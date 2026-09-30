--!strict

--[=[

	Work: The cases for Record/Work, the transaction's steps inside the real Step.

	The game is tests/Gold, whose money field is Gold. Land runs one request and keeps what it wrote,
	as the datastore would. Each case is one of the controls the transaction model must fail without,
	with amounts chosen so that each wrong rule gives a different number.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Book = require("../src/Record/Book")
local Game = require("./Gold")
local Sizes = require("../src/Core/Constants/Sizes")
local Step = require("../src/Record/Step")
local Types = require("../src/Record/Types")
local Windows = require("../src/Core/Constants/Windows")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

type Note = Types.Note
type Request = Types.Request

local NOW = Game.NOW
local DEFAULT = Game.DEFAULT
local Gold, Record = Game.Gold, Game.Record
local Fate, Role = Book.Fate, Book.Role
local GOLD = 1
local DECIDER: Book.Ref = { Store = "Gold", Key = "d" }
local X = Book.Drawn(7, 1)
local Y = Book.Drawn(7, 2)

local function Land(Current: unknown, Asked: Request, Clock: number?): (unknown, Note, boolean)
	local Note = Step(Current, Asked, Clock or NOW, DEFAULT)
	local Value = Note.Stored
	return if Value then Value else Current, Note, Value ~= nil
end

local function Seed(Amount: number): unknown
	local Op: Types.Op = { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = Amount } }
	return (Land(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = { Op } }))
end

local function Delta(Amount: number): Types.Leg
	return { Field = GOLD, Amount = Amount }
end

local function Tent(Name: string, Attempt: number, Leg: Types.Leg, Print: number?): Request
	return {
		Writer = 0,
		Ack = 0,
		MustExist = true,
		Ops = {},
		Tent = { Name = Name, Stamp = NOW, Attempt = Attempt, Print = Print, Decider = DECIDER, Leg = Leg },
	}
end

local function Commit(Name: string, Attempt: number, Leg: Types.Leg): Request
	return {
		Writer = 0,
		Ack = 0,
		MustExist = true,
		Ops = {},
		Commit = { Name = Name, Stamp = NOW, Attempt = Attempt, Legs = { { Store = "Gold", Key = "a" } }, Leg = Leg },
	}
end

local function Fence(Name: string, Attempt: number, Final: boolean): Request
	return { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Fence = { Name = Name, Stamp = NOW, Attempt = Attempt, Final = Final } }
end

local function Resolve(Name: string, Attempt: number, Outcome: Types.Outcome, Print: number?): Request
	local End: Types.End = { Name = Name, Stamp = NOW, Attempt = Attempt, Print = Print, Outcome = Outcome }
	return { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Ends = { End } }
end

local function Edit(Seq: number, Amount: number): Request
	local Op: Types.Op = { Form = "Minted", Seq = Seq, Stamp = NOW, Kind = 0, Body = { Add = Amount } }
	return { Writer = 2, Ack = Seq - 1, MustExist = true, Ops = { Op } }
end

