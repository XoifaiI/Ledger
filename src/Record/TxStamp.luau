--!strict
--!optimize 2

--[=[

	TxStamp: The transaction stamp on an op, and what a record says about it.

	Every fold skips a stamped op, so these questions say whether a key is waiting on a transaction.
	Unstamped takes the stamp off one, Landed takes it off every op of a transaction, and Carries looks
	in both Ops and Seen.

	Return type: A table with Unstamped, Landed, HasPending, NotPending, PendingTx, PendingIds, Holds, Carries and Written.
	Example usage:
		local TxStamp = require("./TxStamp")
		if TxStamp.HasPending(Record) then return end
--]=]

local Shapes = require("../Core/Shapes")

type Op = Shapes.Op
type Record = Shapes.Record<any>

local function Unstamped(Op: Op): Op
	local Plain = table.clone(Op)
	Plain.Tx = nil
	Plain.TxHome = nil
	Plain.TxGen = nil
	return Plain
end

local function Landed(Ops: { Op }, Txid: string?): { Op }
	local Out = table.clone(Ops)
	for Index, Existing in Out do
		if Existing.Tx ~= nil and (Txid == nil or Existing.Tx == Txid) then
			Out[Index] = Unstamped(Existing)
		end
	end
	return Out
end

local function HasPending(Record: Record): boolean
	for _, Op in Record.Ops do
		if Op.Tx ~= nil then
			return true
		end
	end
	return false
end

local function NotPending(Record: Record): boolean
	return not HasPending(Record)
end

local function PendingTx(Record: Record): { [string]: string | true }
	local Set: { [string]: string | true } = {}
	for _, Op in Record.Ops do
		if type(Op.Tx) == "string" then
			Set[Op.Tx] = if type(Op.TxHome) == "string" then Op.TxHome else true
		end
	end
	return Set
end

local function PendingIds(Record: Record): { string }
	local Seen: { [string]: boolean } = {}
	local Found: { string } = {}
	for _, Op in Record.Ops do
		local Txid = Op.Tx
		if type(Txid) ~= "string" or Seen[Txid] then
			continue
		end
		Seen[Txid] = true
		table.insert(Found, Txid)
	end
	table.sort(Found)
	return Found
end

local function Find(Record: Record, Id: string): Op?
	for _, Op in Record.Ops do
		if Op.Id == Id then
			return Op
		end
	end
	return nil
end

local function Holds(Record: Record, Id: string): boolean
	return Find(Record, Id) ~= nil
end

local function Written(Record: Record, Id: string): (boolean, string?, any)
	local Op = Find(Record, Id)
	if Op ~= nil then
		return true, if type(Op.Print) == "string" then Op.Print else nil, Op.From
	end
	for _, Seen in Record.Seen do
		if Seen == Id then
			return true, nil, nil
		end
	end
	return false, nil, nil
end

local function Carries(Record: Record, Id: string): boolean
	return (Written(Record, Id))
end

return table.freeze({
	Unstamped = Unstamped,
	Landed = Landed,
	HasPending = HasPending,
	NotPending = NotPending,
	PendingTx = PendingTx,
	PendingIds = PendingIds,
	Holds = Holds,
	Carries = Carries,
	Written = Written,
})
