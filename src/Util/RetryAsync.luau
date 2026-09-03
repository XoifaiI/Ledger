--!strict
--!optimize 2

--[=[

	RetryAsync: Calls a function again after a failure.

	The delay grows with each attempt and waits on the scheduler it was given, within the limits it
	was given. A failure that already carries a reason has settled, so it is not retried. The cap is
	read again on each attempt rather than once, so a caller that is closing down can lower it while
	a call is already retrying and have the next attempt be the last.

	Return type: A function that gives back (Ok, Result).
	Example usage:
		local RetryAsync = require("./RetryAsync")
		local Ok, Value = RetryAsync(Scheduler, Call, { Attempts = 3 })
--]=]

local Engine = require("./Engine")

local Tagged = require("./Tagged")

type Handler = (() -> ...any) -> (boolean, ...any)

export type Limits = {
	Attempts: number?,
	Constant: number?,
	Exponent: number?,
	Jitter: number?,
}

local DEFAULT_ATTEMPTS = 5
local DEFAULT_CONSTANT = 1
local DEFAULT_EXPONENT = 1.5
local DEFAULT_JITTER = 0.5

local function RetryAsync(Scheduler: Engine.Scheduler, Callback: () -> ...any, Limits: Limits?, Handler: Handler?): (boolean, ...any)
	local Bounds: Limits = Limits or {}
	local Constant = Bounds.Constant or DEFAULT_CONSTANT
	local Exponent = Bounds.Exponent or DEFAULT_EXPONENT
	local Jitter = Bounds.Jitter or DEFAULT_JITTER

	local Attempt = 0

	while true do
		Attempt += 1
		local Allowed = Bounds.Attempts or DEFAULT_ATTEMPTS

		local Result
		if Handler then
			Result = table.pack(Handler(Callback))
		else
			Result = table.pack(pcall(Callback))
		end

		if not Result[1] then
			warn(`Ledger: a call failed on attempt {Attempt} of {Allowed} and will be tried again: {Result[2]}`)
		end

		if Result[1] or Attempt >= Allowed or Tagged.Is(Result[2]) then
			return table.unpack(Result, 1, Result.n)
		end

		local Backoff = Constant + Exponent ^ Attempt + Scheduler.Roll() * Jitter
		if Backoff > 0 then
			Scheduler.Wait(Backoff)
		end
	end
end

return RetryAsync
