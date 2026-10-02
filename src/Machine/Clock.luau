--!strict
--!optimize 2

--[=[
	Clock: Plumbing. This server's clock as a stamp, in whole seconds since Limits.EPOCH.

	Only the runner and the objects read it. A machine hears the time on each reply instead.

	Return type: A table with Now.
	Example usage:
		local Stamp = Clock.Now()
--]=]

local Limits = require("../Core/Constants/Limits")

local Clock = {}

function Clock.Now(): number
	return os.time() - Limits.EPOCH
end

return Clock
