--!strict
--!optimize 2

--[=[
	Resolve: Turns what a marker says into a resolved record.

	Each marker is then told that its leg has reported.
	A server that finds a leg on a key that it wants to read runs this.

	Return type: A table with Settle.
	Example usage:
		local Resolve = require("./Resolve")
		local Record = Resolve.Settle(Books, TxStore, "a", Record)
--]=]

local Shapes = require("../../Core/Shapes")
local Errors = require("../../Core/Errors")
local Windows = require("../../Core/Constants/Windows")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local LogTypes = require("../../Record/Types")
local TxStamp = require("../../Record/TxStamp")
local Marker = require("./Marker")

type Record = Shapes.Record<any>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Log = LogTypes.Log
type Verdict = LogTypes.Verdict

local function Settle(Records: Log, TxStore: DataStoreWrapper, Key: string, Record: Record, PerLeg: number?): Record
	local Limit = PerLeg or Windows.LEG
	local Pending = TxStamp.PendingTx(Record)
	if next(Pending) == nil then
		return Record
	end

	local Verdicts: { [string]: Verdict } = {}
	local Markers: { [string]: DataStoreWrapper } = {}
	for Txid, Home in Pending do
		local Where = Marker.HomeOf(TxStore, Home)
		Markers[Txid] = Where
		local Status, Gen, Since = Marker.StatusOf(Where, Txid, Limit)
		if Status == Marker.COMMITTED or Status == Marker.ABORTED then
			Verdicts[Txid] = { Commit = Status == Marker.COMMITTED, Gen = Gen, Since = Since }
		end
	end
	if next(Verdicts) == nil then
		return Record
	end

	local Settlement = Records:Resolve(Key, Verdicts)
	local Resolved, Counts = Settlement.Record, Settlement.Counts
	local Mark = Marker.MarkOf(Records.Wrapper, Key)
	for Txid, Count in Counts do
		if Count > 0 then
			local Where = Markers[Txid]
			Errors.Holds(Where ~= nil, `settled a leg for transaction '{Txid}' whose marker was never read`)
			Marker.Adopt(Where, Txid, { Mark }, Verdicts[Txid].Gen)
		end
	end
	return Resolved
end

return table.freeze({
	Settle = Settle,
})