Describe("Work", function()
	Test("a debit leg sets its amount aside for later debits, and only its commit takes it off the field", function()
		local Key, Note = Land(Seed(100), Tent(X, 1, Delta(-60)))
		Expect(Note.Report).toBe("Mine")
		Expect(Gold(Key)).toBe(100)
		local Later, Refused, Wrote = Land(Key, Tent(Y, 1, Delta(-50)))
		Expect(Refused.Report).toBe("Refused")
		Expect(Wrote).toBe(true)
		Expect(Record(Later).Timed[Y].Fate).toBe(Fate.Refused)
		local Done = Land(Later, Resolve(X, 1, "Commit"))
		Expect(Gold(Done)).toBe(40)
		Expect(Record(Done).Work[X]).toBeNil()
		Expect(Record(Done).Timed[X].Role).toBe(Role.Leg)
		local Again, _, Twice = Land(Done, Resolve(X, 1, "Commit"))
		Expect(Twice).toBe(false)
		Expect(Gold(Again)).toBe(40)
	end)

	Test("an abort gives the amount back, and a late Tent of that attempt meets the fate", function()
		local Key = Land(Seed(100), Tent(X, 1, Delta(-60)))
		Key = Land(Key, Resolve(X, 1, "Abort"))
		Expect(Gold(Key)).toBe(100)
		Expect(Record(Key).Work[X]).toBeNil()
		local _, Late = Land(Key, Tent(X, 1, Delta(-60)))
		Expect(Late.Report).toBe("Decided")
		Expect(Late.Fate).toBe(Fate.Aborted)
		local _, Next = Land(Key, Tent(X, 2, Delta(-60)))
		Expect(Next.Report).toBe("Mine")
	end)

	Test("a resolve ends only the mark of its own attempt and fingerprint, and an orphan end any attempt", function()
		local Key = Land(Seed(100), Tent("order", 2, Delta(-60), 7))
		local Older = Land(Key, Resolve("order", 1, "Commit", 7))
		Expect(Gold(Older)).toBe(100)
		Expect(Record(Older).Work.order).never.toBeNil()
		local Other = Land(Key, Resolve("order", 2, "Commit", 8))
		Expect(Gold(Other)).toBe(100)
		Expect(Record(Other).Work.order).never.toBeNil()
		Expect(Gold((Land(Key, Resolve("order", 2, "Commit", 7))))).toBe(40)
		local Orphaned = Land(Key, Resolve("order", 1, "Orphan", 7))
		Expect(Gold(Orphaned)).toBe(100)
		Expect(Record(Orphaned).Work.order).toBeNil()
	end)

	Test("a commit applies the decider's leg once and pins the use, and a fence after it says committed", function()
		local Key, Note = Land(Seed(1), Commit(X, 1, Delta(10)))
		Expect(Note.Report).toBe("Committed")
		Expect(Gold(Key)).toBe(11)
		Expect(Record(Key).Work[X].Form).toBe("Pinned")
		local Again, Retry, Wrote = Land(Key, Commit(X, 1, Delta(10)))
		Expect(Retry.Report).toBe("Committed")
		Expect(Wrote).toBe(false)
		Expect(Gold(Again)).toBe(11)
		local _, Fenced = Land(Key, Fence(X, 1, true))
		Expect(Fenced.Report).toBe("Committed")
	end)

	Test("a fence stops a commit of its attempt or lower, and a final one stops every attempt", function()
		local Key = Land(Seed(1), Fence(X, 1, false))
		local Stopped, Note = Land(Key, Commit(X, 1, Delta(10)))
		Expect(Note.Report).toBe("Fenced")
		Expect(Gold(Stopped)).toBe(1)
		local Later, Next = Land(Key, Commit(X, 2, Delta(10)))
		Expect(Next.Report).toBe("Committed")
		Expect(Gold(Later)).toBe(11)
		Key = Land(Key, Fence(Y, 1, true))
		local _, Final = Land(Key, Commit(Y, 3, Delta(10)))
		Expect(Final.Report).toBe("Fenced")
		Expect(Final.Final).toBe(true)
	end)

	Test("a commit its own leg refuses keeps the refusal as the use's decision", function()
		local Key, Note, Wrote = Land(Seed(5), Commit(X, 1, Delta(-10)))
		Expect(Note.Report).toBe("Refused")
		Expect(Wrote).toBe(true)
		Expect(Gold(Key)).toBe(5)
		local _, Again = Land(Key, Commit(X, 2, Delta(-1)))
		Expect(Again.Report).toBe("Refused")
		Expect(Again.Fate).toBe(Fate.Refused)
	end)

	Test("an op beside an escrow mark lands only when the mark cannot change its verdict", function()
		local Key = Land(Seed(100), Tent(X, 1, Delta(-60)))
		local Landed, Took = Land(Key, Edit(1, -30))
		Expect(Took.Fates[1]).toBe(Fate.Took)
		Expect(Gold(Landed)).toBe(70)
		local Mark = Record(Landed).Work[X]
		Expect(Mark.Form ~= "Pinned" and Mark.Clean).toBe(false)
		local Held, Blocked, Wrote = Land(Landed, Edit(2, -20))
		Expect(Blocked.Whys[1]).toBe("Blocked")
		Expect(Wrote).toBe(false)
		Expect(Gold(Held)).toBe(70)
		Expect((Blocked.Items :: any)[X]).never.toBeNil()
	end)

	Test("an exclusive mark blocks every other change, and its diff lands only at the resolve", function()
		local Key, Note = Land(Seed(5), Tent(X, 1, { Body = { Add = 7, Tag = "won" } }))
		Expect(Note.Report).toBe("Mine")
		Expect(Gold(Key)).toBe(5)
		Expect((Key :: any).p).never.toBeNil()
		local _, Edited = Land(Key, Edit(1, 1))
		Expect(Edited.Whys[1]).toBe("Blocked")
		local _, Beside = Land(Key, Tent(Y, 1, Delta(1)))
		Expect(Beside.Report).toBe("Blocked")
		local Done = Land(Key, Resolve(X, 1, "Commit"))
		Expect(Gold(Done)).toBe(12)
		Expect((Done :: any).s.Tag).toBe("won")
		Expect((Done :: any).p).toBeNil()
	end)

	Test("a drop moves a pinned record to the timed room as a decision that took", function()
		local Key = Land(Seed(1), Commit(X, 2, Delta(10)))
		local Dropped = Land(Key, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Drops = { X } })
		local Decision = Record(Dropped).Timed[X]
		Expect(Record(Dropped).Work[X]).toBeNil()
		Expect(Decision.Role).toBe(Role.Decision)
		Expect(Decision.Fate).toBe(Fate.Took)
		Expect(Decision.Attempt).toBe(2)
		local _, Again = Land(Dropped, Commit(X, 2, Delta(10)))
		Expect(Again.Report).toBe("Committed")
		Expect(Again.Attempt).toBe(2)
	end)

	Test("a decider holding the most pinned records reports owed and lists them", function()
		local Key = Seed(1)
		for Index = 1, Sizes.OWED_CAP do
			Key = Land(Key, Commit(Book.Drawn(8, Index), 1, Delta(1)))
		end
		local Held, Note, Wrote = Land(Key, Commit(X, 1, Delta(1)))
		Expect(Note.Report).toBe("Owed")
		Expect(Wrote).toBe(false)
		Expect(Gold(Held)).toBe(1 + Sizes.OWED_CAP)
		local Count = 0
		for _ in Note.Items :: any do
			Count += 1
		end
		Expect(Count).toBe(Sizes.OWED_CAP)
	end)

	Test("while a mark is CEILING old only an end path write lands, and a refused op lists the mark", function()
		local Late = NOW + Windows.CEILING
		local Key = Land(Seed(100), Tent(X, 1, Delta(-10)))
		local _, Refused, Wrote = Land(Key, Edit(1, 5), Late)
		Expect(Refused.Whys[1]).toBe("Overdue")
		Expect(Wrote).toBe(false)
		Expect((Refused.Items :: any)[X]).never.toBeNil()
		local Ended, _, Landed = Land(Key, Resolve(X, 1, "Abort"), Late)
		Expect(Landed).toBe(true)
		Expect(Record(Ended).Work[X]).toBeNil()
	end)

	Test("a Tent may make a key that need not exist, and a fence or a stale commit never does", function()
		local Made, Note = Land(nil, { Writer = 0, Ack = 0, MustExist = false, Ops = {}, Tent = Tent(X, 1, Delta(1)).Tent })
		Expect(Note.Report).toBe("Mine")
		Expect(Record(Made).Work[X]).never.toBeNil()
		local _, Fenced = Land(nil, Fence(X, 1, false))
		Expect(Fenced.Why).toBe("Missing")
		local Stale = Commit(X, 1, Delta(1)).Commit :: Types.Commit
		local Late: Request = { Writer = 0, Ack = 0, MustExist = false, Ops = {}, Commit = Stale }
		local _, Old = Land(nil, Late, NOW + DEFAULT.Minted + 1)
		Expect(Old.Why).toBe("Missing")
	end)
end)

return nil
