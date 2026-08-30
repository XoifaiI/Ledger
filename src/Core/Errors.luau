--!strict
--!optimize 2

--[=[

	Errors: Identifies Ledger errors.

	Reason reads the reason from a thrown value. Anything that is not one of Ledger's own reads as
	Unresolved, so a plain assert answers a caller the same way.

	Example usage:
		local Errors = require("./Errors")

		local Reason = Errors.Reason(Err)

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
	Reason = Reason,
})
