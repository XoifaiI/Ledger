--!strict
--!optimize 2

--[=[
	Liveness: Asks whether the system settles on its own.

	Safety says nothing bad happened. Liveness says something good happens in the end. It moves the
	clock and runs the pass the ticker would have run. It never calls Resettle, because that would
	prove an operator can fix it and not that Ledger does.

	Return type: A table with Converge and its windows. The type is Report.
	Example usage:
		local Alive = Liveness.Converge(Plate, Where, Marks, Format, Store, Names)
--]=]

local Disk = require("./Disk")
local Invariants = require("./Invariants")
local Lib = require("./Lib")
local Time = require("./Time")

type Disk = Disk.Disk

export type Report = {
	Ok: boolean,
	Left: number,
	Rounds: number,
	Says: string?,
}

local ROUND_SECONDS = 86400
local ROUND_LIMIT = 25

local SWEEP_REAP_EVERY = 10
local STUCK_LIMIT = SWEEP_REAP_EVERY + 4

assert(ROUND_SECONDS * ROUND_LIMIT < 30 * 86400, "a convergence window that reaches the prune horizon watches recovery write money off and calls it a bug")
assert(STUCK_LIMIT > SWEEP_REAP_EVERY and ROUND_LIMIT > STUCK_LIMIT, "a stall window shorter than the reap cadence fails a run for waiting on the one thing that is slow on purpose")

local function Waiting(Board: Disk, Where: Invariants.Where, Marks: { string }, Format: any): string
	local Named = Invariants.Unfinished(Board, Where, Marks, Format)
	for _, Line in Invariants.Markers(Board, Marks, Lib.Horizons.REAP, Time.Read()) do
		table.insert(Named, Line)
	end
	return table.concat(Named, "; ")
end

local function Converge(Board: Disk, Where: Invariants.Where, Marks: { string }, Format: any, Store: any, Names: { any }): Report
	local Left = Invariants.Unsettled(Board, Where, Marks, Format)
	if Left == 0 then
		return { Ok = true, Left = 0, Rounds = 0, Says = nil }
	end

	local Sweep = Lib.Sweep()
	local Opened = Sweep.Passes
	local Stuck = 0
	local Rounds = 0

	while Left > 0 and Rounds < ROUND_LIMIT do
		Rounds += 1

		Time.Advance(ROUND_SECONDS)
		local Ran = pcall(function()
			for _, Key in Names do
				Store:Peek(Key):Wait()
			end
			Sweep:Pass()
		end)

		local Now = Invariants.Unsettled(Board, Where, Marks, Format)
		Stuck = if Now < Left then 0 else Stuck + 1
		Left = Now

		if not Ran then
			return {
				Ok = false,
				Left = Left,
				Rounds = Rounds,
				Says = "the recovery sweep threw, so nothing was going to settle on its own",
			}
		end
		if Stuck >= STUCK_LIMIT then
			return {
				Ok = false,
				Left = Left,
				Rounds = Rounds,
				Says = `nothing moved for {STUCK_LIMIT} rounds over {Sweep.Passes - Opened} sweep pass(es), still waiting on: {Waiting(Board, Where, Marks, Format)}`,
			}
		end
	end

	if Left > 0 then
		return {
			Ok = false,
			Left = Left,
			Rounds = Rounds,
			Says = `after {ROUND_LIMIT} quiet rounds over {Sweep.Passes - Opened} sweep pass(es), still waiting on: {Waiting(Board, Where, Marks, Format)}`,
		}
	end

	return { Ok = true, Left = 0, Rounds = Rounds, Says = nil }
end

return table.freeze({
	Converge = Converge,
	ROUND_SECONDS = ROUND_SECONDS,
	STUCK_LIMIT = STUCK_LIMIT,
	ROUND_LIMIT = ROUND_LIMIT,
})
