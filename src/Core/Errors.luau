--!strict
--!optimize 2

--[=[

	Errors: An error that carries the reason it becomes.

	New builds one, Of and Named read the reason back out of a raised value, and Holds throws one when
	a rule of Ledger breaks. Broke warns about the same without throwing.

	Return type: A table with New, Of, Named, Broke and Holds.
	Example usage:
		local Errors = require("./Errors")
		error(Errors.New(Reasons.Busy, "the key has a leg on it"))
--]=]

local Tagged = require("../Util/Tagged")
local ThreadQueue = require("../Util/ThreadQueue")
local Reasons = require("./Reasons")

type Reason = Reasons.Reason

type FaultImpl = {
	__tostring: (self: Errors) -> string,
}

export type Errors = setmetatable<{
	read Ledger: true,
	read Why: Reason,
	read Message: string,
}, FaultImpl>

local CLOSED = Reasons.Closed
local UNRESOLVED = Reasons.Unresolved

local Errors = {} :: FaultImpl

local function New(Why: Reason, Message: string): Errors
	return table.freeze(setmetatable({ [Tagged.TAG] = true, Why = Why, Message = Message }, Errors)) :: any
end

local function Of(Err: unknown): Reason?
	if not Tagged.Is(Err) then
		return nil
	end

	local Held = Err :: { Why: unknown }
	if type(Held.Why) ~= "string" then
		return nil
	end
	return Held.Why :: Reason
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
	local Held = Of(Err)
	if Held ~= nil then
		return Held
	end
	if Err == ThreadQueue.SKIPPED then
		return CLOSED
	end
	return UNRESOLVED
end

function Errors.__tostring(self: Errors): string
	return self.Message
end

table.freeze(Errors)

return table.freeze({
	New = New,
	Of = Of,
	Named = Named,
	Broke = Broke,
	Holds = Holds,
})
