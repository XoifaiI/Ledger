--!strict
--!optimize 2

-- pure replay, base state plus every op through the reducer. a rejected, throwing, yielding or tx stamped op is skipped

local Step = require("./Step")
local Types = require("../Types")

type Op = Types.Op
type Reducer<S> = Types.Reducer<S>

local function Fold<S>(Base: S, Ops: { Op }, Reducer: Reducer<S>, Mark: string?): (S, boolean)
	local State = Base
	local Took = false

	for _, Op in Ops do
		if Op.Tx ~= nil then
			continue
		end
		local Next = Step(Reducer, State, Op)
		if Next ~= nil then
			State = Next
			if Op.Id == Mark then
				Took = true
			end
		end
	end

	return State, Took
end

return Fold
