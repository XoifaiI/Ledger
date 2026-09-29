--!strict

--[=[

	Machine: The cases for Core/Machine.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Machine = require("../src/Core/Machine")
local Queue = require("../src/Util/Queue")

type Effect = { read Kind: string, read Leg: number? }
type Reply = { read Kind: string, read Value: number? }
type Call<C> = Machine.Call<C, Reply, Effect, number>
type Spec<C> = Machine.Spec<C, Reply, Effect, number>
type Machine<C> = Machine.Machine<C, Reply, Effect, number>

type FetchContext = { Tries: number }
type CommitContext = { Legs: number, Yes: number }
type TimedContext = { Timer: number }
type PollContext = { Timer: number, Left: number }

local Describe, Test, Expect, Similar = Testing.Describe, Testing.Test, Testing.Expect, Testing.Similar

local function Fetch(): Machine<FetchContext>
	local Spec: Spec<FetchContext> = {
		Name = "Fetch",
		Initial = "Asking",
		States = {
			Asking = {
				To = { "Done" },
				Enter = function(Call: Call<FetchContext>)
					Machine.Send(Call, { Kind = "Get" })
				end,
				On = function(Call: Call<FetchContext>, Reply: Reply): string?
					if Reply.Kind == "Failed" then
						Call.Context.Tries += 1
						Machine.Send(Call, { Kind = "Get" })
						return nil
					end
					Machine.Answer(Call, Reply.Value :: number)
					return "Done"
				end,
			},
			Done = {},
		},
	}
	return Machine.Define(Spec)
end

local function Commit(): Machine<CommitContext>
	local Spec: Spec<CommitContext> = {
		Name = "Commit",
		Initial = "Preparing",
		States = {
			Preparing = {
				To = { "Committing" },
				Enter = function(Call: Call<CommitContext>)
					for Leg = 1, Call.Context.Legs do
						Machine.Send(Call, { Kind = "Prepare", Leg = Leg })
					end
				end,
				On = function(Call: Call<CommitContext>, _: Reply): string?
					Call.Context.Yes += 1
					return if Call.Waiting == 0 then "Committing" else nil
				end,
			},
			Committing = {
				To = { "Done" },
				Enter = function(Call: Call<CommitContext>)
					Machine.Answer(Call, Call.Context.Yes)
					for Leg = 1, Call.Context.Legs do
						Machine.Send(Call, { Kind = "Commit", Leg = Leg })
					end
				end,
				On = function(Call: Call<CommitContext>, _: Reply): string?
					return if Call.Waiting == 0 then "Done" else nil
				end,
			},
			Done = {},
		},
	}
	return Machine.Define(Spec)
end

local function Timed(): Machine<TimedContext>
	local Spec: Spec<TimedContext> = {
		Name = "Timed",
		Initial = "Reading",
		States = {
			Reading = {
				To = { "Done" },
				Enter = function(Call: Call<TimedContext>)
					Machine.Send(Call, { Kind = "Get" })
					Call.Context.Timer = Machine.Send(Call, { Kind = "Wait" })
				end,
				On = function(Call: Call<TimedContext>, Reply: Reply): string?
					Machine.Cancel(Call, Call.Context.Timer)
					Machine.Answer(Call, Reply.Value :: number)
					return "Done"
				end,
			},
			Done = {},
		},
	}
	return Machine.Define(Spec)
end

local function Poll(): Machine<PollContext>
	local Spec: Spec<PollContext> = {
		Name = "Poll",
		Initial = "Polling",
		States = {
			Polling = {
				To = { "Done" },
				Enter = function(Call: Call<PollContext>)
					Call.Context.Timer = Machine.Send(Call, { Kind = "Wait" })
					Machine.Send(Call, { Kind = "Get" })
				end,
				On = function(Call: Call<PollContext>, _: Reply): string?
					Machine.Cancel(Call, Call.Context.Timer)
					Call.Context.Left -= 1
					if Call.Context.Left == 0 then
						return "Done"
					end
					Machine.Send(Call, { Kind = "Get" })
					return nil
				end,
			},
			Done = {},
		},
	}
	return Machine.Define(Spec)
end

local function Single(Name: string, States: { [string]: Machine.State<{}, Reply, Effect, number> }): Machine<{}>
	local Spec: Spec<{}> = { Name = Name, Initial = "A", States = States }
	return Machine.Define(Spec)
end

local function Replay<C>(Spec: Machine<C>, Context: C): ({ string }, Call<C>)
	local Path: { string } = {}
	local Pending: Queue.Queue<{ Id: number, Effect: Effect }> = Queue.New()
	local Call, Effects, First = Machine.Start(Spec, Context)
	while true do
		table.insert(Path, Machine.StateOf(Call))
		for Slot, Effect in Effects do
			Queue.Push(Pending, { Id = First + Slot - 1, Effect = Effect })
		end
		local Next = Queue.Pop(Pending)
		if Next == nil then
			return Path, Call
		end
		Effects, First = Machine.Step(Call, Next.Id, { Kind = Next.Effect.Kind })
	end
end

Describe("Machine", function()
	Test("start runs the initial Enter and its first id is one", function()
		local Call, Effects, First = Machine.Start(Fetch(), { Tries = 0 })
		Expect(Machine.StateOf(Call)).toBe("Asking")
		Expect(First).toBe(1)
		Expect(Call.Waiting).toBe(1)
		Expect(Effects).toBe(Similar({ { Kind = "Get" } }))
	end)

	Test("a state that stays may send again under the next id", function()
		local Call = Machine.Start(Fetch(), { Tries = 0 })
		local Effects, First = Machine.Step(Call, 1, { Kind = "Failed" })
		Expect(Machine.StateOf(Call)).toBe("Asking")
		Expect(Call.Context.Tries).toBe(1)
		Expect(First).toBe(2)
		Expect(Effects).toHaveLength(1)
		Effects = Machine.Step(Call, 2, { Kind = "Read", Value = 7 })
		Expect(Machine.IsFinal(Call)).toBe(true)
		Expect(Call.Answer).toBe(7)
		Expect(Effects).toHaveLength(0)
	end)

	Test("a fan out moves only after its last reply, in any order", function()
		local Call, Effects, First = Machine.Start(Commit(), { Legs = 3, Yes = 0 })
		Expect(Effects).toHaveLength(3)
		Expect(First).toBe(1)
		Machine.Step(Call, 3, { Kind = "Yes" })
		Machine.Step(Call, 1, { Kind = "Yes" })
		Expect(Machine.StateOf(Call)).toBe("Preparing")
		Expect(Call.Answer).toBeNil()
		Effects, First = Machine.Step(Call, 2, { Kind = "Yes" })
		Expect(Machine.StateOf(Call)).toBe("Committing")
		Expect(First).toBe(4)
		Expect(Effects[1]).toBe(Similar({ Kind = "Commit", Leg = 1 }))
		Expect(Effects).toHaveLength(3)
	end)

	Test("a call answers and goes on working", function()
		local Call = Machine.Start(Commit(), { Legs = 2, Yes = 0 })
		Machine.Step(Call, 1, { Kind = "Yes" })
		Machine.Step(Call, 2, { Kind = "Yes" })
		Expect(Call.Answer).toBe(2)
		Expect(Machine.IsFinal(Call)).toBe(false)
		Machine.Step(Call, 4, { Kind = "Done" })
		Machine.Step(Call, 3, { Kind = "Done" })
		Expect(Machine.IsFinal(Call)).toBe(true)
		Expect(Call.Answer).toBe(2)
	end)

	Test("a call answers once", function()
		local Twice = Single("Twice", {
			A = {
				Enter = function(Call: Call<{}>)
					Machine.Answer(Call, 1)
					Machine.Answer(Call, 2)
				end,
			},
		})
		Expect(function()
			Machine.Start(Twice, {})
		end).toThrow("Machine Twice: the call answered already")
	end)

	Test("a state that moves with a request out is refused", function()
		local Hasty = Single("Hasty", {
			A = {
				To = { "B" },
				Enter = function(Call: Call<{}>)
					Machine.Send(Call, { Kind = "Get" })
					Machine.Send(Call, { Kind = "Get" })
				end,
				On = function(_: Call<{}>, _: Reply): string?
					return "B"
				end,
			},
			B = {},
		})
		local Call = Machine.Start(Hasty, {})
		Expect(function()
			Machine.Step(Call, 2, { Kind = "Read" })
		end).toThrow("Machine Hasty: state A moves to B with 1 requests out")
	end)

	Test("a reply to an id that is not out is refused and the call goes on", function()
		local Call = Machine.Start(Fetch(), { Tries = 0 })
		Machine.Step(Call, 1, { Kind = "Failed" })
		Expect(function()
			Machine.Step(Call, 1, { Kind = "Read", Value = 1 })
		end).toThrow("Machine Fetch: request 1 is not out")
		Expect(function()
			Machine.Step(Call, 99, { Kind = "Read", Value = 1 })
		end).toThrow("Machine Fetch: request 99 is not out")
		Machine.Step(Call, 2, { Kind = "Read", Value = 5 })
		Expect(Call.Answer).toBe(5)
	end)

	Test("an id that was never sent is not out", function()
		local Call = Machine.Start(Fetch(), { Tries = 0 })
		for _, Id in { 0, -1, 1.5, 2, 9, 2 ^ 40 } do
			Expect(function()
				Machine.Step(Call, Id, { Kind = "Read" })
			end).toThrow(`Machine Fetch: request {Id} is not out`)
		end
		Machine.Cancel(Call, 0)
		Machine.Cancel(Call, -1)
		Expect(Call.Waiting).toBe(1)
		Machine.Step(Call, 1, { Kind = "Read", Value = 3 })
		Expect(Call.Answer).toBe(3)
	end)

	Test("the late reply to a cancelled request is dropped once, even after the call ends", function()
		local Call = Machine.Start(Timed(), { Timer = 0 })
		Expect(Call.Context.Timer).toBe(2)
		Expect(Call.Waiting).toBe(2)
		Machine.Step(Call, 1, { Kind = "Read", Value = 4 })
		Expect(Machine.IsFinal(Call)).toBe(true)
		Expect(Call.Waiting).toBe(0)
		Expect((Machine.Step(Call, 2, { Kind = "Woke" }))).toHaveLength(0)
		Expect(Call.Answer).toBe(4)
		Expect(function()
			Machine.Step(Call, 2, { Kind = "Woke" })
		end).toThrow("Machine Timed: request 2 is not out")
	end)

	Test("a cancelled request that never replies holds up no later id", function()
		local Call = Machine.Start(Poll(), { Timer = 0, Left = 100 })
		for Id = 2, 101 do
			Machine.Step(Call, Id, { Kind = "Read" })
		end
		Expect(Machine.IsFinal(Call)).toBe(true)
		Expect(Call.Waiting).toBe(0)
		Expect((Machine.Step(Call, 1, { Kind = "Woke" }))).toHaveLength(0)
		Expect(function()
			Machine.Step(Call, 1, { Kind = "Woke" })
		end).toThrow("Machine Poll: request 1 is not out")
	end)

	Test("a fan out of a hundred takes its replies in reverse and refuses each twice", function()
		local Call = Machine.Start(Commit(), { Legs = 100, Yes = 0 })
		for Id = 100, 2, -1 do
			Machine.Step(Call, Id, { Kind = "Yes" })
			Expect(function()
				Machine.Step(Call, Id, { Kind = "Yes" })
			end).toThrow(`Machine Commit: request {Id} is not out`)
		end
		Expect(Machine.StateOf(Call)).toBe("Preparing")
		Expect(Call.Waiting).toBe(1)
		local Effects, First = Machine.Step(Call, 1, { Kind = "Yes" })
		Expect(Machine.StateOf(Call)).toBe("Committing")
		Expect(First).toBe(101)
		Expect(Effects).toHaveLength(100)
	end)

	Test("step inside step is refused and the call stays dead", function()
		local Nested = Single("Nested", {
			A = {
				Enter = function(Call: Call<{}>)
					Machine.Send(Call, { Kind = "Get" })
					Machine.Send(Call, { Kind = "Get" })
				end,
				On = function(Call: Call<{}>, _: Reply): string?
					Machine.Step(Call, 2, { Kind = "Read" })
					return nil
				end,
			},
		})
		local Call = Machine.Start(Nested, {})
		for Id = 1, 2 do
			Expect(function()
				Machine.Step(Call, Id, { Kind = "Read" })
			end).toThrow("Machine Nested: Step inside Step, or on a call whose transition raised")
		end
	end)

	Test("a final state cannot send and nothing sends outside a step", function()
		local Loud = Single("Loud", {
			A = {
				Enter = function(Call: Call<{}>)
					Machine.Send(Call, { Kind = "Get" })
				end,
			},
		})
		Expect(function()
			Machine.Start(Loud, {})
		end).toThrow("Machine Loud: Send outside a step or from a final state")
		local Call = Machine.Start(Fetch(), { Tries = 0 })
		Expect(function()
			Machine.Send(Call, { Kind = "Get" })
		end).toThrow("Machine Fetch: Send outside a step or from a final state")
	end)

	Test("a move the state does not list is refused", function()
		local Loose = Single("Loose", {
			A = {
				To = { "B" },
				Enter = function(Call: Call<{}>)
					Machine.Send(Call, { Kind = "Get" })
				end,
				On = function(_: Call<{}>, _: Reply): string?
					return "C"
				end,
			},
			B = {},
			C = {},
		})
		local Call = Machine.Start(Loose, {})
		Expect(function()
			Machine.Step(Call, 1, { Kind = "Go" })
		end).toThrow("Machine Loose: state A may not move to C")
	end)

	Test("define checks every name at load", function()
		local NoInitial: Spec<{}> = { Name = "Bad", Initial = "Nowhere", States = { A = {} } }
		Expect(function()
			Machine.Define(NoInitial)
		end).toThrow("Machine Bad: Nowhere is not a state")
		Expect(function()
			Single("Bad", {
				A = {
					To = { "Gone" },
					On = function(_: Call<{}>, _: Reply): string?
						return nil
					end,
				},
			})
		end).toThrow("Machine Bad: Gone is not a state")
	end)

	Test("the effects array is reused from step to step", function()
		local Call, Effects = Machine.Start(Fetch(), { Tries = 0 })
		local Again = Machine.Step(Call, 1, { Kind = "Failed" })
		Expect(Again).toBe(Effects)
		Expect(Again).toHaveLength(1)
	end)

	Test("replay answers requests in the order they were sent", function()
		local Path, Call = Replay(Commit(), { Legs = 2, Yes = 0 })
		Expect(table.concat(Path, ",")).toBe("Preparing,Preparing,Committing,Committing,Done")
		Expect(Machine.IsFinal(Call)).toBe(true)
		Expect(Call.Answer).toBe(2)
	end)
end)

return nil
