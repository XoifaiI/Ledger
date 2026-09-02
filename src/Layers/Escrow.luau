--!strict
--!optimize 2

--[=[

	Escrow: The reducer half of a transfer.

	The money leaves the sender into a hold under the transfer id, is paid in on the receiver against
	the set of applied names, and the hold clears once both have happened. Each of the three legs is a
	separate op, so each is atomic on its own key. Expire gives a hold back and Prune drops names that
	have aged out.

	Return type: A table with Layered and Entry.
	Example usage:
		local Escrow = require("./Escrow")
		local Layered = Escrow.Layered("Gold")
--]=]

local TableUtil = require("../Util/TableUtil")
local Validate = require("../Core/Validate")
local Tags = require("../Core/Constants/Tags")
local Applied = require("../Core/Applied")
local Kinds = require("../Core/Constants/Kinds")
local Layer = require("./Layer")
local Shapes = require("../Core/Shapes")

type Op = Shapes.Op
type Data = Shapes.Folded
type Held = Shapes.Held

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
	if Found.Field ~= nil and type(Found.Field) ~= "string" then
		return nil
	end

	local To = Found.To
	return if type(To) == "string" or type(To) == "number" then Found else nil
end

local function Named(Op: Op, Balance: string?): string?
	local Field = Op.Field
	return if type(Field) == "string" then Field else Balance
end

local function Reserving(Data: Data, Op: Op, Balance: string?): Data?
	local Tid = Op.Tid
	local Amount = Validate.Number(Op.Amount)
	local Field = Named(Op, Balance)
	if type(Tid) ~= "string" or Amount == nil or Field == nil then
		return nil
	end

	if Data._Held and Data._Held[Tid] ~= nil then
		return nil
	end
	if Applied.Has(Data._Received, Tags.SENT, Tid) then
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
	Holds[Tid] = { To = To, Amount = Amount, At = At, Field = if type(Op.Field) == "string" then Op.Field else nil }

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) - Amount
	Next._Held = TableUtil.Some(Holds)

	return Next
end

local function Delivering(Data: Data, Op: Op, Balance: string?): Data?
	local Tid = Op.Tid
	local Amount = Op.Amount
	local Field = Named(Op, Balance)
	if type(Tid) ~= "string" or type(Amount) ~= "number" or Field == nil then
		return nil
	end

	if type(Op.At) ~= "number" then
		return nil
	end

	local Print = if type(Op.Print) == "string" then Op.Print else nil
	local Received = (Data._Received or {}) :: { [string]: any }
	if Applied.Has(Received, Tags.TRANSFER, Tid) then
		return nil
	end

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) + Amount
	Next._Received = Applied.Remember(Received, Applied.Key(Tags.TRANSFER, Tid), Op.At, Print)

	return Next
end

local function Expiring(Data: Data, Op: Op, Balance: string?): Data?
	local Tid = Op.Tid
	if type(Tid) ~= "string" then
		return nil
	end

	local Held = Data._Held
	local Found = Entry(Held, Tid)
	if Held == nil or Found == nil then
		return nil
	end
	local Field = Found.Field or Balance
	if Field == nil then
		return nil
	end

	local Rest = table.clone(Held)
	Rest[Tid] = nil

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) + Found.Amount
	Next._Held = TableUtil.Some(Rest)

	if Next[Field] < (Data[Field] or 0) then
		warn(`Ledger bug: giving transfer {Tid} back left the sender with less than they started with`)
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
	Next._Received = Applied.Remember(Data._Received, Applied.Key(Tags.SENT, Tid), Op.At, Print)

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
	return {
		Kinds = {
			[Kinds.RESERVE] = function(Data: Data, Op: Op): Data?
				return Reserving(Data, Op, Balance)
			end,
			[Kinds.DELIVER] = function(Data: Data, Op: Op): Data?
				return Delivering(Data, Op, Balance)
			end,
			[Kinds.EXPIRE] = function(Data: Data, Op: Op): Data?
				return Expiring(Data, Op, Balance)
			end,
			[Kinds.SETTLE] = Settling,
			[Kinds.PRUNE] = Pruning,
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
})
