--!strict
--!optimize 2

--[=[
	Worker: One worker of the actor fleet.

	It waits in ServerStorage until Fleet copies it under an Actor. It takes a first and a last seed,
	runs them as a single threaded sweep would, and answers one time with everything it found.

	Return type: Nothing. It binds a message handler.
	Example usage:
		Fleet clones this under an Actor and sends it a range.
--]=]

local ServerStorage = game:GetService("ServerStorage")

local Root = ServerStorage:WaitForChild("LedgerDev"):WaitForChild("SimulationV2")
local Simulator = require(Root:WaitForChild("Simulator")) :: any
local Say = require(Root.Parent:WaitForChild("src"):WaitForChild("Util"):WaitForChild("Say")) :: any

Say.Quiet(true)

local Actor = assert(script:GetActor(), "the fleet worker only runs inside an Actor")

local Home = assert(Actor.Parent, "the worker's actor is not in the fleet folder")
local Done = Home:WaitForChild("Done") :: BindableEvent

Actor:BindToMessageParallel("Sweep", function(From: number, To: number, Misdirect: boolean, Trace: boolean)
	local Threw: { string } = {}
	local Broken: { string } = {}
	local Reached: { [string]: number } = {}
	local Said: { [string]: number } = {}
	local Issued, Calls, Injected, Lost, Checked, Outside, Crashes = 0, 0, 0, 0, 0, 0, 0

	for Seed = From, To do
		local Fine, Out = pcall(function(): any
			return Simulator.Run(Seed, { Misdirect = Misdirect, Trace = Trace })
		end)

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
			Said[Record.Says] = (Said[Record.Says] or 0) + Record.Count
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
		Said = Said,
	})
end)

Done:Fire({ Ready = true })
