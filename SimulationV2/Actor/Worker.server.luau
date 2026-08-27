--!strict
--!optimize 2

--[=[
	Worker: One worker of the actor fleet.

	It waits in ServerStorage until Fleet copies it under an Actor. It takes a first and a last index,
	runs them as a single threaded sweep would, and answers one time with everything it found.
	An index is the seed itself unless the fleet passed entropy, and then the worker draws its own
	seeds from it, so no list of them ever crosses between actors.

	Return type: Nothing. It binds a message handler.
	Example usage:
		Fleet clones this under an Actor and sends it a range.
--]=]

local ServerStorage = game:GetService("ServerStorage")

local Root = ServerStorage:WaitForChild("LedgerDev"):WaitForChild("SimulationV2")
local Simulator = require(Root:WaitForChild("Simulator")) :: any
local Marks = require(Root:WaitForChild("Marks")) :: any
local Seeds = require(Root:WaitForChild("Seeds")) :: any
local Say = require(Root.Parent:WaitForChild("src"):WaitForChild("Util"):WaitForChild("Tools"):WaitForChild("Say")) :: any

Say.Quiet(true)

local PROGRESS_EVERY = 25
local ACCUSED_KEPT = 50

local Actor = assert(script:GetActor(), "the fleet worker only runs inside an Actor")

local Home = assert(Actor.Parent, "the worker's actor is not in the fleet folder")
local Done = Home:WaitForChild("Done") :: BindableEvent

Actor:BindToMessageParallel("Sweep", function(From: number, To: number, Misdirect: boolean, Trace: boolean, Entropy: string)
	local Threw: { string } = {}
	local Broken: { string } = {}
	local Reached: { [string]: number } = {}
	local Sheet = Marks.New()
	local Accused: { string } = {}
	local Issued, Calls, Injected, Lost, Checked, Outside, Crashes = 0, 0, 0, 0, 0, 0, 0
	local Warnings, Accusations = 0, 0
	local Since = 0

	local Options = { Misdirect = Misdirect, Trace = Trace }

	local Drawn: { number } = {}
	if Entropy ~= "" then
		task.synchronize()
		local Fine, Held = pcall(Seeds.Spread, Entropy, From, To)
		task.desynchronize()
		if Fine then
			Drawn = Held
		else
			table.insert(Threw, `drawing seeds for indices {From} to {To} threw: {tostring(Held)}`)
		end
	end
	local Spread = #Drawn > 0

	for Index = From, To do
		local Seed = if Spread then Drawn[Index - From + 1] else Index
		local Fine, Out = pcall(Simulator.Run, Seed, Options)

		Since += 1
		if Since >= PROGRESS_EVERY then
			Since = 0
			task.synchronize()
			Done:Fire({ Progress = PROGRESS_EVERY })
			task.desynchronize()
		end

		if not Fine then
			table.insert(Threw, `seed {Seed}: the run itself threw: {tostring(Out)}`)
			continue
		end

		Issued += Out.Issued
		Calls += Out.Calls
		Injected += Out.Injected
		Lost += Out.Lost
		Checked += Out.Books.Checked
		Outside += #Out.Books.Broken
		Crashes += Out.Crashes

		for _, Record in Out.Said do
			Warnings += Record.Count
			Sheet:Note(Record.Says, Record.Count)
			if string.find(Record.Says, Marks.ACCUSED, 1, true) == nil then
				continue
			end

			Accusations += Record.Count
			if #Accused < ACCUSED_KEPT then
				table.insert(Accused, `seed {Seed}: {Record.Says}`)
			end
		end

		for _, Line in Out.Threw do
			table.insert(Threw, `seed {Seed}: {Line}`)
		end
		for _, Line in Out.Broken do
			table.insert(Broken, `seed {Seed}: {Line}`)
		end

		for Bucket, Count in Out.Cover.Counts do
			if Count > 0 then
				Reached[Bucket] = (Reached[Bucket] or 0) + Count
			end
		end
	end

	task.synchronize()
	Done:Fire({
		From = From,
		To = To,

		Issued = Issued,
		Calls = Calls,
		Injected = Injected,
		Lost = Lost,
		Checked = Checked,
		Outside = Outside,
		Crashes = Crashes,
		Threw = Threw,
		Broken = Broken,
		Reached = Reached,
		Counts = Sheet.Counts,
		Unknown = Sheet.Unknown,
		Warnings = Warnings,
		Accusations = Accusations,
		Accused = Accused,
	})
end)

Done:Fire({ Ready = true })
