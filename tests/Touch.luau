--!strict

--[=[

	Touch: The cases for Record/Touches, Calls/Touch and Calls/Resettle, and for a writer that meets
	a mark whose decider is gone.

	tests/Replay answers each effect as it is sent. Every key is in the store of tests/Gold, whose
	money field is Gold. The use Y has a debit mark on key a and decides on key d.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Requests = require("../src/Record/Requests")
local Testing = require("./Testing")
local Asks = require("../src/Machine/Asks")
local Book = require("../src/Record/Book")
local Clock = require("../src/Machine/Clock")
local Game = require("./Gold")
local Heard = require("./Heard")
local Machine = require("../src/Machine/Machine")
local Queue = require("../src/Record/Queue")
local Replay = require("./Replay")
local Save = require("../src/Calls/Save")
local Step = require("../src/Record/Step")
local Resettle = require("../src/Calls/Resettle")
local Shown = require("../src/Record/Shown")
local Touch = require("../src/Calls/Touch")
local Touches = require("../src/Record/Touches")
local View = require("../src/Record/View")
local Windows = require("../src/Core/Constants/Windows")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

type Keys = Replay.Keys

local NOW = Clock.Now()
local DEFAULT = Game.DEFAULT
local Gold, Record = Game.Gold, Game.Record
local Y = Book.Drawn(6, 1)

local function Ref(Key: string): Book.Ref
	return { Store = "Gold", Key = Key }
end

local function Seed(Amount: number): unknown
	local Op: Requests.Op = { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = Amount } }
	return Step(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = { Op } }, NOW, DEFAULT).Stored
end

local function Put(Keys: Keys, Key: string, Asked: Requests.Request)
	Keys[Key] = assert(Step(Keys[Key], Asked, NOW, DEFAULT).Stored, "the setup write did not land")
end

local function Marked(Stamp: number): Keys
	local Keys: Keys = { a = Seed(100) }
	local Tent: Requests.Tent = { Name = Y, Stamp = Stamp, Attempt = 1, Decider = Ref("d"), Leg = { Field = 1, Amount = -30 } }
	Put(Keys, "a", { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Tent = Tent })
	return Keys
end

local function Mark(Keys: Keys): (typeof(Touch.Mark), Touch.Context)
	local Item = Record(Keys.a).Work[Y]
	return Touch.Mark, Touch.Context(Y, Item, Ref("a"), Windows.SETTLE)
end

Describe("Touches", function()
	Test("a server at the top level acts on a mark SETTLE old, and one at the bottom waits a step a level", function()
		local Item = Record(Marked(NOW - Windows.SETTLE).a).Work[Y]
		Expect(Touches.Due(Item, Touches.LEVELS, NOW, NOW)).toBe(true)
		Expect(Touches.Due(Item, 0, NOW, NOW - 3600)).toBe(false)
		local Wait = Touches.LEVELS * Touches.STEP
		local Older = Record(Marked(NOW - Windows.SETTLE - Wait).a).Work[Y]
		Expect(Touches.Due(Older, 0, NOW, NOW)).toBe(false)
		Expect(Touches.Due(Older, 0, NOW, NOW - Wait)).toBe(true)
		Expect(Touches.Level(16, "any name")).toBeLessThan(Touches.LEVELS + 1)
	end)

	Test("a gate is finished by a toucher at the top level once SETTLE old, and by a lower one a step a level later", function()
		local Gate: Book.Gate = { Name = "wipe", Stamp = NOW - Windows.SETTLE, Kind = Book.Cause.Reset, At = NOW - Windows.SETTLE + 1 }
		Expect(Touches.Gated(Gate, Touches.LEVELS, NOW, NOW)).toBe(false)
		Expect(Touches.Gated(Gate, Touches.LEVELS, NOW + 1, NOW)).toBe(true)
		Expect(Touches.Gated(Gate, Touches.LEVELS - 1, NOW + 1, NOW)).toBe(false)
		Expect(Touches.Gated(Gate, Touches.LEVELS - 1, NOW + 1 + Touches.STEP, NOW)).toBe(true)
	end)
end)

