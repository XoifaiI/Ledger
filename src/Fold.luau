--!strict
--!optimize 2

--[=[
    Fold: pure replay, run the base state then every op through the reducer to get current state.

    a reducer that rejects (nil), throws, or yields just skips that op so one poison op can't break
    the whole fold. the yield guard matters because Compact folds inside a datastore transform,
    where a yield would fail the save, and every fold path must skip the same ops or replays diverge.
    an op still carrying a Tx marker is a PREPARED transaction leg that has not resolved yet: it is
    skipped as if it never happened, until resolution strips the marker (committed) or removes the
    op (aborted), so the fold never reads the transaction store and stays pure.

    Return type: the Fold function
    Example usage:
        local Fold = require("./Fold")
        local State = Fold(Base, Ops, Reducer)
--]=]

local NoYield = require("./Util/NoYield")
local Types = require("./Types")

type Op = Types.Op
type Reducer<S> = Types.Reducer<S>

local function Fold<S>(Base: S, Ops: { Op }, Reducer: Reducer<S>): S
	local State = Base

	for _, Op in Ops do
		if Op.Tx ~= nil then
			continue
		end
		local Ok, Next = pcall(NoYield, Reducer, State, Op)
		if Ok and type(Next) == "table" then
			State = Next
		end
	end

	return State
end

return Fold
