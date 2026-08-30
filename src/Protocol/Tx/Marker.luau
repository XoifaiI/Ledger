--!strict
--!optimize 2

--[=[

	Marker: The one key that decides a transaction.

	Create opens one, Decide commits or aborts it, StatusOf reads it and abandons one nothing has
	touched for longer than a transaction may take, and Adopt records that a leg has reported. No
	marker means aborted. A marker goes away only once every leg has reported.

	Return type: A table with Create, Decide, StatusOf, Adopt, GenOf, BornAt, MarkOf, Elsewhere, HomeOf and ShutdownHomes, the four openings, the three statuses, and the caps on legs and homes.
	Example usage:
		local Marker = require("./Marker")
		local Status = Marker.StatusOf(TxStore, "order1", 30)
--]=]

local TableUtil = require("../../Util/TableUtil")
local Clock = require("../../Util/Clock")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Engine = require("../../Util/Engine")
local Errors = require("../../Core/Errors")
local Ident = require("../../Encode/Ident")
local Mark = require("../../Encode/Mark")
local Types = require("./Types")

type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Marker = Types.Marker
type Status = Types.Status
type Opened = Types.Opened

local MAX_LEGS = 4
local MAX_HOMES = 64

local CREATED = "Created" :: "Created"
local MISMATCH = "Mismatch" :: "Mismatch"
local UNWRITTEN = "Unwritten" :: "Unwritten"
local HUSK = "Husk" :: "Husk"

local PENDING = "Pending" :: "Pending"
local COMMITTED = "Committed" :: "Committed"
local ABORTED = "Aborted" :: "Aborted"

local Homes: { [Engine.Hook]: { [string]: DataStoreWrapper } } = {}
local Kept = 0
local Said = false

local function GenOf(Value: any): string?
	if type(Value) ~= "table" or type(Value.Gen) ~= "string" then
		return nil
	end
	return Value.Gen
end

local function BornAt(Value: any, Fallback: number): number
	if type(Value) ~= "table" or type(Value.At) ~= "number" then
		return Fallback
	end
	return Value.At
end

local function Buried(Value: any): boolean
	return type(Value) == "table" and Value.Dead == true
end

local function Finished(Current: any): boolean
	if Current.Total > 0 then
		return TableUtil.Count(Current.Adopted) >= Current.Total
	end
	return Current.Status == ABORTED
end

local function Ours(Current: any, Gen: string?): boolean
	local Held = GenOf(Current)
	return type(Held) == "string" and Held == Gen
end

local function MarkOf(Wrapper: DataStoreWrapper, Key: string): string
	return Mark.Of(Wrapper.Name, Key)
end

local function Elsewhere(Name: string, From: DataStoreWrapper): DataStoreWrapper
	local Mine = Homes[From.Hook]
	if Mine == nil then
		Mine = {}
		Homes[From.Hook] = Mine
	end

	local Cached = Mine[Name]
	if Cached ~= nil then
		return Cached
	end

	local Fresh = DataStoreWrapper.New(Name, From.Scheduler, From.Hook)
	if Kept < MAX_HOMES then
		Mine[Name] = Fresh
		Kept += 1
		return Fresh
	end

	if not Said then
		Said = true
		warn(
			`Ledger: this server holds {MAX_HOMES} transaction homes, so '{Name}' gets a new handle each time. its writes no longer queue, and a shutdown cannot stop its retries. use fewer stores in your transactions`
		)
	end
	return Fresh
end

local function HomeOf(TxStore: DataStoreWrapper, Home: string | true): DataStoreWrapper
	if Home == true or Home == TxStore.Name then
		return TxStore
	end

	return Elsewhere(Home, TxStore)
end

local function Create(TxStore: DataStoreWrapper, Txid: string, Total: number, Keys: string, Terms: string): (Opened, string?, number, boolean)
	Errors.Holds(Total > 0, "a transaction marker is being opened for no legs at all")

	local Clash = false
	local Minted = false
	local Born = Clock.Now()
	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		Clash = false
		Minted = false
		if type(Current) ~= "table" or Buried(Current) then
			Minted = true
			return {
				Status = PENDING,
				Total = Total,
				Gen = Ident.Fresh(),
				At = Born,
				Adopted = {},
				Keys = Keys,
				Terms = Terms,
			}
		end
		if type(Current.Keys) == "string" and Current.Keys ~= Keys then
			Clash = true
			return nil
		end
		if type(Current.Terms) == "string" and Current.Terms ~= Terms then
			Clash = true
			return nil
		end

		return Current
	end)

	if Clash then
		return MISMATCH, nil, Born, false
	end
	if Ok ~= true then
		return UNWRITTEN, nil, Born, false
	end
	if type(Value) == "table" and (Value :: Marker).Status == ABORTED then
		return HUSK, GenOf(Value), BornAt(Value, Born), Minted
	end
	return CREATED, GenOf(Value), BornAt(Value, Born), Minted
