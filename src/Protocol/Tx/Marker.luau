--!strict
--!optimize 2

--[=[

	Marker: The key that decides one use of a transaction name.

	Each generation of a name has a marker of its own, under a key that holds the generation. Nothing
	writes that key a second time, so a reaper that takes one off can only take off the one it judged.
	A marker an older build wrote sits under the name itself and is read as before. Create joins one
	like that, or refuses it for other terms, and otherwise opens a new generation. A coordinator joins
	its own generation again on a later pass.

	Decide commits or aborts a marker. StatusOf reads it, and abandons one nothing has touched for
	longer than a transaction may take. Adopt records that a leg has reported. No marker means aborted.
	Condemn marks one the reaper is about to take off, and only while it holds the generation and the
	status the reaper judged. A condemned marker reads as aborted and Decide will not change it.

	The handles it keeps to other stores belong to the hook they were opened on, and so does the count
	of how many are left. A handle that stops being cached stops queueing its writes in order.

	Return type: A table with Create, Decide, StatusOf, Adopt, Condemn, Condemned, KeyOf, GenOf, BornAt, TouchedAt, MarkOf, Elsewhere, HomeOf and ShutdownHomes.
	Example usage:
		local Marker = require("./Marker")
		local Status = Marker.StatusOf(TxStore, Marker.KeyOf(Gen), 30)
--]=]

local TableUtil = require("../../Util/TableUtil")
local Clock = require("../../Util/Clock")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Engine = require("../../Util/Engine")
local Mark = require("../../Encode/Mark")
local Datastore = require("../../Core/Constants/Datastore")
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

local MILLISECOND = 1000
local ONCE = DataStoreWrapper.ONCE

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

local function TouchedAt(Info: any): number
	if Info == nil then
		return 0
	end
	return (Info :: DataStoreKeyInfo).UpdatedTime / MILLISECOND
end

local function Buried(Value: any): boolean
	return type(Value) == "table" and Value.Dead == true
end

local function Condemned(Value: any): boolean
	return type(Value) == "table" and Value.Condemned == true
end

local function KeyOf(Gen: string): string
	local Key = `{Transactions.DECISION}{Gen}`
	assert(#Key <= Datastore.MAX_KEY, `the marker key for generation '{Gen}' is longer than a datastore key may be`)
	return Key
end

local function Clashes(Value: any, Keys: string, Terms: string): boolean
	return (type(Value.Keys) == "string" and Value.Keys ~= Keys) or (type(Value.Terms) == "string" and Value.Terms ~= Terms)
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

local function Same(Current: any, Seen: any): boolean
	if Current == nil then
		return false
	end
	if type(Seen) ~= "table" then
		return type(Current) ~= "table"
	end
	return type(Current) == "table" and GenOf(Current) == GenOf(Seen) and Current.Status == Seen.Status
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

local function Open(TxStore: DataStoreWrapper, Gen: string, Name: string, Total: number, Keys: string, Terms: string, Born: number): boolean
	local Made = false
	local Ok, Value = TxStore:UpdateAsync(KeyOf(Gen), function(Current: any): Marker?
		Made = false
		if Current ~= nil then
			return nil
		end

		Made = true
		return {
			Status = Transactions.PENDING,
			Total = Total,
			Gen = Gen,
			At = Born,
			Adopted = {},
			Keys = Keys,
			Terms = Terms,
			Name = Name,
		}
	end, nil, ONCE)
	return Ok == true and Made and type(Value) == "table"
end

local function Opening(TxStore: DataStoreWrapper, Name: string, Fresh: string, Total: number, Keys: string, Terms: string, Born: number): (Opened, string?, number, boolean, string?)
	local Key = KeyOf(Fresh)
	if not Open(TxStore, Fresh, Name, Total, Keys, Terms, Born) then
		return Transactions.UNWRITTEN, nil, Born, false, Key
	end
	return Transactions.CREATED, Fresh, Born, true, Key
end

local function Joined(Value: Marker, Born: number, Key: string): (Opened, string?, number, boolean, string?)
	local Outcome = if Value.Status == Transactions.ABORTED then Transactions.HUSK else Transactions.CREATED
	return Outcome, GenOf(Value), BornAt(Value, Born), false, Key
end

local function Create(TxStore: DataStoreWrapper, Name: string, Total: number, Keys: string, Terms: string, Fresh: string, Own: string?): (Opened, string?, number, boolean, string?)
	assert(Total > 0, "a transaction marker is being opened for no legs at all")

	local Born = Clock.Now()
	if Own ~= nil then
		local Standing: any = nil
		local Looked = TxStore:UpdateAsync(Own, function(Current: any): Marker?
			Standing = Current
			if type(Current) ~= "table" or Buried(Current) then
				return nil
			end
			return Current
		end)
		if Looked ~= true then
			return Transactions.UNWRITTEN, nil, Born, false, Own
		end
		if type(Standing) == "table" and not Buried(Standing) then
			return Joined(Standing, Born, Own)
		end
	end

	local Read, Seen = TxStore:GetAsync(Name)
	if Read ~= true then
		return Transactions.UNWRITTEN, nil, Born, false, nil
	end
	if type(Seen) ~= "table" or Buried(Seen) then
		return Opening(TxStore, Name, Fresh, Total, Keys, Terms, Born)
	end
	if Clashes(Seen, Keys, Terms) then
		return Transactions.MISMATCH, nil, Born, false, nil
	end

	local Touched: any = nil
	local Ok = TxStore:UpdateAsync(Name, function(Current: any): Marker?
		Touched = nil
		if type(Current) ~= "table" or Buried(Current) or Clashes(Current, Keys, Terms) then
			return nil
		end
		Touched = Current
		return Current
	end)
	if Ok ~= true or Touched == nil then
		return Transactions.UNWRITTEN, nil, Born, false, nil
	end
	return Joined(Touched, Born, Name)
end

local function Decide(TxStore: DataStoreWrapper, Txid: string, To: Status, Shrink: number?, Gen: string?): Status?
	assert(To ~= Transactions.PENDING, "a transaction is being decided back to pending, which would let it start over")

	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) ~= "table" or not Ours(Current, Gen) or Condemned(Current) then
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
	local Updated = TouchedAt(Info)
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

local function Condemn(TxStore: DataStoreWrapper, Txid: string, Seen: any): boolean
	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if not Same(Current, Seen) then
			return nil
		end

		local Held: Marker = if type(Current) == "table" then Current else { Status = Transactions.ABORTED, Total = 0 }
		Held.Dead = true
		Held.Condemned = true
		return Held
	end)
	return Ok == true and Condemned(Value)
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
	Condemn = Condemn,
	Condemned = Condemned,
	KeyOf = KeyOf,
	GenOf = GenOf,
	BornAt = BornAt,
	TouchedAt = TouchedAt,
	MarkOf = MarkOf,
	Elsewhere = Elsewhere,
	HomeOf = HomeOf,
	ShutdownHomes = ShutdownHomes,
})
