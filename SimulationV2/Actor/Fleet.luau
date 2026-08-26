--!strict
--!optimize 2

--[=[
	Fleet: Runs seeds across actors.

	A sweep costs what its slowest actor costs. The split is by seed and never inside one, because
	the servers of a seed are coroutines under the seeded scheduler. Each actor has its own copy of
	every module, so two seeds cannot see each other.
	The split is over indices. An index is the seed itself unless entropy is given, and then each
	worker derives its own seeds from it, so a sweep of millions never builds a list of them.

	Return type: A table with Sweep, Split and Build. The types are Answer and Report.
	Example usage:
		local Fleet = require("./Fleet")
		local Out = Fleet.Sweep(1, 1000, 8, false)
--]=]

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

export type Answer = {
	From: number,
	To: number,

	Issued: number,
	Calls: number,
	Injected: number,
	Lost: number,
	Checked: number,
	Outside: number,
	Crashes: number,
	Threw: { string },
	Broken: { string },
	Reached: { [string]: number },
	Counts: { [string]: number },
	Unknown: number,
	Warnings: number,
	Accusations: number,
	Accused: { string },
}

export type Report = {
	Answers: { Answer },
	Issued: number,
	Calls: number,
	Injected: number,
	Lost: number,
	Checked: number,
	Outside: number,
	Crashes: number,
	Threw: { string },
	Broken: { string },
	Reached: { [string]: number },
	Counts: { [string]: number },
	Unknown: number,
	Warnings: number,
	Accusations: number,
	Accused: { string },
	Seconds: number,
}

local WORKER = "Worker"
local FOLDER = "V2Fleet"

local PRINT_EVERY = 1000

local MINUTE = 60
local HOUR = 60 * MINUTE

local function Spell(Seconds: number): string
	if Seconds < MINUTE then
		return `{math.floor(Seconds)}s`
	end
	if Seconds < HOUR then
		return `{math.floor(Seconds / MINUTE)}m {math.floor(Seconds % MINUTE)}s`
	end
	return `{math.floor(Seconds / HOUR)}h {math.floor(Seconds % HOUR / MINUTE)}m`
end

local function Build(Count: number): (Folder, { Actor }, BindableEvent)
	local Template = ServerStorage:WaitForChild("LedgerDev"):WaitForChild("SimulationV2"):WaitForChild("Actor"):WaitForChild(WORKER)

	local Old = ServerScriptService:FindFirstChild(FOLDER)
	if Old ~= nil then
		Old:Destroy()
	end

	local Home = Instance.new("Folder")
	Home.Name = FOLDER

	local Done = Instance.new("BindableEvent")
	Done.Name = "Done"

	Done.Parent = Home

	local Held: { Actor } = table.create(Count) :: { Actor }
	for Index = 1, Count do
		local Made = Instance.new("Actor")
		Made.Name = `Worker{Index}`

		local Copy = Template:Clone()
		Copy.Parent = Made
		Made.Parent = Home
		Held[Index] = Made
	end

	Home.Parent = ServerScriptService
	return Home, Held, Done
end

local function Split(From: number, To: number, Count: number): { { number } }
	local Total = To - From + 1
	local Each = math.max(1, math.ceil(Total / Count))
	local Ranges: { { number } } = {}

	local At = From
	while At <= To do
		local Last = math.min(At + Each - 1, To)
		table.insert(Ranges, { At, Last })
		At = Last + 1
	end
	return Ranges
end

local function Sweep(From: number, To: number, Count: number, Misdirect: boolean?, Trace: boolean?, Entropy: string?, Seconds: number?): Report
	local Started = os.clock()
	local Ranges = Split(From, To, Count)
	local Home, Actors, Done = Build(#Ranges)
	assert(#Actors == #Ranges, "the fleet built a different number of workers than it has ranges")

	local Answers: { Answer } = {}
	local Ready = 0
	local Walked = 0
	local Said = 0
	local Total = To - From + 1
	local Tap = Done.Event:Connect(function(Held: any)
		if type(Held) ~= "table" then
			return
		end
		if Held.Ready == true then
			Ready += 1
			return
		end

		if type(Held.Progress) == "number" then
			Walked += Held.Progress
			if Walked - Said < PRINT_EVERY and Walked < Total then
				return
			end
			Said = Walked

			local Elapsed = os.clock() - Started
			local Rate = Walked / math.max(Elapsed, 0.001)
			print(
				`  sweep {Walked}/{Total} ({string.format("%.1f", 100 * Walked / Total)}%) {Spell(Elapsed)} in, {string.format("%.0f", Rate)} seeds/s, about {Spell((Total - Walked) / math.max(Rate, 0.001))} left`
			)
			return
		end

		table.insert(Answers, Held :: Answer)
	end)

	local Waking = os.clock() + 10
	while Ready < #Ranges and os.clock() < Waking do
		task.wait()
	end
	if Ready < #Ranges then
		Tap:Disconnect()
		Home:Destroy()
		error(`SimulationV2 fleet: only {Ready} of {#Ranges} worker(s) came up`, 0)
	end

	for Index, Range in Ranges do
		Actors[Index]:SendMessage("Sweep", Range[1], Range[2], Misdirect == true, Trace == true, Entropy or "")
	end

	local Deadline = os.clock() + (Seconds or math.max(120, (To - From + 1) * 3))
	while #Answers < #Ranges and os.clock() < Deadline do
		task.wait()
	end
	Tap:Disconnect()

	local Report: Report = {
		Answers = Answers,
		Issued = 0,
		Calls = 0,
		Injected = 0,
		Lost = 0,
		Checked = 0,
		Outside = 0,
		Crashes = 0,
		Threw = {},
		Broken = {},
		Reached = {},
		Counts = {},
		Unknown = 0,
		Warnings = 0,
		Accusations = 0,
		Accused = {},
		Seconds = os.clock() - Started,
	}

	for _, Held in Answers do
		Report.Issued += Held.Issued
		Report.Calls += Held.Calls
		Report.Injected += Held.Injected
		Report.Lost += Held.Lost
		Report.Checked += Held.Checked
		Report.Outside += Held.Outside
		Report.Crashes += Held.Crashes
		for _, Line in Held.Threw do
			table.insert(Report.Threw, Line)
		end
		for _, Line in Held.Broken do
			table.insert(Report.Broken, Line)
		end
		for Bucket, Count0 in Held.Reached do
			Report.Reached[Bucket] = (Report.Reached[Bucket] or 0) + Count0
		end

		Report.Unknown += Held.Unknown
		Report.Warnings += Held.Warnings
		Report.Accusations += Held.Accusations
		for Name, Count0 in Held.Counts do
			Report.Counts[Name] = (Report.Counts[Name] or 0) + Count0
		end
		for _, Line in Held.Accused do
			table.insert(Report.Accused, Line)
		end
	end

	if #Answers < #Ranges then
		table.insert(Report.Threw, `{#Ranges - #Answers} of {#Ranges} worker(s) never answered, so those seeds did not run`)
	end

	Home:Destroy()
	return Report
end

return table.freeze({
	Sweep = Sweep,
	Split = Split,
	Build = Build,
})
