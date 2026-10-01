--!strict

--[=[

	Reads: The cases for Record/View, Record/Shown, Calls/Peek and Calls/DidApply.

	Keys are written by the real Step for the game in tests/Gold. The machines are stepped directly:
	a read hears a key, and a send hears the note of the real Step run on it.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Answer = require("../src/Core/Answer")
local Book = require("../src/Record/Book")
local Asks = require("../src/Machine/Asks")
local Clock = require("../src/Machine/Clock")
local DidApply = require("../src/Calls/DidApply")
local Game = require("./Gold")
local Limits = require("../src/Core/Constants/Limits")
local Machine = require("../src/Machine/Machine")
local Peek = require("../src/Calls/Peek")
local Replay = require("./Replay")
local Shown = require("../src/Record/Shown")
local Step = require("../src/Record/Step")
local Types = require("../src/Record/Types")
local View = require("../src/Record/View")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local NOW = Game.NOW

local function Key(Ops: { Types.Op }, Using: Types.Build?): unknown
	return Step(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = Ops }, NOW, Using or Game.DEFAULT).Stored
end

local function Mint(Add: number): Types.Op
	return { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = Add } }
end

local function Land(Asked: { Machine.Asked }, Current: unknown): Asks.Heard
	local Ask = Asked[1].Ask
	local Note = Step(Current, if Ask.Kind == "Send" then Ask.Request else error("not a send"), NOW, Game.DEFAULT)
	return Asks.Noted(Note, NOW, Note.Stored ~= nil)
end

Describe("View", function()
	Test("a key is shown through this build, with its missing migrations run and nothing written", function()
		local Stored = Key({ Mint(4) })
		local Newer = Game.Build({ Level = 1, Migrations = {
			function(State: any): unknown
				return { Gold = State.Gold * 2 }
			end,
		} })
		local Shown = View.Read(Stored, Newer) :: View.View
		Expect(Shown.State.Gold).toBe(8)
		Expect(Shown.Writes).toBe(1)
		Expect(Game.Gold(Stored)).toBe(4)
	end)

	Test("a key that is empty, sealed, broken, past the floor, or whose migrations fail is not shown", function()
		Expect(View.Read(nil, Game.DEFAULT)).toBe(Answer.Missing)
		Expect(View.Read({ z = "seal" }, Game.DEFAULT)).toBe(Answer.Missing)
		Expect(View.Read({ s = {}, b = "=" }, Game.DEFAULT)).toBe(Answer.Unresolved)
		Expect(View.Read(Key({ Mint(1) }, Game.Build({ Floor = 2 })), Game.DEFAULT)).toBe(Answer.Behind)
		local Broken = Game.Build({ Level = 1, Migrations = {
			function(): unknown
				error("broken")
			end,
		} })
		Expect(View.Read(Key({ Mint(1) }), Broken)).toBe(Answer.Refused)
	end)
end)

Describe("Shown", function()
	Test("a view older than one shown is refused, and a forgotten key must be read fresh", function()
		local Table = Shown.New()
		Expect(Table:Allows("a", 3)).toBe(true)
		Table:Show("a", 3)
		Expect(Table:Allows("a", 2)).toBe(false)
		Expect(Table:Allows("a", 3)).toBe(true)
		for Index = 1, Limits.SHOWN_MAX do
			Table:Show(`k{Index}`, 1)
		end
		Expect(Table:Stale("a")).toBe(true)
		Expect(Table:Allows("a", 99)).toBe(false)
		Table:Show("a", 5)
		Expect(Table:Stale("a")).toBe(false)
	end)

	Test("a pinned key is never forgotten, and can be forgotten again once unpinned", function()
		local Table = Shown.New()
		Table:Show("a", 3)
		Table:Pin("a", 2)
		for Index = 1, Limits.SHOWN_MAX do
			Table:Show(`k{Index}`, 1)
		end
		Expect(Table:Stale("a")).toBe(false)
		Expect(Table:Allows("a", 2)).toBe(false)
		Table:Show("a", 4)
		Table:Unpin("a")
		Expect(Table:Allows("a", 3)).toBe(false)
		Expect(Table:Allows("a", 4)).toBe(true)
		for Index = 1, Limits.SHOWN_MAX do
			Table:Show(`j{Index}`, 1)
		end
		Expect(Table:Stale("a")).toBe(true)
	end)
end)

