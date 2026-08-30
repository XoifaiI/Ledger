--!strict
--!optimize 2

--[=[

	Apply: Puts one op through a reducer, with the guards on.

	A reducer that throws, yields, or gives back something that is not a table has refused the op.

	Return type: A function that gives back the next state, or nothing.
	Example usage:
		local Apply = require("./Apply")
		local Next = Apply(Reducer, State, Op)
--]=]

local NoYield = require("../Util/NoYield")
local Shapes = require("../Core/Shapes")

type Op = Shapes.Op
type Reducer<S> = Shapes.Reducer<S>

local function Apply<S>(Reducer: Reducer<S>, State: S, Op: Op): S?
	local Ok, Next = NoYield.Try(Reducer, State, Op)
	return if Ok and type(Next) == "table" then Next else nil
end

return Apply
