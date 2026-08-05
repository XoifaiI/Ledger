--!strict
--!optimize 2

--[=[
	Step: Puts one op through a reducer, with the guards on.
	
	A reducer that throws, yields, or gives back something that is not a table has refused the op.
	
	Return type: A function that gives back the next state, or nothing.
	Example usage:
		local Step = require("./Step")
		local Next = Step(Reducer, State, Op)
--]=]

local NoYield = require("../Util/NoYield")
local Op = require("../Contract/Op")

type Op = Op.Op
type Reducer<S> = Op.Reducer<S>

local function Step<S>(Reducer: Reducer<S>, State: S, Op: Op): S?
	local Ok, Next = pcall(NoYield, Reducer, State, Op)
	return if Ok and type(Next) == "table" then Next else nil
end

return Step
