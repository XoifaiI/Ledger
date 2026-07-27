--!strict
--!optimize 2

-- retry an async call with backoff, hands back pcall style (ok, ...) once it succeeds or runs out of goes

type Handler = (() -> ...any) -> (boolean, ...any)

export type Options = {
	Attempts: number?,
	Constant: number?,
	Exponent: number?,
	Handler: Handler?
}

local DEFAULT_ATTEMPTS = 5
local DEFAULT_CONSTANT = 1
local DEFAULT_EXPONENT = 1.5

local function RetryAsync(Callback: () -> ...any, Options: Options?): (boolean, ...any)
	local Config: Options = Options or {}
	local Attempts = Config.Attempts or DEFAULT_ATTEMPTS
	local Constant = Config.Constant or DEFAULT_CONSTANT
	local Exponent = Config.Exponent or DEFAULT_EXPONENT
	local Handler = Config.Handler

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

		if Result[1] or Attempt >= Attempts then
			return table.unpack(Result, 1, Result.n)
		end

		task.wait(Constant + Exponent ^ Attempt + math.random() * 0.5)
	end
end

return RetryAsync