end

local function Decide(TxStore: DataStoreWrapper, Txid: string, To: Status, Shrink: number?, Gen: string?): Status?
	Errors.Holds(To ~= PENDING, "a transaction is being decided back to pending, which would let it start over")

	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) ~= "table" or not Ours(Current, Gen) then
			return nil
		end
		if Current.Status == PENDING then
			Current.Status = To
		end
		if Shrink ~= nil and Current.Status == ABORTED then
			if Shrink < Current.Total then
				Current.Total = Shrink
			end
			if Finished(Current) then
				Current.Dead = true
			end
		end
		return Current
	end)

	if not Ok or type(Value) ~= "table" then
		return nil
	end
	local Decided = Value :: Marker
	Errors.Holds(Decided.Status ~= PENDING, `transaction '{Txid}' was decided but its marker is still pending, so another server could decide it the other way`)

	return Decided.Status
end

local function StatusOf(TxStore: DataStoreWrapper, Txid: string, PerLeg: number): (Status?, string?, number)
	local Looked = Clock.Now()
	local Ok, Value, Info = TxStore:GetAsync(Txid)
	if not Ok then
		return nil, nil, Looked
	end
	if type(Value) ~= "table" or Buried(Value) then
		return ABORTED, nil, Looked - PerLeg * MAX_LEGS
	end

	local Marker = Value :: Marker
	local Gen, Born = GenOf(Value), BornAt(Value, 0)
	if Marker.Status ~= PENDING then
		return Marker.Status, Gen, Born
	end

	local Legs = if type(Marker.Total) == "number" and Marker.Total > 0 then Marker.Total else MAX_LEGS
	local Updated = if Info then (Info :: DataStoreKeyInfo).UpdatedTime / 1000 else 0
	if Clock.Now() - Updated >= PerLeg * Legs then
		return Decide(TxStore, Txid, ABORTED, nil, Gen) or PENDING, Gen, Born
	end
	return PENDING, Gen, Born
end

local function Adopt(TxStore: DataStoreWrapper, Txid: string, Marks: { string }, Gen: string?)
	if #Marks == 0 then
		return
	end

	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) ~= "table" or not Ours(Current, Gen) then
			return nil
		end

		local Adopted: { [string]: boolean } = if type(Current.Adopted) == "table" then Current.Adopted :: { [string]: boolean } else {}
		for _, Mark in Marks do
			Adopted[Mark] = true
		end
		Current.Adopted = Adopted
		if Current.Status ~= PENDING and Finished(Current) then
			Current.Dead = true
		end
		return Current
	end)

	if not Ok or type(Value) ~= "table" then
		return
	end

	local Marker = Value :: Marker
	if Finished(Marker) then
		Errors.Holds(Marker.Status ~= PENDING, `transaction '{Txid}' is finished but its marker is still undecided, so a retry would run it again`)
	end
end

local function ShutdownHomes(Attempts: number)
	for _, Mine in Homes do
		for _, Wrapper in Mine do
			Wrapper:SkipAllQueuesToLastEnqueued()
			Wrapper.Attempts = Attempts
		end
	end
end

return table.freeze({
	Create = Create,
	Decide = Decide,
	StatusOf = StatusOf,
	Adopt = Adopt,
	GenOf = GenOf,
	BornAt = BornAt,
	MarkOf = MarkOf,
	Elsewhere = Elsewhere,
	HomeOf = HomeOf,
	ShutdownHomes = ShutdownHomes,

	CREATED = CREATED,
	MISMATCH = MISMATCH,
	UNWRITTEN = UNWRITTEN,
	HUSK = HUSK,

	PENDING = PENDING,
	COMMITTED = COMMITTED,
	ABORTED = ABORTED,

	MAX_LEGS = MAX_LEGS,
	MAX_HOMES = MAX_HOMES,
})
