--!strict
--!optimize 2

--[=[
	Fleet: Runs seeds across actors.

	A sweep costs what its slowest actor costs. The split is by seed and never inside one, because
	the servers of a seed are coroutines under the seeded scheduler. Each actor has its own copy of
	every module, so two seeds cannot see each other.

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
	Seconds: number,
}

local WORKER = "Worker"
local FOLDER = "V2Fleet"

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

local function Sweep(From: number, To: number, Count: number, Misdirect: boolean?, Trace: boolean?, Seconds: number?): Report
	local Started = os.clock()
	local Ranges = Split(From, To, Count)
	local Home, Actors, Done = Build(#Ranges)
	assert(#Actors == #Ranges, "the fleet built a different number of workers than it has ranges")

	local Answers: { Answer } = {}
	local Ready = 0
	local Tap = Done.Event:Connect(function(Held: any)
		if type(Held) == "table" and Held.Ready == true then
			Ready += 1
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
		Actors[Index]:SendMessage("Sweep", Range[1], Range[2], Misdirect == true, Trace == true)
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
