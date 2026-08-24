--!strict
--!optimize 2

--[=[
	Reap: Removes the markers of transactions that are over.

	A committed marker can go only after each key that it touched has forgotten it.
	A key that still names it would read a missing marker as an abort, and would undo a leg that
	the transaction counted as committed.
	A key that this pass cannot read counts as loud, so a datastore fault never removes a marker early.
	One pass walks a few pages and then stops. It gives back the cursor of the place where it stopped,
	and the pass after it carries on from there. A marker that a game keeps for years therefore cannot
	hide the markers behind it.

	Return type: A table with Reap, Spent, Quiet, Anywhere, REAP_HORIZON, REAP_LIMIT and REAP_PAGES.
	Example usage:
		local Reap = require("./Reap")
		local Count, Next = Reap.Reap(TxStore, Lookup)
--]=]

local Clock = require("../../Util/Clock")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Contract = require("../../Contract/Op")
local Horizons = require("../../Contract/Horizons")
local Mark = require("../../Encode/Mark")
local Log = require("../../Record/Log")
local LogTypes = require("../../Record/Types")
local Marker = require("./Marker")
local Types = require("./Types")

type Record = Contract.Record<any>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Lookup = Types.Lookup

local REAP_HORIZON = Horizons.REAP
local REAP_LIMIT = 64
local REAP_PAGES = 8

local function Spent(Record: Record, Txid: string, Gen: string?, Born: number): boolean
	if type(Gen) ~= "string" then
		return false
	end

	for _, Op in Record.Ops do
		if Op.Tx ~= Txid then
			continue
		end

		local Mine = Op.TxGen
		if type(Mine) ~= "string" or Mine == Gen then
			return false
		end
		if type(Op.TxAt) ~= "number" or Op.TxAt >= Born then
			return false
		end
	end
	return true
end

local function Anywhere(Lookup: Lookup, Name: string): LogTypes.Log
	local Known = Lookup(Name)
	if Known ~= nil then
		return Known
	end
	return Log.New(Marker.Elsewhere(Name))
end

local function Quiet(Txid: string, Keys: any, Lookup: Lookup, Gen: string?, Born: number): boolean
	if type(Keys) ~= "string" or #Keys == 0 then
		return false
	end

	for _, Held in Mark.Unpack(Keys) do
		local Store, Key = Mark.Split(Held)
		if Store == nil or Key == nil then
			return false
		end

		local Records = Anywhere(Lookup, Store)
		local Read, Record = pcall(function(): Record
			return Records:Read(Key :: string)
		end)
		if not Read or not Spent(Record, Txid, Gen, Born) then
			return false
		end
	end

	return true
end

local function Listed(TxStore: DataStoreWrapper, Limit: number, Resume: string): DataStoreKeyPages
	if Resume ~= "" then
		local Carried, Onward = TxStore:ListKeysAsync("", Limit, Resume)
		if Carried then
			return Onward :: DataStoreKeyPages
		end
		warn(`Ledger: could not carry on listing the transaction markers for '{TxStore.Name}' from where the last pass stopped, so this one starts at the front`)
	end

	local Ok, Pages = TxStore:ListKeysAsync("", Limit, nil)
	if not Ok then
		error(Pages)
	end
	return Pages :: DataStoreKeyPages
end

local function Reap(TxStore: DataStoreWrapper, Lookup: Lookup, Horizon: number?, Limit: number?, Resume: string?): (number, string)
	local Book = Listed(TxStore, Limit or REAP_LIMIT, if type(Resume) == "string" then Resume else "")

	local Older = Horizon or REAP_HORIZON
	local Now = Clock.Now()
	local Reaped = 0
	local Wrapped = false

	for _ = 1, REAP_PAGES do
		local Took = Reaped

		for _, Entry in Book:GetCurrentPage() do
			local Txid = (Entry :: any).KeyName
			local Read, Value, Info = TxStore:GetAsync(Txid)
			if not Read or type(Value) ~= "table" then
				continue
			end

			local Held = Value :: Types.Marker
			local Updated = if Info then (Info :: DataStoreKeyInfo).UpdatedTime / 1000 else 0
			if Now - Updated < Older then
				continue
			end

			if Held.Status ~= Marker.ABORTED and not Quiet(Txid, Held.Keys, Lookup, Marker.GenOf(Value), Marker.BornAt(Value, 0)) then
				continue
			end

			if TxStore:RemoveAsync(Txid) then
				Reaped += 1
			end
		end

		if Book.IsFinished then
			Wrapped = true
			break
		end
		if Reaped > Took then
			break
		end

		Book:AdvanceToNextPageAsync()
	end

	if not Wrapped and Reaped == 0 then
		warn(`Ledger: '{TxStore.Name}' holds more transaction markers than one pass can walk, and this pass removed none. the next pass carries on from where this one stopped`)
	end

	return Reaped, if Wrapped then "" else Book.Cursor
end

return table.freeze({
	Reap = Reap,
	Spent = Spent,
	Quiet = Quiet,
	Anywhere = Anywhere,
	REAP_HORIZON = REAP_HORIZON,
	REAP_LIMIT = REAP_LIMIT,
	REAP_PAGES = REAP_PAGES,
})
