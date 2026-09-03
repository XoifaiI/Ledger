--!strict
--!optimize 2

--[=[

	Queues: One rule per case for the queues every write stands on.

	Order, exclusion and errors: tasks run in the order they arrived, never two at once, and one that
	throws tells its own caller and nobody else. The first task runs inline rather than queued, and may
	yield while the queue stays shut.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau
--]=]

local Suite = require("../Suite")

local KeyedRetryQueue = require("../../src/Util/KeyedRetryQueue")
local SetInterval = require("../../src/Util/SetInterval")
local ThreadQueue = require("../../src/Util/ThreadQueue")

type Case = Suite.Case

local SLOW = 0.2
local QUICK = 0.03

local Cases = Suite.File("Queues")

type Bench = {
	Order: { string },
	Overlaps: number,
	Live: number,
}

local function Idle(Queue: any): () -> boolean
	return function(): boolean
		return not Queue.Busy and Queue:GetLength() == 0
	end
end

local function Bench(): Bench
	return { Order = {}, Overlaps = 0, Live = 0 }
end

local function Job(T: Case, Watch: Bench, Name: string, Wait: number): () -> string
	return function(): string
		Watch.Live += 1
		if Watch.Live > 1 then
			Watch.Overlaps += 1
		end
		table.insert(Watch.Order, Name)
		if Wait > 0 then
			T:Wait(Wait)
		end
		Watch.Live -= 1
		return Name
	end
end

Cases.Case("tasks behind a yielding fast path run in the order they arrived", function(T: Case)
	local Queue = ThreadQueue.New(T.Turn)
	local Watch = Bench()

	T:Spawn(function()
		Queue:SubmitAsync(Job(T, Watch, "A", SLOW))
	end)
	T:Wait(QUICK)
	for _, Name in { "B", "C", "D" } do
		T:Spawn(function()
			Queue:SubmitAsync(Job(T, Watch, Name, QUICK))
		end)
	end
	T:Until(function(): boolean
		return #Watch.Order == 4 and Idle(Queue)()
	end)

	T:Is("the order they ran in", table.concat(Watch.Order, ""), "ABCD")
	T:Is("how many ran at the same time as another", Watch.Overlaps, 0)
	T:Is("the queue is idle afterwards", Queue.Busy, false)
	T:Is("tasks left over", Queue:GetLength(), 0)
end)

Cases.Case("a fast path task that throws does not wedge the queue", function(T: Case)
	local Queue = ThreadQueue.New(T.Turn)
	local Raised, Behind = nil, nil

	T:Spawn(function()
		Raised = not pcall(function()
			Queue:SubmitAsync(function()
				T:Wait(QUICK)
				error("injected fast path failure")
			end)
		end)
	end)
	T:Wait(QUICK / 2)
	T:Spawn(function()
		Behind = select(
			2,
			pcall(function(): string
				return Queue:SubmitAsync(function(): string
					return "B"
				end)
			end)
		)
	end)
	T:Until(function(): boolean
		return Raised ~= nil and Behind ~= nil
	end)

	T:Is("the caller was told its task threw", Raised, true)
	T:Is("the task lined up behind it still ran", Behind, "B")
	T:Is("the queue is idle afterwards", Queue.Busy, false)
end)

Cases.Case("a queued task that throws does not stop the ones behind it", function(T: Case)
	local Queue = ThreadQueue.New(T.Turn)
	local Raised, Behind = nil, nil

	T:Spawn(function()
		Queue:SubmitAsync(function()
			T:Wait(QUICK)
		end)
	end)
	T:Wait(QUICK / 2)
	T:Spawn(function()
		Raised = not pcall(function()
			Queue:SubmitAsync(function()
				error("injected queued failure")
			end)
		end)
	end)
	T:Spawn(function()
		Behind = select(
			2,
			pcall(function(): string
				return Queue:SubmitAsync(function(): string
					return "C"
				end)
			end)
		)
	end)
	T:Until(function(): boolean
		return Raised ~= nil and Behind ~= nil
	end)

	T:Is("the caller was told its task threw", Raised, true)
	T:Is("the task behind the one that threw still ran", Behind, "C")
	T:Is("the queue is idle afterwards", Queue.Busy, false)
end)

