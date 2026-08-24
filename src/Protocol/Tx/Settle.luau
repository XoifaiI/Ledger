--!strict
--!optimize 2

--[=[
	Settle: Turns what a marker says into a resolved record.

	Each marker is then told that its leg has reported.
	A server that finds a leg on a key that it wants to read runs this.

	Return type: A table with Settle.
	Example usage:
		local Settle = require("./Settle")
		local Record = Settle.Settle(Books, TxStore, "a", Record)
--]=]

local Contract = require("../../Contract/Op")
local Fault = require("../../Contract/Fault")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local LogTypes = require("../../Record/Types")
local Stamp = require("../../Record/Stamp")
local Marker = require("./Marker")

type Record = Contract.Record<any>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Log = LogTypes.Log
type Verdict = LogTypes.Verdict

local function Settle(Records: Log, TxStore: DataStoreWrapper, Key: string, Record: Record, PerLeg: number?): Record
	local Limit = PerLeg or Marker.LEG_TIMEOUT
	local Pending = Stamp.PendingTx(Record)
	if next(Pending) == nil then
		return Record
	end

	local Verdicts: { [string]: Verdict } = {}
	local Markers: { [string]: DataStoreWrapper } = {}
	for Txid, Home in Pending do
		local Where = Marker.HomeOf(TxStore, Home)
		Markers[Txid] = Where
		local Status, Gen, Since = Marker.StatusOf(Where, Txid, Limit)
		if Status == Marker.COMMITTED then
			Verdicts[Txid] = { Commit = true, Gen = Gen, Since = Since }
		elseif Status == Marker.ABORTED then
			Verdicts[Txid] = { Commit = false, Gen = Gen, Since = Since }
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
			Fault.Holds(Where ~= nil, `settled a leg for transaction '{Txid}' whose marker was never read`)
			Marker.Adopt(Where, Txid, { Mark }, Verdicts[Txid].Gen)
		end
	end
	return Resolved
end

return table.freeze({
	Settle = Settle,
})