Describe("Touch", function()
	Test("a mark whose decider committed is resolved by that commit", function()
		local Keys = Marked(NOW - Windows.SETTLE)
		Keys.d = Seed(1)
		local Commit: Requests.Commit = { Name = Y, Stamp = NOW, Attempt = 1, Legs = { Ref("a") }, Leg = { Field = 1, Amount = 30 } }
		Put(Keys, "d", { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Commit = Commit })
		local Of, Context = Mark(Keys)
		Expect((Replay.Run(Of, Context, Keys, DEFAULT, NOW))).toBe(true)
		Expect(Gold(Keys.a)).toBe(70)
		Expect(Record(Keys.a).Work[Y]).toBeNil()
	end)

	Test("an undecided mark SETTLE old is fenced on its decider and resolved as an abort", function()
		local Keys = Marked(NOW - Windows.SETTLE)
		Keys.d = Seed(1)
		local Of, Context = Mark(Keys)
		Expect((Replay.Run(Of, Context, Keys, DEFAULT, NOW))).toBe(true)
		Expect(Gold(Keys.a)).toBe(100)
		Expect(Record(Keys.a).Work[Y]).toBeNil()
		Expect(Record(Keys.d).Timed[Y].Fate).toBe(Book.Fate.Fenced)
	end)

	Test("a mark whose decider reads gone stays until ORPHAN old, then ends as an orphan with a named return", function()
		local Young = Marked(NOW - Windows.SETTLE)
		local Of, Context = Mark(Young)
		local Answer, Updates = Replay.Run(Of, Context, Young, DEFAULT, NOW)
		Expect(Answer).toBe(false)
		Expect(Updates).toBe(0)
		local Old = Marked(NOW - Windows.ORPHAN)
		Of, Context = Mark(Old)
		Expect((Replay.Run(Of, Context, Old, DEFAULT, NOW))).toBe(true)
		Expect(Gold(Old.a)).toBe(100)
		Expect(Record(Old.a).Work[Y]).toBeNil()
		Expect(Record(Old.a).Horizon >= NOW - Windows.ORPHAN).toBe(true)
		local Returned = Record(Old.a).Events[1]
		Expect(Returned.Cause).toBe(Book.Cause.Returned)
		Expect(Returned.Amounts[1]).toBe(-30)
		Expect((Returned.Ref :: Book.Ref).Key).toBe("d")
	end)

	Test("a fence that reports its decider missing is no orphan evidence, however old the mark", function()
		local Item: Book.Escrow = { Form = "Escrow", Stamp = Heard.NOW - Windows.ORPHAN, Attempt = 1, Clean = true, Decider = Ref("d"), Field = 1, Amount = -30 }
		local Call, Asked = Machine.Start(Touch.Mark, Touch.Context(Y, Item, Ref("a"), Windows.SETTLE), Heard.NOW)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Seed(0)))
		local Ask = Asked[1].Ask
		Expect(Ask.Kind == "Send" and Ask.Request.Fence ~= nil).toBe(true)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Why = "Missing" }))
		Expect(#Asked).toBe(0)
		Expect(Machine.AnswerOf(Call)).toBe(false)
	end)

	Test("a read of no value asked before the mark is ORPHAN old ends nothing, though it is heard after", function()
		local Item: Book.Escrow = { Form = "Escrow", Stamp = Heard.NOW - Windows.ORPHAN, Attempt = 1, Clean = true, Decider = Ref("d"), Field = 1, Amount = -30 }
		local Call, Asked = Machine.Start(Touch.Mark, Touch.Context(Y, Item, Ref("a"), Windows.SETTLE), Heard.NOW - 1)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Expect(#Asked).toBe(0)
		Expect(Machine.AnswerOf(Call)).toBe(false)
	end)

	Test("a key that is only written ends a mark whose decider reads gone past ORPHAN, and the blocked op lands", function()
		local Keys = Marked(NOW - Windows.ORPHAN)
		local Kept = Queue.New(Ref("a"), DEFAULT, 16, nil, NOW)
		local Replies: { Queue.Reply } = {}
		Queue.Push(Kept, { Form = "Minted", Kind = 0, MustExist = true, Body = { Add = -80 } }, function(_: Queue.Asked, Reply: Queue.Reply)
			table.insert(Replies, Reply)
		end)
		Expect((Replay.Run(Save.Machine, Save.Context(Kept), Keys, DEFAULT, NOW))).toBe(Save.SAID.Empty)
		Expect(Replies[1]).toBe(true)
		Expect(Gold(Keys.a)).toBe(20)
		Expect(Record(Keys.a).Work[Y]).toBeNil()
		local Returned = Record(Keys.a).Events[1]
		Expect(Returned.Cause).toBe(Book.Cause.Returned)
		Expect(Returned.Amounts[1]).toBe(-30)
		Expect((Returned.Ref :: Book.Ref).Key).toBe("d")
	end)

	Test("a pinned record whose leg key reads gone past ORPHAN is dropped with a named return of that key", function()
		local Keys: Keys = { d = Seed(1) }
		local Stamp = NOW - Windows.ORPHAN
		Put(Keys, "d", {
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Commit = { Name = "late", Stamp = NOW, Attempt = 1, Print = 3, Legs = { Ref("gone") }, Leg = { Field = 1, Amount = 1 } },
		})
		local Item = Record(Keys.d).Work.late
		local Old: Book.Pinned = { Form = "Pinned", Stamp = Stamp, Attempt = 1, Print = 3, Legs = { Ref("gone") } }
		Expect(Item ~= nil).toBe(true)
		Expect((Replay.Run(Touch.Pinned, Touch.Context("late", Old, Ref("d"), Windows.SETTLE), Keys, DEFAULT, NOW))).toBe(true)
		Expect(Record(Keys.d).Work.late).toBeNil()
		local Orphan = Record(Keys.d).Events[1]
		Expect(Orphan.Cause).toBe(Book.Cause.Orphan)
		Expect((Orphan.Ref :: Book.Ref).Key).toBe("gone")
	end)

	Test("a pinned record is dropped only after every leg key is resolved by its commit", function()
		local Keys = Marked(NOW - Touches.PINNED)
		Keys.b, Keys.d = Seed(5), Seed(1)
		local Legs = { Ref("a"), Ref("b") }
		local Commit: Requests.Commit = { Name = Y, Stamp = NOW - Touches.PINNED, Attempt = 1, Legs = Legs, Leg = { Field = 1, Amount = 30 } }
		Put(Keys, "d", { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Commit = Commit })
		local Item = Record(Keys.d).Work[Y]
		Expect((Replay.Run(Touch.Pinned, Touch.Context(Y, Item, Ref("d"), Windows.SETTLE), Keys, DEFAULT, NOW))).toBe(true)
		Expect(Gold(Keys.a)).toBe(70)
		Expect(Record(Keys.d).Work[Y]).toBeNil()
		Expect(Record(Keys.d).Timed[Y].Fate).toBe(Book.Fate.Took)
		local Missing: Keys = { d = Keys.d }
		Put(Missing, "d", {
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Commit = { Name = "late", Stamp = NOW, Attempt = 1, Print = 3, Legs = { Ref("gone") }, Leg = { Field = 1, Amount = 1 } },
		})
		local Pinned = Record(Missing.d).Work.late
		Expect((Replay.Run(Touch.Pinned, Touch.Context("late", Pinned, Ref("d"), Windows.SETTLE), Missing, DEFAULT, NOW))).toBe(false)
		Expect(Record(Missing.d).Work.late).never.toBeNil()
	end)
end)

