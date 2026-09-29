--!strict

--[=[

	Sender: The cases for Server/Sender, stepped by hand with the replies a datastore gives.

	The game is tests/Gold. A landed reply runs the request's transform on the key first, as the
	datastore would.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Effect = require("../src/Server/Effect")
local Game = require("./Gold")
local Machine = require("../src/Core/Machine")
local Sender = require("../src/Server/Sender")
local Writer = require("../src/Server/Writer")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local function Add(Amount: number): Writer.Asked
	return { Form = "Minted", Kind = 0, MustExist = false, Body = { Add = Amount } }
end

local function Seconds(Sent: Effect.Effect): number?
	return if Sent.Kind == Effect.Kind.Wait then Sent.Seconds else nil
end

local function Land(Sent: Effect.Effect, Key: unknown): unknown
	return if Sent.Kind == Effect.Kind.Update then Sent.Transform(Key, nil) else nil
end

Describe("Sender", function()
	Test("a reply that settles nothing rests longer each time, and a landed one that empties the writer stops", function()
		local Key = Sender.New(nil :: any, "42", Game.DEFAULT, 16)
		Key.Writer:Push(Add(5))
		local Call, Effects, First = Machine.Start(Sender.Sending, Key)
		local Waits: { number? } = {}
		for _ = 1, 3 do
			Effects, First = Machine.Step(Call, First, false, "502: busy")
			table.insert(Waits, Seconds(Effects[1]))
			Effects, First = Machine.Step(Call, First, true)
		end
		Expect(table.concat(Waits :: { any }, " ")).toBe("1 2 4")
		local Value = Land(Effects[1], nil)
		Machine.Step(Call, First, true, Value, nil, true)
		Expect(Machine.IsFinal(Call)).toBe(true)
		Expect(Key.Running).toBe(false)
		Expect(Game.Gold(Value)).toBe(5)
	end)

	Test("a landed reply that leaves ops queued sends them at once", function()
		local Key = Sender.New(nil :: any, "42", Game.DEFAULT, 16)
		Key.Writer:Push(Add(5))
		local Call, Effects, First = Machine.Start(Sender.Sending, Key)
		Key.Writer:Push(Add(2))
		local Value = Land(Effects[1], nil)
		Effects, First = Machine.Step(Call, First, true, Value, nil, true)
		Expect(Machine.StateOf(Call)).toBe("Sending")
		Machine.Step(Call, First, true, Land(Effects[1], Value), nil, true)
		Expect(Machine.IsFinal(Call)).toBe(true)
	end)
end)

return nil
