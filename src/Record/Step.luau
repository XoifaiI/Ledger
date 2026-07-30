--!strict
--!optimize 2

-- one op through a reducer with the guard rails on. a reducer that throws, yields or hands back anything but a table refused the op

local NoYield = require("../Util/NoYield")
local Types = require("../Types")

type Op = Types.Op
type Reducer<S> = Types.Reducer<S>

local function Step<S>(Reducer: Reducer<S>, State: S, Op: Op): S?
	local Ok, Next = pcall(NoYield, Reducer, State, Op)
	return if Ok and type(Next) == "table" then Next else nil
end

return Step
