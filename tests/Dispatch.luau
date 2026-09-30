--!strict

--[=[

	Dispatch: The cases for Machine/Machine, on a toy machine.

	The toy asks twice in Asking, one Wait for each of its Keys, and Hear folds the replies into the
	count of those that failed. Rows send it on by that count. A When stops the second row once
	Tries runs out, and the third row, for the same count, catches it then. Two failures go to Else.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Asks = require("../src/Machine/Asks")
local Heard = require("./Heard")
local Machine = require("../src/Machine/Machine")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

type Context = { Tries: number, Path: { string } }
type Call = Machine.Call<Context, string>

local function Asking(Call: Call)
	table.insert(Call.Context.Path, "Asking")
	Machine.Ask(Call, Asks.Wait(1))
	Machine.Ask(Call, Asks.Wait(2))
end

local function Failures(Call: Call): string
	local Count = 0
	for _, Reply in Call.Heard do
		Count += if Reply.Said == Asks.SAID.Failed then 1 else 0
	end
	return tostring(Count)
end

local function TriesLeft(Call: Call): boolean
	Call.Context.Tries -= 1
	return Call.Context.Tries >= 0
end

local function Finish(Call: Call): string
	Machine.Answer(Call, "fine")
	return "Done"
end

local function Passing(Call: Call)
	table.insert(Call.Context.Path, "Passing")
end

local STATES: { [string]: Machine.State<Context, string> } = {
	Asking = {
		Enter = Asking,
		Hear = Failures,
		On = {
			{ Said = "0", Go = "Passing" },
			{ Said = "1", When = TriesLeft, Go = "Asking" },
			{ Said = "1", Go = "Stopped" },
		},
		Else = "Done",
	},
	Passing = { Enter = Passing, Else = Finish },
	Stopped = {},
	Done = {},
}

local Toy = Machine.Define({ Name = "Toy", Initial = "Asking", States = STATES })

local function Start(Tries: number): (Call, { Machine.Asked })
	return Machine.Start(Toy, { Tries = Tries, Path = {} }, Heard.NOW)
end

Describe("Dispatch", function()
	Test("a state goes on only once every ask is heard, and the first row that matches wins", function()
		local Call, Asked = Start(1)
		Expect(#Asked).toBe(2)
		Expect(#Machine.Step(Call, Asked[2].Id, Heard.Done())).toBe(0)
		Expect(Machine.StateOf(Call)).toBe("Asking")
		Machine.Step(Call, Asked[1].Id, Heard.Done())
		Expect(Machine.AnswerOf(Call)).toBe("fine")
		Expect(table.concat(Call.Context.Path, " ")).toBe("Asking Passing")
	end)

	Test("a row whose When fails is passed over for the next row, and a word no row takes goes to Else", function()
		local Call, First = Start(1)
		Machine.Step(Call, First[1].Id, Heard.Failed())
		local Asked = Machine.Step(Call, First[2].Id, Heard.Done())
		Expect(#Asked).toBe(2)
		Machine.Step(Call, Asked[1].Id, Heard.Failed())
		Machine.Step(Call, Asked[2].Id, Heard.Done())
		Expect(Machine.StateOf(Call)).toBe("Stopped")
		local Other, Both = Start(1)
		Machine.Step(Other, Both[1].Id, Heard.Failed())
		Machine.Step(Other, Both[2].Id, Heard.Failed())
		Expect(Machine.StateOf(Other)).toBe("Done")
	end)

	Test("Define refuses a state with rows and no Else, and a row to a state that is not there", function()
		Expect(function()
			Machine.Define({ Name = "Bad", Initial = "A", States = { A = { On = { { Said = "x", Go = "A" } } } } })
		end).toThrow("Machine Bad: A has rows and no Else")
		Expect(function()
			Machine.Define({ Name = "Bad", Initial = "A", States = { A = { Else = "B" } } })
		end).toThrow("Machine Bad: A goes to B, which is not a state")
	end)
end)

return nil
