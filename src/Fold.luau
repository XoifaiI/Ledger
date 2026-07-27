--!strict
--!optimize 2

-- pure replay, base state plus every op through the reducer. a rejected, throwing, yielding or tx stamped op is skipped

local NoYield = require("./Util/NoYield")
local Types = require("./Types")

type Op = Types.Op
type Reducer<S> = Types.Reducer<S>

local function Fold<S>(Base: S, Ops: { Op }, Reducer: Reducer<S>, Mark: string?): (S, boolean)
	local State = Base
	local Took = false

	for _, Op in Ops do
		if Op.Tx ~= nil then
			continue
		end
		local Ok, Next = pcall(NoYield, Reducer, State, Op)
		if Ok and type(Next) == "table" then
			State = Next
			if Op.Id == Mark then
				Took = true
			end
		end
	end

	return State, Took
end

return Fold
