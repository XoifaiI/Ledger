--!strict
--!optimize 2

--[=[
	Ops: Logic. The op a game's call asks for.

	Spec: record 5.1.

	A body is what a reducer sees: the op's fields and its Kind. An op with no Once is minted. With
	Once and OnceAt, the unix time the name was first sent, it is timed, and with Once alone it is
	untimed. A kind is stored as a number, the hash of its name. A print is 16 bits of the hash of a
	value's canon print, and an op's print is that of its body. A game's name may not start with
	Book.DRAWN. Durable gives nil for an op a datastore cannot hold. A bad Once or OnceAt throws at
	the game's call.

	Return type: The Ops module.
	Example usage:
		local Asked = Ops.Durable("Grant", { Amount = 5, Once = Receipt.PurchaseId }, false)
--]=]

local Book = require("../Record/Book")
local Canon = require("../Encode/Canon")
local Errors = require("../Core/Errors")
local Hash = require("../Encode/Hash")
local Limits = require("../Core/Constants/Limits")
local Requests = require("../Record/Requests")
local Value = require("../Encode/Value")
local Queue = require("../Record/Queue")

type Fields = { [string]: any }

local ONCE = `Once has to be a string of 1 to {Limits.NAME_BYTES} bytes`
local ONCE_AT = "OnceAt has to be the whole unix time the name was first sent"
local ALONE = "OnceAt needs a Once"

local Form = Requests.Form

local KINDS = 32768
local PRINT_MASK = 0xFFFF

local Ops = {}

local function Named(Name: string): boolean
	return Name ~= "" and #Name <= Limits.NAME_BYTES and string.sub(Name, 1, 1) ~= Book.DRAWN
end

local function Timed(At: number): boolean
	return At % 1 == 0 and At >= Limits.EPOCH and At - Limits.EPOCH <= Limits.STAMP_MAX
end

function Ops.Body(Kind: string, Fields: Fields?): Fields
	local Body = if Fields then table.clone(Fields) else {}
	Body.Kind = Kind
	return Body
end

function Ops.Kind(Kind: string): number
	return Hash(Kind) % KINDS
end

function Ops.Print(Value: unknown): number
	return bit32.band(Hash(Canon(Value)), PRINT_MASK)
end

function Ops.Durable(Kind: string, Fields: Fields?, MustExist: boolean): Queue.Asked?
	local Body = Ops.Body(Kind, Fields)
	local Name, At = Body.Once, Body.OnceAt
	Body.Once = nil
	Body.OnceAt = nil
	if Name ~= nil and not (type(Name) == "string" and Named(Name)) then
		Errors.Misuse(ONCE, 1)
	elseif At ~= nil and not (type(At) == "number" and Timed(At)) then
		Errors.Misuse(ONCE_AT, 1)
	elseif At ~= nil and Name == nil then
		Errors.Misuse(ALONE, 1)
	elseif Value.Check(Body) == nil then
		return nil
	elseif Name == nil then
		return { Form = Form.Minted, Kind = 0, MustExist = MustExist, Body = Body }
	end
	return {
		Form = if At then Form.Timed else Form.Untimed,
		Kind = Ops.Kind(Kind),
		Name = Name,
		Print = Ops.Print(Body),
		Stamp = if At then At - Limits.EPOCH else nil,
		MustExist = MustExist,
		Body = Body,
	}
end

function Ops.Name(Name: unknown): string
	local Checked: string = if type(Name) == "string" and Named(Name) then Name else Errors.Misuse(ONCE, 1)
	return Checked
end

function Ops.Stamp(At: unknown): number
	local Checked: number = if type(At) == "number" and Timed(At) then At else Errors.Misuse(ONCE_AT, 1)
	return Checked - Limits.EPOCH
end

return Ops
