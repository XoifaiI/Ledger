--!strict
--!optimize 2

--[=[
	Virtual: A scheduler whose clock only moves when nothing is left to run.

	Everything ready runs before the clock moves, and time then jumps straight to the next deadline,
	so a run costs what its work costs and never what its waits ask for. Done is one condition,
	nothing ready and nothing sleeping, so it cannot disagree with itself the way a live count beside
	a queue can.
	Ready threads sit in a ring that is written over rather than grown, because a queue that leaves
	holes in a growing array is moved into the hash part and every read after that is a lookup.
	Sleeping threads sit in a heap of two plain arrays that sift a hole downward, since a swap of two
	scattered slots is what a heap does and buffers lose at that.
	Resume runs a thread on the spot and Defer queues it. Keep them apart: code waiting on a queue
	cannot be woken by a wake that was put in the queue behind it.
	A thread that throws is kept rather than printed, because a scheduler that warns would put its own
	words in whatever else is reading them.

	Return type: A table with New. It answers the Scheduler shape and adds the driving. The type is Virtual.
	Example usage:
		local Turn = Virtual.New()
		Turn.Defer(Body)
		Turn.Run()
--]=]

local Engine = require("../Util/Engine")

export type Virtual = Engine.Scheduler & {
	read Step: () -> boolean,
	read Drain: (Limit: number) -> number,
	read Run: (Limit: number?) -> boolean,
	read Done: () -> boolean,
	read Advance: (Seconds: number) -> (),
	read Sleeping: () -> number,
	read Ready: () -> number,
	read Steps: () -> number,
	read Failures: () -> { string },
}

local EPOCH = 1700000000
local READY = 64
local STEP_CAP = 1048576

local function New(From: number?): Virtual
	local Held = From or EPOCH
	local Taken = 0
	local Failed: { string } = {}

	local Queue: { thread } = table.create(READY) :: { thread }
	local Capacity = READY
	local Head = 0
	local Tail = 0

	local Deadlines: { number } = {}
	local Sleepers: { thread } = {}
	local Count = 0

	local function Push(Thread: thread)
		if Tail - Head >= Capacity then
			local Bigger: { thread } = table.create(Capacity * 2) :: { thread }
			local Waiting = Tail - Head
			for Index = 0, Waiting - 1 do
				Bigger[Index + 1] = Queue[(Head + Index) % Capacity + 1]
			end
			Queue = Bigger
			Capacity *= 2
			Head = 0
			Tail = Waiting
		end

		Queue[Tail % Capacity + 1] = Thread
		Tail += 1
	end

	local function Pop(): thread?
		if Head == Tail then
			return nil
		end

		local Thread = Queue[Head % Capacity + 1]
		Head += 1
		return Thread
	end

	@native
	local function Up(At: number)
		local When = Deadlines[At]
		local Thread = Sleepers[At]
		local Index = At

		while Index > 1 do
			local Parent = Index // 2
			if Deadlines[Parent] <= When then
				break
			end

			Deadlines[Index] = Deadlines[Parent]
			Sleepers[Index] = Sleepers[Parent]
			Index = Parent
		end

		Deadlines[Index] = When
		Sleepers[Index] = Thread
	end

	@native
	local function Down(At: number)
		local When = Deadlines[At]
		local Thread = Sleepers[At]
		local Index = At

		while true do
			local Child = Index * 2
			if Child > Count then
				break
			end
			if Child < Count and Deadlines[Child + 1] < Deadlines[Child] then
				Child += 1
			end
			if Deadlines[Child] >= When then
				break
			end

			Deadlines[Index] = Deadlines[Child]
			Sleepers[Index] = Sleepers[Child]
			Index = Child
		end

		Deadlines[Index] = When
		Sleepers[Index] = Thread
	end

	local function Sleep(When: number, Thread: thread)
		Count += 1
		Deadlines[Count] = When
		Sleepers[Count] = Thread
		Up(Count)
	end

	local function Wake(): thread
		local Thread = Sleepers[1]
		Deadlines[1] = Deadlines[Count]
		Sleepers[1] = Sleepers[Count]
		Sleepers[Count] = nil :: any
		Count -= 1

		if Count > 0 then
			Down(1)
		end
		return Thread
	end

	local function Bind(Body: (...any) -> (), ...: any): thread
		if select("#", ...) == 0 then
			return coroutine.create(Body)
		end

		local Args = table.pack(...)
		return coroutine.create(function()
			Body(table.unpack(Args, 1, Args.n))
		end)
	end

	local function Carry(Thread: thread, Ok: boolean, Raised: any)
		if Ok then
			return
		end
		table.insert(Failed, debug.traceback(Thread, tostring(Raised)))
	end

	local function Now(): number
		return Held
	end

	local function Wait(Seconds: number)
		local Thread = coroutine.running()
		if Seconds > 0 then
			Sleep(Held + Seconds, Thread)
		else
			Push(Thread)
		end
		coroutine.yield()
	end

	local function Spawn(Body: (...any) -> (), ...: any): thread
		local Thread = coroutine.create(Body)
		Carry(Thread, coroutine.resume(Thread, ...))
		return Thread
	end

	local function Resume(Thread: thread, ...: any): boolean
		if coroutine.status(Thread) ~= "suspended" then
			return false
		end

		Carry(Thread, coroutine.resume(Thread, ...))
		return true
	end

	local function Defer(Body: (...any) -> (), ...: any): thread
		local Thread = Bind(Body, ...)
		Push(Thread)
		return Thread
	end

	local function Delay(Seconds: number, Body: (...any) -> (), ...: any): thread
		local Thread = Bind(Body, ...)
		if Seconds > 0 then
			Sleep(Held + Seconds, Thread)
		else
			Push(Thread)
		end
		return Thread
	end

	local function Cancel(Thread: thread)
		if coroutine.status(Thread) ~= "suspended" then
			return
		end
		coroutine.close(Thread)
	end

	local function Step(): boolean
		local Thread = Pop()
		if Thread == nil then
			if Count == 0 then
				return false
			end

			local When = Deadlines[1]
			if When > Held then
				Held = When
			end
			repeat
				Push(Wake())
			until Count == 0 or Deadlines[1] > Held

			Thread = Pop()
		end

		Taken += 1
		if coroutine.status(Thread :: thread) ~= "suspended" then
			return true
		end

		Carry(Thread :: thread, coroutine.resume(Thread :: thread))
		return true
	end

	local function Drain(Limit: number): number
		local Ran = 0
		while Ran < Limit and Step() do
			Ran += 1
		end
		return Ran
	end

	local function Done(): boolean
		return Head == Tail and Count == 0
	end

	local function Run(Limit: number?): boolean
		Drain(Limit or STEP_CAP)
		return Done()
	end

	local function Advance(Seconds: number)
		if Seconds <= 0 then
			return
		end
		Held += Seconds
	end

	local function Sleeping(): number
		return Count
	end

	local function Ready(): number
		return Tail - Head
	end

	local function Steps(): number
		return Taken
	end

	local function Failures(): { string }
		return Failed
	end

	return table.freeze({
		Now = Now,
		Wait = Wait,
		Spawn = Spawn,
		Resume = Resume,
		Defer = Defer,
		Delay = Delay,
		Cancel = Cancel,

		Step = Step,
		Drain = Drain,
		Run = Run,
		Done = Done,
		Advance = Advance,
		Sleeping = Sleeping,
		Ready = Ready,
		Steps = Steps,
		Failures = Failures,
	})
end

return table.freeze({
	New = New,
	EPOCH = EPOCH,
	STEP_CAP = STEP_CAP,
})
