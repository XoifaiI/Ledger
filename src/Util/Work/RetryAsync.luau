--!strict
--!optimize 2

--[=[
	RetryAsync: Calls a function again after a failure.

	The delay increases after each attempt.
	An error that carries a reason has already settled, so the retries stop.

	Return type: A function that gives back (Ok, Result).
	Example usage:
		local RetryAsync = require("./RetryAsync")
		local Ok, Value = RetryAsync(Call, { Attempts = 3 })
--]=]

local Say = require("../Tools/Say")
local Carried = require("../Tools/Carried")

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

local function RetryAsync(Callback: () -> ...any, Limits: Limits?, Handler: Handler?): (boolean, ...any)
	local Bounds: Limits = Limits or {}
	local Constant = Bounds.Constant or DEFAULT_CONSTANT
	local Exponent = Bounds.Exponent or DEFAULT_EXPONENT
	local Jitter = Bounds.Jitter or DEFAULT_JITTER

	local Attempt = 0

	while true do
		Attempt += 1

		local Result
		if Handler then
			Result = table.pack(Handler(Callback))
		else
			Result = table.pack(pcall(Callback))
		end

		local Allowed = Bounds.Attempts or DEFAULT_ATTEMPTS
		if not Result[1] then
			Say.Warn(`Ledger: RetryAsync attempt {Attempt}/{Allowed}: {Result[2]}`)
		end

		if Result[1] or Attempt >= Allowed or Carried.Is(Result[2]) then
			return table.unpack(Result, 1, Result.n)
		end

		local Backoff = Constant + Exponent ^ Attempt + math.random() * Jitter
		if Backoff > 0 then
			task.wait(Backoff)
		end
	end
end

return RetryAsync