Describe("Peek", function()
	Test("a read the table allows is shown, and one older than shown is read fresh", function()
		local Stored = Key({ Mint(4) })
		local Table = Shown.New()
		local Ref = { Store = "s", Key = "42" }
		local Call, Asked = Machine.Start(Peek.Cached, Peek.Context(Ref, Game.DEFAULT, Table), NOW)
		Machine.Step(Call, Asked[1].Id, Asks.Got(Stored, NOW))
		Expect((Machine.AnswerOf(Call) :: View.View).Writes).toBe(1)

		Table:Show("s/42", 9)
		Call, Asked = Machine.Start(Peek.Cached, Peek.Context(Ref, Game.DEFAULT, Table), NOW)
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Got(Stored, NOW))
		Expect(Machine.StateOf(Call)).toBe("Refreshing")
		Machine.Step(Call, Asked[1].Id, Land(Asked, Stored))
		Expect((Machine.AnswerOf(Call) :: View.View).Writes).toBe(2)
	end)

	Test("a read that failed answers Unresolved", function()
		local Call, Asked = Machine.Start(Peek.Cached, Peek.Context({ Store = "s", Key = "42" }, Game.DEFAULT, Shown.New()), NOW)
		Machine.Step(Call, Asked[1].Id, Asks.Failed(NOW, false))
		Expect(Machine.AnswerOf(Call)).toBe(Answer.Unresolved)
	end)
end)

Describe("Peek beside marks", function()
	local Live = Clock.Now()
	local Y = Book.Drawn(4, 1)

	local function Write(Current: unknown, Asked: Types.Request): unknown
		return assert(Step(Current, Asked, Live, Game.DEFAULT).Stored, "the setup write did not land")
	end

	local function Keys(Unclean: boolean, Committed: boolean): Replay.Keys
		local Op: Types.Op = { Form = "Minted", Seq = 1, Stamp = Live, Kind = 0, Body = { Add = 100 } }
		local Tent: Types.Tent = { Name = Y, Stamp = Live, Attempt = 1, Decider = { Store = "Gold", Key = "d" }, Leg = { Field = 1, Amount = -30 } }
		local A = Write(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = { Op } })
		A = Write(A, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Tent = Tent })
		if Unclean then
			local Edit: Types.Op = { Form = "Minted", Seq = 2, Stamp = Live, Kind = 0, Body = { Add = 5 } }
			A = Write(A, { Writer = 1, Ack = 1, MustExist = true, Ops = { Edit } })
		end
		local D = Write(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = { Op } })
		if Committed then
			local Commit: Types.Commit = { Name = Y, Stamp = Live, Attempt = 1, Legs = { { Store = "Gold", Key = "a" } }, Leg = { Field = 1, Amount = 30 } }
			D = Write(D, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Commit = Commit })
		end
		return { a = A, d = D }
	end

	local function Show(Held: Replay.Keys): (View.View, number, number)
		local Context = Peek.Context({ Store = "Gold", Key = "a" }, Game.DEFAULT, Shown.New())
		local Found, Updates, Sends = Replay.Run(Peek.Cached, Context, Held, Game.DEFAULT, Live)
		return Found :: View.View, Updates, Sends
	end

	Test("a clean mark is shown as it is, and its decider is not read", function()
		local Found, _, Sends = Show(Keys(false, true))
		Expect(Found.State.Gold).toBe(100)
		Expect(Sends).toBe(0)
	end)

	Test("an unclean mark whose use did not commit is shown as it is", function()
		local Found, Updates = Show(Keys(true, false))
		Expect(Found.State.Gold).toBe(105)
		Expect(Updates).toBe(0)
	end)

	Test("an unclean mark whose use committed is resolved by the read, and the landing is shown", function()
		local Held = Keys(true, true)
		local Found, Updates = Show(Held)
		Expect(Found.State.Gold).toBe(75)
		Expect(Updates).toBe(1)
		Expect(Game.Record(Held.a).Work[Y]).toBeNil()
	end)

	Test("an unclean mark whose decider cannot be read is not shown, since its use may have committed", function()
		local Held = Keys(true, true)
		local Context = Peek.Context({ Store = "Gold", Key = "a" }, Game.DEFAULT, Shown.New())
		local Call, Asked = Machine.Start(Peek.Cached, Context, Live)
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Got(Held.a, Live))
		Expect(Asked[1].Ask.Kind).toBe("Read")
		Machine.Step(Call, Asked[1].Id, Asks.Failed(Live, false))
		Expect(Machine.AnswerOf(Call)).toBe(Answer.Unresolved)
	end)
