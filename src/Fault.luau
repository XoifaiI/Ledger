--!strict
--!optimize 2

-- an error that carries the reason it turns into, so a failure names itself where it happens instead of being read back out of its message later

local ThreadQueue = require("./Util/ThreadQueue")
local Reasons = require("./Reason")
local Types = require("./Types")

type Reason = Types.Reason

local CLOSED = Reasons.Closed
local UNRESOLVED = Reasons.Unresolved

export type Fault = {
	read Ledger: true,
	read Why: Reason,
	read Message: string
}

local Meta = table.freeze({
	__tostring = function(self: Fault): string
		return self.Message
	end
})

local function New(Why: Reason, Message: string): Fault
	return table.freeze(setmetatable({ Ledger = true, Why = Why, Message = Message }, Meta)) :: any
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

return table.freeze({
	New = New,
	Of = Of,
	Named = Named,
	Broke = Broke,
	Holds = Holds
})
