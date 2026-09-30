--!strict

--[=[

	Touch: The cases for Record/Touches, Calls/Touch and Calls/Resettle.

	tests/Replay answers each effect as it is sent. Every key is in the store of tests/Gold, whose
	money field is Gold. The use Y has a debit mark on key a and decides on key d.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Book = require("../src/Record/Book")
local Clock = require("../src/Machine/Clock")
local Game = require("./Gold")
local Limits = require("../src/Core/Constants/Limits")
local Replay = require("./Replay")
local Step = require("../src/Record/Step")
local Resettle = require("../src/Calls/Resettle")
local Shown = require("../src/Record/Shown")
local Touch = require("../src/Calls/Touch")
local Touches = require("../src/Record/Touches")
local Types = require("../src/Record/Types")
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
	local Op: Types.Op = { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = Amount } }
	return Step(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = { Op } }, NOW, DEFAULT).Stored
end

local function Put(Keys: Keys, Key: string, Asked: Types.Request)
	Keys[Key] = assert(Step(Keys[Key], Asked, NOW, DEFAULT).Stored, "the setup write did not land")
end

local function Marked(Stamp: number): Keys
	local Keys: Keys = { a = Seed(100) }
	local Tent: Types.Tent = { Name = Y, Stamp = Stamp, Attempt = 1, Decider = Ref("d"), Leg = { Field = 1, Amount = -30 } }
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
		Expect(Touches.Due(Item, Limits.LEVELS, NOW, NOW)).toBe(true)
		Expect(Touches.Due(Item, 0, NOW, NOW - 3600)).toBe(false)
		local Wait = Limits.LEVELS * Windows.STEP
		local Older = Record(Marked(NOW - Windows.SETTLE - Wait).a).Work[Y]
		Expect(Touches.Due(Older, 0, NOW, NOW)).toBe(false)
		Expect(Touches.Due(Older, 0, NOW, NOW - Wait)).toBe(true)
		Expect(Touches.Level(16, "any name")).toBeLessThan(Limits.LEVELS + 1)
	end)
end)

Describe("Touch", function()
	Test("a mark whose decider committed is resolved by that commit", function()
		local Keys = Marked(NOW - Windows.SETTLE)
		Keys.d = Seed(1)
		local Commit: Types.Commit = { Name = Y, Stamp = NOW, Attempt = 1, Legs = { Ref("a") }, Leg = { Field = 1, Amount = 30 } }
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

	Test("a mark whose decider reads gone stays until ORPHAN old, and then ends as an orphan under the horizon", function()
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
	end)

	Test("a pinned record is dropped only after every leg key is resolved by its commit", function()
		local Keys = Marked(NOW - Windows.PINNED)
		Keys.b, Keys.d = Seed(5), Seed(1)
		local Legs = { Ref("a"), Ref("b") }
		local Commit: Types.Commit = { Name = Y, Stamp = NOW - Windows.PINNED, Attempt = 1, Legs = Legs, Leg = { Field = 1, Amount = 30 } }
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

	Test("a key whose every item ends answers true, and one with a fresh undecided mark answers Busy", function()
		local Keys = Marked(NOW - Windows.SETTLE)
		Keys.d = Seed(1)
		Expect(Settle(Keys)).toBe(true)
		Expect(Record(Keys.a).Work[Y]).toBeNil()
		local Fresh = Marked(NOW - 1)
		Fresh.d = Seed(1)
		Expect(Settle(Fresh)).toBe("Busy")
		Expect(Record(Fresh.a).Work[Y]).never.toBeNil()
	end)

	Test("a key that holds no value answers Missing", function()
		Expect(Settle({})).toBe("Missing")
	end)
end)

return nil