end)

Describe("DidApply", function()
	Test("a read says true only for a name held as took, and a probe that lands says false", function()
		local Stored = Key({ { Form = "Timed", Seq = 1, Stamp = NOW, Kind = 1, Name = "order", Print = 7, Body = { Add = 1 } } })
		local Ref = { Store = "Gold", Key = "42" }
		local Call, Asked = Machine.Start(DidApply.Reading, DidApply.Context(Ref, "order", NOW), NOW)
		Machine.Step(Call, Asked[1].Id, Asks.Got(Stored, NOW))
		Expect(Machine.AnswerOf(Call)).toBe(true)
		Call, Asked = Machine.Start(DidApply.Reading, DidApply.Context(Ref, "other", NOW), NOW)
		Machine.Step(Call, Asked[1].Id, Asks.Got(Stored, NOW))
		Expect(Machine.AnswerOf(Call)).toBe(Answer.Unresolved)
		Call, Asked = Machine.Start(DidApply.Probing, DidApply.Context(Ref, "other", NOW), NOW)
		Machine.Step(Call, Asked[1].Id, Land(Asked, Stored))
		Expect(Machine.AnswerOf(Call)).toBe(false)
	end)

	Test("a use pinned on its decider answers true, and a standing mark answers Unresolved, from a read or a probe", function()
		local Leg: Types.Leg = { Field = 1, Amount = 10 }
		local function Placed(Asked: Types.Request): unknown
			return Step(Key({ Mint(1) }), Asked, NOW, Game.DEFAULT).Stored
		end
		local Pinned = Placed({
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Commit = { Name = "order", Stamp = NOW, Attempt = 1, Print = 7, Legs = { { Store = "Gold", Key = "a" } }, Leg = Leg },
		})
		local Marked = Placed({
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Tent = { Name = "order", Stamp = NOW, Attempt = 1, Print = 7, Decider = { Store = "Gold", Key = "d" }, Leg = Leg },
		})
		local Ref = { Store = "Gold", Key = "42" }
		for _, Case in { { Pinned, true }, { Marked, Answer.Unresolved } } do
			local Stored, Expected = Case[1], Case[2]
			local Call, Asked = Machine.Start(DidApply.Reading, DidApply.Context(Ref, "order", NOW), NOW)
			Machine.Step(Call, Asked[1].Id, Asks.Got(Stored, NOW))
			Expect(Machine.AnswerOf(Call)).toBe(Expected)
			Call, Asked = Machine.Start(DidApply.Probing, DidApply.Context(Ref, "order", NOW), NOW)
			Machine.Step(Call, Asked[1].Id, Land(Asked, Stored))
			Expect(Machine.AnswerOf(Call)).toBe(Expected)
		end
	end)
end)

return nil