Cases.Case("a task submitted from inside the fast path waits for it to finish", function(T: Case)
	local Queue = ThreadQueue.New(T.Turn)
	local Order: { string } = {}
	local Returned = false

	T:Spawn(function()
		Queue:SubmitAsync(function()
			table.insert(Order, "outer start")
			T:Wait(QUICK)
			table.insert(Order, "outer end")
		end)
		Returned = true
	end)
	T:Wait(QUICK / 2)
	T:Spawn(function()
		Queue:SubmitAsync(function()
			table.insert(Order, "inner")
		end)
	end)
	T:Until(function(): boolean
		return #Order == 3 and Returned
	end)

	T:Is("when the one submitted underneath ran", table.concat(Order, ","), "outer start,outer end,inner")
	T:Is("the fast path caller got its answer back", Returned, true)
end)

Cases.Case("skipping does not touch the task already running", function(T: Case)
	local Queue = ThreadQueue.New(T.Turn)
	local Answers: { string } = {}

	T:Spawn(function()
		local Ok = pcall(function()
			Queue:SubmitAsync(function()
				T:Wait(SLOW)
			end)
		end)
		table.insert(Answers, `A={Ok}`)
	end)
	T:Wait(QUICK)
	for _, Name in { "B", "C", "D" } do
		T:Spawn(function()
			local Ok = pcall(function()
				Queue:SubmitAsync(function(): string
					return Name
				end)
			end)
			table.insert(Answers, `{Name}={Ok}`)
		end)
	end
	T:Wait(QUICK / 2)

	Queue:SkipToLastEnqueued()
	T:Until(function(): boolean
		return #Answers == 4 and Idle(Queue)()
	end)

	table.sort(Answers)
	T:Is("who got through and who was dropped", table.concat(Answers, ","), "A=true,B=false,C=false,D=true")
	T:Is("the queue is idle afterwards", Queue.Busy, false)
end)

Cases.Case("one key only ever has one queue running on it", function(T: Case)
	local State: any = { Scheduler = T.Turn, Attempts = 1, Queues = {} }
	local Watch = Bench()
	local Built, Seen = 0, {}

	local Returned = 0

	local function Fire(Name: string, Wait: number): () -> ()
		return function()
			KeyedRetryQueue.Run(State, "k", function(): string
				local Queue = State.Queues.k
				if Queue ~= nil and not Seen[Queue] then
					Seen[Queue] = true
					Built += 1
				end
				return Job(T, Watch, Name, Wait)()
			end)
			Returned += 1
		end
	end

	T:Spawn(Fire("A", SLOW))
	T:Wait(QUICK / 2)
	for _, Name in { "B", "C", "D" } do
		T:Spawn(Fire(Name, SLOW))
		T:Wait(QUICK / 4)
	end

	T:Until(function(): boolean
		return Returned >= 1
	end)
	T:Spawn(Fire("E", QUICK))

	T:Until(function(): boolean
		return #Watch.Order == 5 and next(State.Queues) == nil
	end)

	local Left = 0
	for _ in State.Queues do
		Left += 1
	end

	T:Is("the order they ran in", table.concat(Watch.Order, ""), "ABCDE")
	T:Is("how many ran at the same time as another", Watch.Overlaps, 0)
	T:Is("how many queues the key was given", Built, 1)
	T:Is("queues left in the map once everything settled", Left, 0)
end)

Cases.Case("a queue whose thread was cancelled is taken over by the next caller, and says Ledger broke", function(T: Case)
	local Queue = ThreadQueue.New(T.Turn)

	local Holder = T:Spawn(function()
		Queue:SubmitAsync(function()
			T:Wait(SLOW)
		end)
	end)
	T:Wait(QUICK)

	local Waiting = T:Spawn(function()
		Queue:SubmitAsync(function() end)
	end)
	T:Wait(QUICK)
	T.Turn.Cancel(Holder)

	local Took = Queue:SubmitAsync(function(): string
		return "through"
	end)

	T:Is("the call that found the queue abandoned", Took, "through")
	T:Ok(
		"the task left waiting on the dead holder still ran",
		T:Until(function(): boolean
			return coroutine.status(Waiting) == "dead"
		end)
	)
	T:Accuses("it named itself rather than wedging the key", "was cancelled")
end)

Cases.Case("a job on a timer that throws says Ledger broke and keeps running", function(T: Case)
	local Runs = 0
	local Ticker = SetInterval(T.Turn, 1, function()
		Runs += 1
		error("injected timer failure")
	end)

	T:Advance(1)
	T:Until(function(): boolean
		return Runs >= 1
	end)
	T:Advance(1)
	T:Until(function(): boolean
		return Runs >= 2
	end)
	T.Turn.Cancel(Ticker)

	T:Is("times it ran, so a throw does not stop the timer", Runs, 2)
	T:Accuses("it named itself", "runs on a timer threw")
end)

return Cases
