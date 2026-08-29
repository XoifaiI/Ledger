--!strict
--!optimize 2

--[=[
	Escrow: The reducer half of a transfer.

	The money leaves the sender into a hold under the transfer id. It is paid in on the receiver
	against the set of applied names. The hold clears after both of those things happen.
	A sender that already has this transfer written down as sent sets nothing aside a second time.
	The reducer owns that record, so the money never leaves before Escrow asks the question.
	Each of the three legs is a separate op, so each one is atomic on its own key.

	Return type: A table with Layered, Entry, the five op kinds and the five id prefixes.
	Example usage:
		local Escrow = require("./Escrow")
		local Layered = Escrow.Layered("Gold")
--]=]

local TableUtil = require("../Util/TableUtil")
local Errors = require("../Core/Errors")
local Validate = require("../Core/Validate")
local Applied = require("../Core/Applied")
local Layer = require("./Layer")
local Shapes = require("../Core/Shapes")

type Op = Shapes.Op
type Data = Shapes.Folded
type Held = Shapes.Held

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

local function Entry(Held: any, Tid: any): Held?
	if type(Held) ~= "table" or type(Tid) ~= "string" then
		return nil
	end

	local Found = Held[Tid]
	if type(Found) ~= "table" or type(Found.Amount) ~= "number" then
		return nil
	end
	if Found.At ~= nil and type(Found.At) ~= "number" then
		return nil
	end

	local To = Found.To
	return if type(To) == "string" or type(To) == "number" then Found else nil
end

local function Reserving(Data: Data, Op: Op, Field: string): Data?
	local Tid = Op.Tid
	local Amount = Validate.Number(Op.Amount)
	if type(Tid) ~= "string" or Amount == nil then
		return nil
	end

	if Data._Held and Data._Held[Tid] ~= nil then
		return nil
	end
	if Applied.Has(Data._Received, Applied.SENT, Tid) then
		return nil
	end
	if Amount > (Data[Field] or 0) then
		return nil
	end

	local To = Op.To
	local At = if type(Op.At) == "number" then Op.At else nil
	if type(To) ~= "string" and type(To) ~= "number" then
		return nil
	end

	local Holds: { [string]: Held } = table.clone(Data._Held or {})
	Holds[Tid] = { To = To, Amount = Amount, At = At }

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) - Amount
	Next._Held = TableUtil.Some(Holds)

	return Next
end

local function Delivering(Data: Data, Op: Op, Field: string): Data?
	local Tid = Op.Tid
	local Amount = Op.Amount
	if type(Tid) ~= "string" or type(Amount) ~= "number" then
		return nil
	end

	if type(Op.At) ~= "number" then
		return nil
	end

	local Print = if type(Op.Print) == "string" then Op.Print else nil
	local Received = (Data._Received or {}) :: { [string]: any }
	if Applied.Has(Received, Applied.TRANSFER, Tid) then
		return nil
	end

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) + Amount
	Next._Received = Applied.Remember(Received, Applied.Key(Applied.TRANSFER, Tid), Op.At, Print)

	return Next
end

local function Expiring(Data: Data, Op: Op, Field: string): Data?
	local Tid = Op.Tid
	if type(Tid) ~= "string" then
		return nil
	end

	local Held = Data._Held
	local Found = Entry(Held, Tid)
	if Held == nil or Found == nil then
		return nil
	end

	local Rest = table.clone(Held)
	Rest[Tid] = nil

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) + Found.Amount
	Next._Held = TableUtil.Some(Rest)

	if Next[Field] < (Data[Field] or 0) then
		Errors.Broke(`giving transfer {Tid} back left the sender with less than they started with`)
		return nil
	end
	return Next
end

local function Settling(Data: Data, Op: Op): Data?
	local Tid = Op.Tid
	if type(Tid) ~= "string" then
		return nil
	end
	local Holds = Data._Held
	if Holds == nil or Entry(Holds, Tid) == nil then
		return nil
	end
	if type(Op.At) ~= "number" then
		return nil
	end

	local Print = if type(Op.Print) == "string" then Op.Print else nil
	local Held = table.clone(Holds)
	Held[Tid] = nil

	local Next = table.clone(Data)
	Next._Held = TableUtil.Some(Held)
	Next._Received = Applied.Remember(Data._Received, Applied.Key(Applied.SENT, Tid), Op.At, Print)

	return Next
end

local function Pruning(Data: Data, Op: Op): Data?
	local Kept = Applied.Prune(Data._Received, Op.At)
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
	Entry = Entry,

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
})
