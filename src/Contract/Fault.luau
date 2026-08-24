--!strict
--!optimize 2

--[=[
	Fault: An error that carries the reason that it becomes.

	A failure names itself where it occurs. The caller does not read the reason out of a message later.
	Holds writes a warning and throws when a rule of Ledger breaks. That is a fault in Ledger.
	A fault has no methods, only a way to print itself, so its metatable declares __tostring and no
	__index. Nothing is inherited, and an instance holds the three fields and nothing else.

	Return type: A table with New, Of, Named, Broke and Holds.
	Example usage:
		local Fault = require("./Fault")
		error(Fault.New(Reasons.Busy, "the key has a leg on it"))
--]=]

local ThreadQueue = require("../Util/ThreadQueue")
local Reasons = require("./Reason")

type Reason = Reasons.Reason

type FaultImpl = {
	__tostring: (self: Fault) -> string,
}

export type Fault = setmetatable<{
	read Ledger: true,
	read Why: Reason,
	read Message: string,
}, FaultImpl>

local CLOSED = Reasons.Closed
local UNRESOLVED = Reasons.Unresolved

local Fault = {} :: FaultImpl

local function New(Why: Reason, Message: string): Fault
	return table.freeze(setmetatable({ Ledger = true, Why = Why, Message = Message }, Fault)) :: any
end

local function Of(Err: unknown): Reason?
	if type(Err) ~= "table" then
		return nil
	end

	local Tagged = Err :: { Ledger: unknown, Why: unknown }
	if Tagged.Ledger ~= true or type(Tagged.Why) ~= "string" then
		return nil
	end
	return Tagged.Why :: Reason
end

local function Broke(Message: string)
	warn(`Ledger: {Message}. that is a rule Ledger holds itself to, so this is a bug in Ledger and not in your game. please report it`)
end

local function Holds(Condition: any, Message: string)
	if Condition then
		return
	end

	Broke(Message)
	error(New(UNRESOLVED, Message), 0)
end

local function Named(Err: unknown): Reason
	local Tagged = Of(Err)
	if Tagged ~= nil then
		return Tagged
	end
	if Err == ThreadQueue.SKIPPED then
		return CLOSED
	end
	return UNRESOLVED
end

function Fault.__tostring(self: Fault): string
	return self.Message
end

table.freeze(Fault)

return table.freeze({
	New = New,
	Of = Of,
	Named = Named,
	Broke = Broke,
	Holds = Holds,
})
