--!strict

--[=[

	Step: The cases for Record/Step, one per rule of record 4.

	The game is tests/Gold. Land runs one request and keeps what it wrote, as the datastore would.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Book = require("../src/Record/Book")
local Game = require("./Gold")
local Step = require("../src/Record/Step")
local Types = require("../src/Record/Types")

local Describe, Test, Expect, Similar = Testing.Describe, Testing.Test, Testing.Expect, Testing.Similar

type Op = Types.Op
type Note = Types.Note

local NOW = Game.NOW
local DEFAULT = Game.DEFAULT
local Build, Gold, Record = Game.Build, Game.Gold, Game.Record
local Fate = Book.Fate

local function Mint(Seq: number, Add: number, Stamp: number?): Op
	return { Form = "Minted", Seq = Seq, Stamp = Stamp or NOW, Kind = 0, Body = { Add = Add } }
end

local function Named(Form: Types.Form, Seq: number, Name: string, Add: number, Stamp: number?, Print: number?): Op
	return { Form = Form, Seq = Seq, Stamp = Stamp or NOW, Kind = 1, Name = Name, Print = Print or 7, Body = { Add = Add } }
end

local function Request(Ops: { Op }, Ack: number?, Writer: number?): Types.Request
	return { Writer = Writer or 1, Ack = Ack or 0, MustExist = false, Ops = Ops }
end

local function Land(Current: unknown, Asked: Types.Request, Clock: number?, Using: Types.Build?): (unknown, Note, boolean)
	local Value, Note = Step(Current, Asked, Clock or NOW, Using or DEFAULT)
	return if Value then Value else Current, Note, Value ~= nil
end

Describe("Step", function()
	Test("a first op makes the key, takes, and starts its writer's entry", function()
		local Key, Note, Wrote = Land(nil, Request({ Mint(1, 5) }))
		Expect(Wrote).toBe(true)
		Expect(Gold(Key)).toBe(5)
		Expect(Note.Fates).toBe(Similar({ Fate.Took }))
		Expect(Record(Key).Writes).toBe(1)
		Expect(Record(Key).Writers[1].Lo).toBe(1)
	end)

	Test("a retry of a decided op is told its fate and writes nothing", function()
		local Key = Land(nil, Request({ Mint(1, 5), Mint(2, -99) }))
		local Again, Note, Wrote = Land(Key, Request({ Mint(1, 5), Mint(2, -99) }))
		Expect(Wrote).toBe(false)
		Expect(Gold(Again)).toBe(5)
		Expect(Note.Fates).toBe(Similar({ Fate.Took, Fate.Refused }))
	end)

	Test("a refused fate is kept until the writer's ack passes it", function()
		local Key = Land(nil, Request({ Mint(1, -1), Mint(2, 3) }))
		Expect(Record(Key).Writers[1].Fates).toBe(Similar({ [1] = Fate.Refused }))
		Key = Land(Key, Request({ Mint(3, 1) }, 2))
		Expect(Record(Key).Writers[1].Fates).toBe(Similar({}))
		Expect(Gold(Key)).toBe(4)
	end)

	Test("a game's name is told its fate on a retry and Spent under other terms", function()
		local Key = Land(nil, Request({ Named("Timed", 1, "order", 5) }))
		local _, Same = Land(Key, Request({ Named("Timed", 1, "order", 5) }, 0, 2))
		Expect(Same.Fates).toBe(Similar({ Fate.Took }))
		local _, Other = Land(Key, Request({ Named("Timed", 1, "order", 5, nil, 8) }, 0, 2))
		Expect(Other.Whys).toBe(Similar({ "Spent" }))
	end)

	Test("a name the key forgot is forgotten, and every op after it is undecided", function()
		local Key = Land(nil, Request({ Named("Timed", 1, "old", 1, NOW) }))
		Key = Land(Key, Request({ Mint(1, 1, NOW + 200) }, 0, 2), NOW + 200)
		Expect(Record(Key).Timed.old).toBeNil()
		Expect(Record(Key).Horizon).toBe(NOW)
		local After, Note = Land(Key, Request({ Mint(1, 1, NOW + 200), Named("Timed", 2, "old", 1, NOW), Mint(3, 1, NOW + 200) }, 0, 3), NOW + 200)
		Expect(Note.Fates[1]).toBe(Fate.Took)
		Expect(Note.Whys[2]).toBe("Forgotten")
		Expect(Note.Whys[3]).toBe("Undecided")
		Expect(Gold(After)).toBe(3)
	end)

	Test("an op stamped past the clock and Ahead waits, and so do those after it", function()
		local _, Note, Wrote = Land(nil, Request({ Mint(1, 1, NOW + 61), Mint(2, 1) }))
		Expect(Wrote).toBe(false)
		Expect(Note.Whys).toBe(Similar({ "Ahead", "Undecided" }))
	end)

	Test("a key that must exist, is sealed, is broken or is newer writes nothing", function()
		local Must = Request({ Mint(1, 1) })
		local _, Missing = Land(nil, { Writer = 1, Ack = 0, MustExist = true, Ops = Must.Ops })
		Expect(Missing.Whys).toBe(Similar({ "Missing" }))
		Expect((select(2, Land({ z = "seal" }, Must)) :: Note).Whys).toBe(Similar({ "Missing" }))
		Expect((select(2, Land({ s = {}, b = "=" }, Must)) :: Note).Whys).toBe(Similar({ "Corrupt" }))
		Expect((select(2, Land({ s = {}, b = "z" }, Must)) :: Note).Whys).toBe(Similar({ "Behind" }))
	end)

	Test("a key past this build's floor is behind", function()
		local Key = Land(nil, Request({ Mint(1, 1) }), NOW, Build({ Floor = 3 }))
		local _, Note = Land(Key, Request({ Mint(1, 1) }, 0, 2))
		Expect(Note.Whys).toBe(Similar({ "Behind" }))
	end)

	Test("an untimed name takes once, and no room leaves it undecided", function()
		local Key, Note = Land(nil, Request({ Named("Untimed", 1, "daily", 1) }))
		Expect(Note.Fates).toBe(Similar({ Fate.Took }))
		Expect(Record(Key).Untimed.daily).never.toBeNil()
		local Tight = Build({ UntimedRoom = 12 })
		local _, Full = Land(Key, Request({ Named("Untimed", 1, "weekly", 1) }, 0, 2), NOW, Tight)
		Expect(Full.Whys).toBe(Similar({ "NoRoom" }))
	end)

	Test("a hopeful op judged on a view from before a cut is turned away", function()
		local Key = Land(nil, Request({ Mint(1, 1) }))
		local Hopeful: Op = { Form = "Hopeful", Seq = 1, Stamp = NOW, Kind = 0, View = 3, Body = { Add = 1 } }
		local After, Note = Land(Key, Request({ Hopeful }, 0, 2))
		Expect(Note.Fates).toBe(Similar({ Fate.Turned }))
		Expect(Gold(After)).toBe(1)
	end)

	Test("an op that would pass the state cap is Full and the op after it still takes", function()
		local Small = Build({ StateCap = 40 })
		local Key = Land(nil, Request({ Mint(1, 1) }), NOW, Small)
		local Ops = { { Form = "Minted", Seq = 2, Stamp = NOW, Kind = 0, Body = { Add = 0, Tag = string.rep("x", 40) } } :: Op, Mint(3, 2) }
		local After, Note = Land(Key, Request(Ops), NOW, Small)
		Expect(Note.Fates).toBe(Similar({ Fate.Full, Fate.Took }))
		Expect(Gold(After)).toBe(3)
		Expect((After :: any).s.Tag).toBeNil()
	end)

	Test("a field this build does not declare rides along untouched, and a bad money field is refused", function()
		local Key = { s = { Gold = 1, Future = "kept" }, b = Book.Encode(Book.New(), NOW) }
		local After, Note = Land(Key, Request({ Mint(1, 2) }))
		Expect(Note.Fates).toBe(Similar({ Fate.Took }))
		Expect((After :: any).s.Future).toBe("kept")
		local Bad: Op = { Form = "Minted", Seq = 2, Stamp = NOW, Kind = 0, Body = { Add = 0, Bad = 1.5 } }
		local _, Refused = Land(After, Request({ Bad }))
		Expect(Refused.Fates).toBe(Similar({ Fate.Refused }))
	end)

	Test("a full timed room drops the least stamp other than this request's and raises the horizon", function()
		local Key = Land(nil, Request({ Named("Timed", 1, "a", 1, NOW - 30), Named("Timed", 2, "b", 1, NOW - 20) }))
		local Width = #(Key :: any).b
		local After = Land(Key, Request({ Named("Timed", 1, "c", 1) }, 0, 2), NOW, Build({ TimedRoom = Width - 20 }))
		local Kept = Record(After)
		Expect(Kept.Timed.a).toBeNil()
		Expect(Kept.Timed.c).never.toBeNil()
		Expect(Kept.Horizon >= NOW - 30).toBe(true)
	end)

	Test("a key below the build's level has the missing migrations run in the write of its first op", function()
		local Key = Land(nil, Request({ Mint(1, 2) }))
		local Newer = Build({
			Level = 2,
			Floor = 1,
			Migrations = {
				function(State: any): unknown
					State.Gold *= 10
					return State
				end,
				function(State: any): unknown
					return { Gold = State.Gold + 1, Tag = "moved" }
				end,
			},
		})
		local After, Note = Land(Key, Request({ Mint(1, 5) }, 0, 2), NOW, Newer)
		Expect(Note.Fates).toBe(Similar({ Fate.Took }))
		Expect(Gold(After)).toBe(26)
		Expect((After :: any).s.Tag).toBe("moved")
		Expect(Record(After).Level).toBe(2)
		Expect(Record(After).Floor).toBe(1)
	end)

	Test("a migration that fails keeps nothing and every op it would judge is refused", function()
		local Key = Land(nil, Request({ Mint(1, 2) }))
		local Throws = Build({ Level = 1, Migrations = {
			function(): unknown
				error("broken")
			end,
		} })
		local Adds = Build({ Level = 1, Migrations = {
			function(State: any): unknown
				State.Stray = true
				return State
			end,
		} })
		for _, Using in { Throws, Adds } do
			local After, Note = Land(Key, Request({ Mint(1, 2), Mint(2, 3) }, 0, 3), NOW, Using)
			Expect(Note.Fates).toBe(Similar({ Fate.Refused, Fate.Refused }))
			Expect(Gold(After)).toBe(2)
			Expect(Record(After).Level).toBe(0)
		end
	end)
end)

return nil
