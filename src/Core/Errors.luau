--!strict
--!optimize 2

--[=[

	Errors: Raises and identifies Ledger errors.

	Raise throws one, and is the only place the tag is written. Reason reads the reason back off a
	thrown value, and anything that is not one of Ledger's own reads as Unresolved, so a plain assert
	answers a caller the same way.

	Return type: A table with Raise and Reason. The type is Error.
	Example usage:
		local Errors = require("./Errors")
		Errors.Raise(Reasons.Busy, "that key has a transaction parked on it")
--]=]

local Tagged = require("../Util/Tagged")
local Messages = require("./Constants/Messages")
local Reasons = require("./Constants/Reasons")

type Reason = Reasons.Reason

export type Error = {
	Ledger: true,
	Why: Reason,
	Message: string,
}

local function IsError(Value: unknown): boolean
	return Tagged.Is(Value) and type((Value :: { Why: unknown }).Why) == "string"
end

local function Raise(Why: Reason, Message: string): never
	error(
		{
			[Messages.TAG] = true,
			Why = Why,
			Message = Message,
		} :: Error,
		0
	)
end

local function Reason(Err: unknown): Reason
	if Err == Messages.SKIPPED then
		return Reasons.Closed
	end
	if not IsError(Err) then
		return Reasons.Unresolved
	end

	return (Err :: Error).Why
end

return table.freeze({
	Raise = Raise,
	Reason = Reason,
})
