--!strict
--!optimize 2

--[=[
	Escrow: The reducer half of a transfer.

	The money leaves the sender into a hold under the transfer id. It is paid in on the receiver
	against the set of applied names. The hold clears after both of those things happen.
	A sender that already has this transfer written down as sent sets nothing aside a second time.
	The reducer owns that record, so the money never leaves before Escrow asks the question.
	Each of the three legs is a separate op, so each one is atomic on its own key.

	Return type: A table with Layered, the five op kinds, the five id prefixes, REDRIVE_HORIZON and EXPIRE_MARGIN.
	Example usage:
		local Escrow = require("./Escrow")
		local Layered = Escrow.Layered("Gold")
--]=]

local TableUtil = require("../Util/TableUtil")
local Fault = require("../Contract/Fault")
local Horizons = require("../Contract/Horizons")
local Entries = require("../Kernel/Entries")
local Layer = require("../Kernel/Layer")
local Op = require("../Contract/Op")

type Op = Op.Op
type Data = { [any]: any }

local RESERVE = "__TransferReserve"
local DELIVER = "__TransferDeliver"
local SETTLE = "__TransferSettle"
local PRUNE = "__TransferPrune"
local EXPIRE = "__TransferExpire"

local RESERVE_ID = "res"
local DELIVER_ID = "del"
local SETTLE_ID = "set"
local PRUNE_ID = "prn"
local EXPIRE_ID = "exp"

local REDRIVE_HORIZON = Horizons.REDRIVE
local EXPIRE_MARGIN = Horizons.EXPIRE_MARGIN

local function Reserving(Data: Data, Op: Op, Field: string): Data?
	local Tid = Op.Tid
	local Amount = Op.Amount
	if type(Tid) ~= "string" or type(Amount) ~= "number" then
		return nil
	end

	if Data._Held and Data._Held[Tid] ~= nil then
		return nil
	end
	if Entries.Has(Data._Received, Entries.SENT, Tid) then
		return nil
	end
	if Amount > (Data[Field] or 0) then
		return nil
	end

	local Held = table.clone((Data._Held or {}) :: Data)
	Held[Tid] = { To = Op.To, Amount = Amount, At = Op.At }

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) - Amount
	Next._Held = TableUtil.Some(Held)

	if Next[Field] < 0 then
		Fault.Broke(`setting {Amount} aside for transfer {Tid} took '{Field}' below zero`)
		return nil
	end
	if TableUtil.Count(Next._Held) ~= TableUtil.Count(Data._Held) + 1 then
		Fault.Broke(`setting aside for transfer {Tid} did not leave exactly one more hold on the key`)
		return nil
	end
	return Next
end

local function Delivering(Data: Data, Op: Op, Field: string): Data?
	local Tid = Op.Tid
	local Amount = Op.Amount
	if type(Tid) ~= "string" or type(Amount) ~= "number" then
		return nil
	end

	local Print = if type(Op.Print) == "string" then Op.Print else nil
	local Received = (Data._Received or {}) :: { [string]: any }
	if Entries.Has(Received, Entries.TRANSFER, Tid) then
		return nil
	end

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) + Amount
	Next._Received = Entries.Remember(Received, Entries.Key(Entries.TRANSFER, Tid), Op.At, Print)

	if not Entries.Has(Next._Received, Entries.TRANSFER, Tid) then
		Fault.Broke(`transfer {Tid} was paid in without being remembered, so the same delivery could pay again`)
		return nil
	end
	if TableUtil.Count(Next._Held) ~= TableUtil.Count(Data._Held) then
		Fault.Broke(`paying in transfer {Tid} changed what the receiver has set aside`)
		return nil
	end
	return Next
end

local function Expiring(Data: Data, Op: Op, Field: string): Data?
	local Tid = Op.Tid
	if type(Tid) ~= "string" then
		return nil
	end

	local Held = Data._Held :: Data?
	local Entry = if Held then Held[Tid] else nil
	if not Entry then
		return nil
	end

	local Rest = table.clone(Held :: Data)
	Rest[Tid] = nil

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) + Entry.Amount
	Next._Held = TableUtil.Some(Rest)

	if TableUtil.Count(Next._Held) ~= TableUtil.Count(Data._Held) - 1 then
		Fault.Broke(`giving transfer {Tid} back did not clear exactly the one hold it was held under`)
		return nil
	end
	if Next[Field] < (Data[Field] or 0) then
		Fault.Broke(`giving transfer {Tid} back left the sender with less than they started with`)
		return nil
	end
	return Next
end

local function Settling(Data: Data, Op: Op): Data?
	local Tid = Op.Tid
	if type(Tid) ~= "string" then
		return nil
	end
	if not (Data._Held and Data._Held[Tid]) then
		return nil
	end

	local Print = if type(Op.Print) == "string" then Op.Print else nil
	local Held = table.clone(Data._Held :: Data)
	Held[Tid] = nil

	local Next = table.clone(Data)
	Next._Held = TableUtil.Some(Held)
	Next._Received = Entries.Remember(Data._Received, Entries.Key(Entries.SENT, Tid), Op.At, Print)

	if TableUtil.Count(Next._Held) ~= TableUtil.Count(Data._Held) - 1 then
		Fault.Broke(`finishing transfer {Tid} did not clear exactly the one hold it was held under`)
		return nil
	end
	return Next
end

local function Pruning(Data: Data, Op: Op): Data?
	local Kept = Entries.Prune(Data._Received, Op.At)
	if Kept == nil then
		return nil
	end

	local Next = table.clone(Data)
	Next._Received = TableUtil.Some(Kept)
	return Next
end

local function Layered(Balance: string?): Layer.Layer?
	if Balance == nil then
		return nil
	end
	local Field = Balance
	return {
		Kinds = {
			[RESERVE] = function(Data: Data, Op: Op): Data?
				return Reserving(Data, Op, Field)
			end,
			[DELIVER] = function(Data: Data, Op: Op): Data?
				return Delivering(Data, Op, Field)
			end,
			[EXPIRE] = function(Data: Data, Op: Op): Data?
				return Expiring(Data, Op, Field)
			end,
			[SETTLE] = Settling,
			[PRUNE] = Pruning,
		},
		Owns = {
			{ Field = "_Held", Says = "the money set aside" },
			{ Field = "_Received", Says = "the applied names" },
		},
	}
end

return table.freeze({
	Layered = Layered,

	RESERVE = RESERVE,
	DELIVER = DELIVER,
	SETTLE = SETTLE,
	PRUNE = PRUNE,
	EXPIRE = EXPIRE,

	RESERVE_ID = RESERVE_ID,
	DELIVER_ID = DELIVER_ID,
	SETTLE_ID = SETTLE_ID,
	PRUNE_ID = PRUNE_ID,
	EXPIRE_ID = EXPIRE_ID,

	REDRIVE_HORIZON = REDRIVE_HORIZON,
	EXPIRE_MARGIN = EXPIRE_MARGIN,
})
