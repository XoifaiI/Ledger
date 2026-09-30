--!strict

--[=[

	Reads: The cases for Record/View, Server/Shown, Server/Peek and Server/DidApply.

	Keys are written by the real Step for the game in tests/Gold. The machines are stepped by hand with
	the replies a datastore gives, and an update's transform is run on the key as the datastore would.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Answer = require("../src/Core/Answer")
local DidApply = require("../src/Server/DidApply")
local Effect = require("../src/Server/Effect")
local Game = require("./Gold")
local Limits = require("../src/Core/Constants/Limits")
local Machine = require("../src/Core/Machine")
local Peek = require("../src/Server/Peek")
local Shown = require("../src/Server/Shown")
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

local function Land(Sent: Effect.Effect, Current: unknown): unknown
	return if Sent.Kind == Effect.Kind.Update then Sent.Transform(Current, nil) else nil
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
end)

Describe("Peek", function()
	Test("a read the table allows is shown, and one older than shown is read fresh", function()
		local Stored = Key({ Mint(4) })
		local Table = Shown.New()
		local Call, Effects, First = Machine.Start(Peek.Cached, Peek.Context(nil :: any, "42", "s/42", Game.DEFAULT, Table))
		Machine.Step(Call, First, true, Stored)
		Expect((Machine.AnswerOf(Call) :: View.View).Writes).toBe(1)

		Table:Show("s/42", 9)
		Call, Effects, First = Machine.Start(Peek.Cached, Peek.Context(nil :: any, "42", "s/42", Game.DEFAULT, Table))
		Effects, First = Machine.Step(Call, First, true, Stored)
		Expect(Machine.StateOf(Call)).toBe("Refreshing")
		local Fresh = Land(Effects[1], Stored)
		Machine.Step(Call, First, true, Fresh, nil, true)
		Expect((Machine.AnswerOf(Call) :: View.View).Writes).toBe(2)
	end)

	Test("a peek that keeps failing answers Unresolved", function()
		local Call, Effects, First = Machine.Start(Peek.Cached, Peek.Context(nil :: any, "42", "s/42", Game.DEFAULT, Shown.New()))
		for _ = 1, Limits.TRIES - 1 do
			Effects, First = Machine.Step(Call, First, false, "502: busy")
			Effects, First = Machine.Step(Call, First, true)
		end
		Expect(Effects[1].Kind).toBe(Effect.Kind.Get)
		Machine.Step(Call, First, false, "502: busy")
		Expect(Machine.AnswerOf(Call)).toBe(Answer.Unresolved)
	end)
end)

Describe("DidApply", function()
	Test("a read says true only for a name held as took, and a probe that lands says false", function()
		local Stored = Key({ { Form = "Timed", Seq = 1, Stamp = NOW, Kind = 1, Name = "order", Print = 7, Body = { Add = 1 } } })
		local function Start(Of: any, Name: string): (Effect.Call<DidApply.Context, boolean | Answer.Answer>, { Effect.Effect }, number)
			return Machine.Start(Of, DidApply.Context(nil :: any, "42", Game.DEFAULT, { Name = Name, Stamp = NOW }))
		end
		local Call, Effects, First = Start(DidApply.Reading, "order")
		Machine.Step(Call, First, true, Stored, nil, false)
		Expect(Machine.AnswerOf(Call)).toBe(true)
		Call, Effects, First = Start(DidApply.Reading, "other")
		Machine.Step(Call, First, true, Stored, nil, false)
		Expect(Machine.AnswerOf(Call)).toBe(Answer.Unresolved)
		Call, Effects, First = Start(DidApply.Probing, "other")
		Machine.Step(Call, First, true, Land(Effects[1], Stored), nil, true)
		Expect(Machine.AnswerOf(Call)).toBe(false)
	end)
end)

return nil
