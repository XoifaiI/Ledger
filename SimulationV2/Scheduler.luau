--!strict
--!optimize 2

--[=[
	Scheduler: Decides which thread takes the next turn.

	A run replays only while the seed decides that order and nothing else does. Nothing inside a run
	may call task.wait. Run waits for every thread it started. Drain takes a number of turns and then
	stops, whoever is left.

	Return type: A table with New and STALL_LIMIT. The type is Scheduler.
	Example usage:
		local Turn = Scheduler.New(Seed)
		Turn:Spawn(Body)
		Turn:Run()
--]=]

local Scheduler = {}
Scheduler.__index = Scheduler

export type Scheduler = typeof(setmetatable(
	{} :: {
		Rng: Random,
		Ready: { thread },
		Live: number,
		Steps: number,
		Stalls: number,
		GaveUp: boolean
	},
	Scheduler
))

local STALL_LIMIT = 4096

function Scheduler.New(Seed: number): Scheduler
	return setmetatable({
		Rng = Random.new(Seed),
		Ready = {},
		Live = 0,
		Steps = 0,
		Stalls = 0,
		GaveUp = false
	}, Scheduler)
end

function Scheduler.Spawn(self: Scheduler, Body: () -> ())
	self.Live += 1

	local Thread = coroutine.create(function()
		local Fine, Raised = pcall(Body)
		self.Live -= 1
		if not Fine then
			warn(`SimulationV2 scheduler: a driven thread died, {tostring(Raised)}`)
		end
	end)
	table.insert(self.Ready, Thread)
end

function Scheduler.Wait(self: Scheduler)
	table.insert(self.Ready, coroutine.running())
	coroutine.yield()
end

function Scheduler.Step(self: Scheduler): boolean
	local Count = #self.Ready
	if Count == 0 then
		return false
	end

	local Thread = table.remove(self.Ready, self.Rng:NextInteger(1, Count)) :: thread
	self.Steps += 1

	if coroutine.status(Thread) ~= "suspended" then
		return true
	end

	local Fine, Raised = coroutine.resume(Thread)
	if not Fine then
		warn(`SimulationV2 scheduler: a thread errored, {tostring(Raised)}`)
	end
	return true
end

function Scheduler.Drain(self: Scheduler, Limit: number): number
	for _ = 1, Limit do
		if not self:Step() then
			break
		end
	end
	return self.Steps
end

function Scheduler.Run(self: Scheduler)
	while self.Live > 0 do
		if self:Step() then
			continue
		end

		self.Stalls += 1
		if self.Stalls > STALL_LIMIT then
			self.GaveUp = true
			warn(`SimulationV2 scheduler: gave up with {self.Live} thread(s) still running`)
			return
		end
		task.wait()
	end

	while self:Step() do
	end
end

table.freeze(Scheduler)

return table.freeze({
	New = Scheduler.New,
	STALL_LIMIT = STALL_LIMIT
})
