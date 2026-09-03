--!strict
--!optimize 2

--[=[

	Marker: The one key that decides a transaction.

	Create opens one. Decide commits or aborts it. StatusOf reads it, and abandons one nothing has
	touched for longer than a transaction may take. Adopt records that a leg has reported. No marker
	means aborted. A marker goes away only once every leg has reported.

	The handles it keeps to other stores belong to the hook they were opened on, and so does the count
	of how many are left. A handle that stops being cached stops queueing its writes in order.

	Return type: A table with Create, Decide, StatusOf, Adopt, GenOf, BornAt, MarkOf, Elsewhere, HomeOf and ShutdownHomes.
	Example usage:
		local Marker = require("./Marker")
		local Status = Marker.StatusOf(TxStore, "order1", 30)
--]=]

local TableUtil = require("../../Util/TableUtil")
local Clock = require("../../Util/Clock")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Engine = require("../../Util/Engine")
local Ids = require("../../Encode/Ids")
local Mark = require("../../Encode/Mark")
local Transactions = require("../../Core/Constants/Transactions")
local Types = require("./Types")

type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Marker = Types.Marker
type Status = Types.Status
type Opened = Types.Opened

type Home = {
	Wrappers: { [string]: DataStoreWrapper },
	Kept: number,
	Said: boolean,
}

local Homes: { [Engine.Hook]: Home } = setmetatable({}, { __mode = "k" }) :: any

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
	return Current.Status == Transactions.ABORTED
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
		Mine = { Wrappers = {}, Kept = 0, Said = false }
		Homes[From.Hook] = Mine
	end

	local Cached = Mine.Wrappers[Name]
	if Cached ~= nil then
		return Cached
	end

	local Fresh = DataStoreWrapper.New(Name, From.Scheduler, From.Hook)
	if Mine.Kept < Transactions.MAX_HOMES then
		Mine.Wrappers[Name] = Fresh
		Mine.Kept += 1
		return Fresh
	end

	if not Mine.Said then
		Mine.Said = true
		warn(
			`Ledger: this server holds {Transactions.MAX_HOMES} transaction homes, so '{Name}' gets a new handle each time. its writes no longer queue, and a shutdown cannot stop its retries. use fewer stores in your transactions`
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
	assert(Total > 0, "a transaction marker is being opened for no legs at all")

	local Clash = false
	local Minted = false
	local Born = Clock.Now()
	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		Clash = false
		Minted = false
		if type(Current) ~= "table" or Buried(Current) then
			Minted = true
			return {
				Status = Transactions.PENDING,
				Total = Total,
				Gen = Ids.Fresh(),
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
		return Transactions.MISMATCH, nil, Born, false
	end
	if Ok ~= true then
		return Transactions.UNWRITTEN, nil, Born, false
	end
	if type(Value) == "table" and (Value :: Marker).Status == Transactions.ABORTED then
		return Transactions.HUSK, GenOf(Value), BornAt(Value, Born), Minted
	end
	return Transactions.CREATED, GenOf(Value), BornAt(Value, Born), Minted
end

local function Decide(TxStore: DataStoreWrapper, Txid: string, To: Status, Shrink: number?, Gen: string?): Status?
	assert(To ~= Transactions.PENDING, "a transaction is being decided back to pending, which would let it start over")

	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) ~= "table" or not Ours(Current, Gen) then
			return nil
		end
		if Current.Status == Transactions.PENDING then
			Current.Status = To
		end
		if Shrink ~= nil and Current.Status == Transactions.ABORTED then
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
	assert(Decided.Status ~= Transactions.PENDING, `transaction '{Txid}' was decided but its marker is still pending, so another server could decide it the other way`)

	return Decided.Status
end

local function StatusOf(TxStore: DataStoreWrapper, Txid: string, PerLeg: number): (Status?, string?, number)
	local Looked = Clock.Now()
	local Ok, Value, Info = TxStore:GetAsync(Txid)
	if not Ok then
		return nil, nil, Looked
	end
	if type(Value) ~= "table" or Buried(Value) then
		return Transactions.ABORTED, nil, Looked - PerLeg * Transactions.MAX_LEGS
	end

	local Marker = Value :: Marker
	local Gen, Born = GenOf(Value), BornAt(Value, 0)
	if Marker.Status ~= Transactions.PENDING then
		return Marker.Status, Gen, Born
	end

	local Legs = if type(Marker.Total) == "number" and Marker.Total > 0 then Marker.Total else Transactions.MAX_LEGS
	local Updated = if Info then (Info :: DataStoreKeyInfo).UpdatedTime / 1000 else 0
	if Clock.Now() - Updated >= PerLeg * Legs then
		return Decide(TxStore, Txid, Transactions.ABORTED, nil, Gen) or Transactions.PENDING, Gen, Born
	end
	return Transactions.PENDING, Gen, Born
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
		if Current.Status ~= Transactions.PENDING and Finished(Current) then
			Current.Dead = true
		end
		return Current
	end)

	if not Ok or type(Value) ~= "table" then
		return
	end

	local Marker = Value :: Marker
	if Finished(Marker) then
		assert(Marker.Status ~= Transactions.PENDING, `transaction '{Txid}' is finished but its marker is still undecided, so a retry would run it again`)
	end
end

local function ShutdownHomes(Attempts: number)
	for _, Mine in Homes do
		for _, Wrapper in Mine.Wrappers do
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
})