Describe("Resettle", function()
	local function Settle(Keys: Keys): unknown
		local Context = Resettle.Context(Ref("a"), DEFAULT, Shown.New(), NOW)
		return (Replay.Run(Resettle.Machine, Context, Keys, DEFAULT, NOW))
	end

	Test("a key whose every item ends answers true, and one it cannot clear answers Unresolved, never Busy", function()
		local Keys = Marked(NOW - Windows.SETTLE)
		Keys.d = Seed(1)
		Expect(Settle(Keys)).toBe(true)
		Expect(Record(Keys.a).Work[Y]).toBeNil()
		local Fresh = Marked(NOW - 1)
		Fresh.d = Seed(1)
		Expect(Settle(Fresh)).toBe("Unresolved")
		Expect(Record(Fresh.a).Work[Y]).never.toBeNil()
	end)

	Test("an item still left waits SETTLE for another round, and the key answers true once it is clear", function()
		local Item = Record(Marked(NOW - 1).a).Work[Y]
		local Left: View.View = { State = { Gold = 100 }, Writes = 2, Cuts = 0, Horizon = 0, Level = 0, Floor = 0, Work = { [Y] = Item } }
		local Clear: View.View = { State = { Gold = 100 }, Writes = 3, Cuts = 0, Horizon = 0, Level = 0, Floor = 0, Work = {} }
		local Call, Asked = Machine.Start(Resettle.Machine, Resettle.Context(Ref("a"), DEFAULT, Shown.New(), NOW), NOW)
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Done(NOW, Left))
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Done(NOW, false))
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Done(NOW, Left))
		local Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Wait" then Ask.Seconds else -1).toBe(Windows.SETTLE)
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Done(NOW + Windows.SETTLE))
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Done(NOW + Windows.SETTLE, Left))
		Expect(Asked[1].Ask.Kind).toBe("Run")
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Done(NOW + Windows.SETTLE, true))
		Machine.Step(Call, Asked[1].Id, Asks.Done(NOW + Windows.SETTLE, Clear))
		Expect(Machine.AnswerOf(Call)).toBe(true)
	end)

	Test("a key that holds no value answers Missing", function()
		Expect(Settle({})).toBe("Missing")
	end)
end)

return nil
