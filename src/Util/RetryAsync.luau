--!strict
--!optimize 2

--[=[
    RetryAsync: retry an async call with backoff, hands back the pcall style (ok, ...) once it succeeds or the attempts run out, warning on every failed attempt

    Return type: the RetryAsync function, which returns (boolean, ...any)
    Example usage:
        local RetryAsync = require("./RetryAsync")
        local Ok, Value = RetryAsync(function() return Store:GetAsync("Key") end, { Attempts = 5 })
--]=]

type Handler = (() -> ...any) -> (boolean, ...any)
type Retryable = (Reason: any) -> boolean

export type Options = {
	Attempts: number?,
	Constant: number?,
	Exponent: number?,
	Handler: Handler?,
	Retryable: Retryable?,
}

local DEFAULT_ATTEMPTS = 5
local DEFAULT_CONSTANT = 1
local DEFAULT_EXPONENT = 1.5

local function RetryAsync(Callback: () -> ...any, Options: Options?): (boolean, ...any)
	local Config: Options = Options or {}
	local Attempts = Config.Attempts or DEFAULT_ATTEMPTS
	local Constant = Config.Constant or DEFAULT_CONSTANT
	local Exponent = Config.Exponent or DEFAULT_EXPONENT
	local Handler, Retryable = Config.Handler, Config.Retryable

	local Attempt = 0

	while true do
		Attempt += 1

		local Result
		if Handler then
			Result = table.pack(Handler(Callback))
		else
			Result = table.pack(pcall(Callback))
		end

		if not Result[1] then
			warn(`RetryAsync attempt {Attempt}/{Attempts}: {Result[2]}`)
		end

		local Permanent = not Result[1] and Retryable ~= nil and not Retryable(Result[2])

		if Result[1] or Attempt >= Attempts or Permanent then
			return table.unpack(Result, 1, Result.n)
		end

		task.wait(Constant + Exponent ^ Attempt + math.random() * 0.5)
	end
end

return RetryAsync
