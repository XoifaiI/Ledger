--!strict

--[=[

	Unblock: The cases for Calls/Unblock, stepped directly with the replies it hears.

	The blocker is a mark on key a whose decider is key d. A read of d hears a key made by the real
	Step. Every other reply is built by hand.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Requests = require("../src/Record/Requests")
local Testing = require("./Testing")
local Blockers = require("../src/Record/Blockers")
local Book = require("../src/Record/Book")
local Game = require("./Gold")
local Heard = require("./Heard")
local Machine = require("../src/Machine/Machine")
local Step = require("../src/Record/Step")
local Unblock = require("../src/Calls/Unblock")
local Windows = require("../src/Core/Constants/Windows")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local NOW = Heard.NOW
local DEFAULT = Game.DEFAULT
local Y = Book.Drawn(5, 1)

local function Seed(): unknown
	local Op: Requests.Op = { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = 1 } }
	return Step(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = { Op } }, NOW, DEFAULT).Stored
end

local function Blocker(Stamp: number): Blockers.Blocker
	local Item: Book.Escrow = {
		Form = "Escrow",
		Stamp = Stamp,
		Attempt = 1,
		Clean = true,
		Decider = { Store = "Gold", Key = "d" },
		Field = 1,
		Amount = -1,
	}
	return { Name = Y, Item = Item, Ref = { Store = "Gold", Key = "a" } }
end

local function Start(Stamp: number)
	return Machine.Start(Unblock.Machine, Unblock.Context(Blocker(Stamp), NOW, ""), NOW)
end

Describe("Unblock", function()
	Test("a decider that pinned the use answers a commit at its attempt, from one read", function()
		local Commit: Requests.Commit = { Name = Y, Stamp = NOW, Attempt = 2, Legs = {}, Leg = { Field = 1, Amount = 1 } }
		local Decider = Step(Seed(), { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Commit = Commit }, NOW, DEFAULT).Stored
		local Call, Asked = Start(NOW)
		local Ask = Asked[1].Ask
		Expect(Ask.Kind == "Read" and Ask.Ref.Key).toBe("d")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Decider))
		local End = assert(Machine.AnswerOf(Call))
		Expect(End.Outcome).toBe("Commit")
		Expect(End.Attempt).toBe(2)
		Expect(#Asked).toBe(0)
		Expect(Machine.IsFinal(Call)).toBe(true)
	end)

	Test("an undecided younger mark is fenced, not finally, and the fence's report answers its abort", function()
		local Call, Asked = Start(NOW + 5)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Seed()))
		local Ask = Asked[1].Ask
		local Fence = if Ask.Kind == "Send" then Ask.Request.Fence else nil
		Expect(Fence and Fence.Final).toBe(false)
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Fenced", Attempt = 1 }))
		Expect(assert(Machine.AnswerOf(Call)).Outcome).toBe("Abort")
	end)

	Test("an undecided older mark that is fresh is waited on until it is SETTLE old, then fenced", function()
		local Call, Asked = Start(NOW - 2)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Seed()))
		local Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Wait" then Ask.Seconds else 0).toBe(Windows.SETTLE - 2)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Expect(Asked[1].Ask.Kind).toBe("Send")
	end)

	Test("a read that failed, and a decider that holds no value, answer nothing", function()
		local Call, Asked = Start(NOW + 5)
		Machine.Step(Call, Asked[1].Id, Heard.Failed())
		Expect(Machine.AnswerOf(Call)).toBeNil()
		Expect(Machine.IsFinal(Call)).toBe(true)
		Call, Asked = Start(NOW + 5)
		Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Expect(Machine.AnswerOf(Call)).toBeNil()
		Expect(Machine.IsFinal(Call)).toBe(true)
	end)
end)

return nil
