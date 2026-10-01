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
local Rooms = require("../src/Record/Rooms")
local Step = require("../src/Record/Step")
local Types = require("../src/Record/Types")
local Windows = require("../src/Core/Constants/Windows")

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
	local Note = Step(Current, Asked, Clock or NOW, Using or DEFAULT)
	local Value = Note.Stored
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

	Test("a key an op makes takes the id the op carries, and an op judged for another incarnation is Missing", function()
		local function Op(Seq: number, Id: string?, Create: string?): Op
			return { Form = "Minted", Seq = Seq, Stamp = NOW, Kind = 0, Body = { Add = 1 }, Id = Id, Create = Create }
		end
		local Key = Land(nil, Request({ Op(1, nil, "i1") }))
		Expect(Record(Key).Id).toBe("i1")
		local _, Other, Wrote = Land(Key, Request({ Op(2, "i2") }, 1))
		Expect(Wrote).toBe(false)
		Expect(Other.Whys).toBe(Similar({ "Missing" }))
		Expect(Other.Id).toBe("i1")
		Expect((select(2, Land(Key, Request({ Op(2, nil, "i2") }, 1))) :: Note).Whys).toBe(Similar({ "Missing" }))
		Expect(Gold((Land(Key, Request({ Op(2, "i1") }, 1))))).toBe(2)
		Expect(Gold((Land(Key, Request({ Op(2, nil, "i1") }, 1))))).toBe(2)
		Expect(Gold((Land(Key, Request({ Op(2) }, 1))))).toBe(2)
	end)

	Test("a key made by a request first sent more than the minted window before it lands says Late", function()
		local Old = Step(nil, Request({ Mint(1, 1, NOW - Windows.MINTED - 1) }), NOW, DEFAULT)
		Expect(Old.Stored ~= nil).toBe(true)
		Expect(Old.Late).toBe(true)
		Expect(Step(nil, Request({ Mint(1, 1, NOW - Windows.MINTED) }), NOW, DEFAULT).Late).toBeNil()
		local Key = Land(nil, Request({ Mint(1, 1) }))
		Expect(Step(Key, Request({ Mint(2, 1, NOW - Windows.MINTED - 1) }, 1), NOW, DEFAULT).Late).toBeNil()
	end)

	Test("a request whose earlier run wrote makes no key, and one that carries an id makes none either", function()
		local Again = Step(nil, Request({ Named("Timed", 1, "order", 1) }), NOW, DEFAULT, true)
		Expect(Again.Stored).toBeNil()
		Expect(Again.Why).toBe("Missing")
		local Op: Op = { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = 1 }, Id = "i1" }
		Expect(Step(nil, Request({ Op }), NOW, DEFAULT).Why).toBe("Missing")
	end)

	Test("a Tent makes a key with the id it carries, and a Tent or Commit for another incarnation is Missing", function()
		local Leg: Types.Leg = { Field = 1, Amount = 5 }
		local function Tent(Name: string, Id: string?, Create: string?): Types.Request
			return {
				Writer = 0,
				Ack = 0,
				MustExist = false,
				Ops = {},
				Tent = { Name = Name, Stamp = NOW, Attempt = 1, Print = 7, Decider = { Store = "Gold", Key = "d" }, Leg = Leg, Id = Id, Create = Create },
			}
		end
		local Key = Land(nil, Tent("x", nil, "i9"))
		Expect(Record(Key).Id).toBe("i9")
		Expect(Record(Key).Work.x.Form).toBe("Escrow")
		local _, Other, Wrote = Land(Key, Tent("y", "i8"))
		Expect(Other.Why).toBe("Missing")
		Expect(Wrote).toBe(false)
		local Commit: Types.Request = {
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Commit = { Name = "z", Stamp = NOW, Attempt = 1, Print = 7, Legs = { { Store = "Gold", Key = "a" } }, Leg = Leg, Id = "i8" },
		}
		local _, Elsewhere, Landed = Land(Key, Commit)
		Expect(Elsewhere.Why).toBe("Missing")
		Expect(Landed).toBe(false)
		Expect(Record((Land(Key, Tent("y", "i9")))).Work.y.Form).toBe("Escrow")
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
		local Key = { s = { Gold = 1, Future = "kept" }, b = Book.New():Encode(NOW) }
		local After, Note = Land(Key, Request({ Mint(1, 2) }))
		Expect(Note.Fates).toBe(Similar({ Fate.Took }))
		Expect((After :: any).s.Future).toBe("kept")
		local Bad: Op = { Form = "Minted", Seq = 2, Stamp = NOW, Kind = 0, Body = { Add = 0, Bad = 1.5 } }
		local _, Refused = Land(After, Request({ Bad }))
		Expect(Refused.Fates).toBe(Similar({ Fate.Refused }))
	end)

	Test("a full timed room drops the least stamp other than this request's and raises the horizon", function()
		local Key = Land(nil, Request({ Named("Timed", 1, "a", 1, NOW - 30), Named("Timed", 2, "b", 1, NOW - 20) }))
		local Width = Rooms.Timed(Record(Key), NOW)
		local After = Land(Key, Request({ Named("Timed", 1, "c", 1) }, 0, 2), NOW, Build({ TimedRoom = Width }))
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

	Test("a probe reports a held name's fate, is forgotten under the horizon, and otherwise lands deciding nothing", function()
		local Key = Land(nil, Request({ Named("Timed", 1, "order", -99, NOW - 10) }))
		local function Probe(Name: string, Stamp: number): Types.Request
			return { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Probe = { Name = Name, Stamp = Stamp } }
		end
		local Held = Step(Key, Probe("order", NOW - 10), NOW, DEFAULT)
		Expect(Held.Held).toBe(Fate.Refused)
		Expect(Held.Stored).toBeNil()
		local Aged = Land(Key, Request({ Mint(1, 1, NOW + 200) }, 0, 2), NOW + 200)
		Expect(Step(Aged, Probe("gone", NOW - 50), NOW + 200, DEFAULT).Why).toBe("Forgotten")
		local Landed = Step(Key, Probe("later", NOW), NOW, DEFAULT)
		Expect(Record(Landed.Stored).Writes).toBe(Record(Key).Writes + 1)
		Expect(#Landed.Decided).toBe(0)
		Expect(Step(nil, Probe("later", NOW), NOW, DEFAULT).Why).toBe("Missing")
	end)

	Test("a probe of a pinned use reports it took, and a probe of a standing mark is undecided and lands nothing", function()
		local Probe: Types.Request = { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Probe = { Name = "order", Stamp = NOW } }
		local Leg: Types.Leg = { Field = 1, Amount = 10 }
		local Pinned = Land(Land(nil, Request({ Mint(1, 1) })), {
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Commit = { Name = "order", Stamp = NOW, Attempt = 1, Print = 7, Legs = { { Store = "Gold", Key = "a" } }, Leg = Leg },
		})
		Expect(Record(Pinned).Work.order.Form).toBe("Pinned")
		local Committed = Step(Pinned, Probe, NOW, DEFAULT)
		Expect(Committed.Held).toBe(Fate.Took)
		Expect(Committed.Stored).toBeNil()
		local Marked = Land(Land(nil, Request({ Mint(1, 1) })), {
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Tent = { Name = "order", Stamp = NOW, Attempt = 1, Print = 7, Decider = { Store = "Gold", Key = "d" }, Leg = Leg },
		})
		Expect(Record(Marked).Work.order.Form).toBe("Escrow")
		local Standing = Step(Marked, Probe, NOW, DEFAULT)
		Expect(Standing.Held).toBeNil()
		Expect(Standing.Why).toBe("Undecided")
		Expect(Standing.Stored).toBeNil()
	end)

	Test("an untimed name past its window stays until its room is needed, and then goes oldest first", function()
		local Key = Land(nil, Request({ Named("Untimed", 1, "daily", 1) }))
		local _, Early = Land(Key, Request({ Named("Untimed", 1, "weekly", 1) }, 0, 3), NOW, Build({ UntimedRoom = 14 }))
		Expect(Early.Whys).toBe(Similar({ "NoRoom" }))
		Key = Land(Key, Request({ Mint(1, 1, NOW + 200) }, 0, 2), NOW + 200)
		Expect(Record(Key).Untimed.daily).never.toBeNil()
		local Tight = Build({ UntimedRoom = 14 })
		local After, Note = Land(Key, Request({ Named("Untimed", 1, "weekly", 1) }, 0, 3), NOW + 200, Tight)
		Expect(Note.Fates).toBe(Similar({ Fate.Took }))
		Expect(Record(After).Untimed.daily).toBeNil()
		Expect(Record(After).Untimed.weekly).never.toBeNil()
	end)
end)

return nil
