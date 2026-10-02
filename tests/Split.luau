--!strict

--[=[

	Split: The cases for Calls/Split, stepped directly with the replies it hears.

	A part's value is made by the real Step: Value opens a part with a share at a stamp, and takes
	units from it. Swords is a final quantity on 2 parts.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Asks = require("../src/Machine/Asks")
local Game = require("./Gold")
local Heard = require("./Heard")
local Machine = require("../src/Machine/Machine")
local Parts = require("../src/Record/Parts")
local Split = require("../src/Calls/Split")
local Step = require("../src/Record/Step")
local Tx = require("../src/Calls/Tx")
local Types = require("../src/Record/Types")
local Windows = require("../src/Core/Constants/Windows")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local NOW = Heard.NOW
local PRINT = 7
local SWORDS: Parts.Declared = { Name = "Swords", Parts = 2, Mode = "Final", Stock = 3, Proceeds = {}, Print = PRINT, Place = "Gold$P:Swords:2" }
local USING = Parts.Build(Game.DEFAULT, SWORDS)

local function Send(Current: unknown, Body: { [string]: any }, Name: string, At: number): unknown
	local Commit: Types.Commit = { Name = Name, Stamp = At, Attempt = 1, Print = PRINT, Legs = {}, Leg = { Body = Body } }
	local Note = Step(Current, { Writer = 0, Ack = 0, MustExist = Body.Kind ~= "Open", Ops = {}, Commit = Commit }, At, USING)
	return Note.Stored or Current
end

local function Value(Share: number, Opened: number, Taken: number): unknown
	local Made = Send(nil, { Kind = "Open", Share = Share, At = Opened }, "open", Opened)
	if Taken > 0 then
		Made = Send(Made, { Kind = "Take", Count = Taken, Print = PRINT }, "take", Opened)
	end
	return Made
end

type Sent = { Key: string, MustExist: boolean, Body: any }

local function Bodies(Asked: { Machine.Asked }): { Sent }
	local Found: { Sent } = {}
	for _, Each in Asked do
		local Ask = Each.Ask
		local Running = if Ask.Kind == "Run" then Ask.Context :: Tx.Context else error("not a run")
		local Leg = Running.Legs[1]
		local Made: Sent = { Key = Leg.Ref.Key, MustExist = Leg.MustExist, Body = Leg.Change.Body }
		table.insert(Found, Made)
	end
	return Found
end

Describe("Split", function()
	Test("open makes every part with its share under one stamp, tries the rest again, and stops past REMOVE_SEND", function()
		local Call, Asked = Machine.Start(Split.Open, Split.Context(SWORDS, "open:Swords", NOW, 9), NOW)
		local Sent = Bodies(Asked)
		Expect(#Sent).toBe(2)
		Expect(Sent[1].MustExist).toBe(false)
		Expect((Sent[1].Body :: any).Share + (Sent[2].Body :: any).Share).toBe(3)
		Expect((Sent[2].Body :: any).At).toBe(NOW)
		Machine.Step(Call, Asked[1].Id, Heard.Done(true))
		Asked = Machine.Step(Call, Asked[2].Id, Heard.Done("Unresolved"))
		Expect(Asked[1].Ask.Kind).toBe("Wait")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Expect(Bodies(Asked)[1].Key).toBe(Parts.Key("Swords", 2, 1))
		Machine.Step(Call, Asked[1].Id, Asks.Done(NOW + Windows.REMOVE_SEND + 1, "Unresolved"))
		Expect(Machine.AnswerOf(Call)).toBe("Unresolved")
		Call, Asked = Machine.Start(Split.Open, Split.Context(SWORDS, "open:Swords", NOW, 9), NOW)
		Machine.Step(Call, Asked[1].Id, Heard.Done(true))
		Machine.Step(Call, Asked[2].Id, Heard.Done(true))
		Expect(Machine.AnswerOf(Call)).toBe(true)
	end)

	Test("close removes only a closed part that is empty and opened SEAL_AGE ago, and counts a gone part as removed", function()
		local Old = NOW - Windows.SEAL_AGE
		local Call, Asked = Machine.Start(Split.Close, Split.Context(SWORDS, "close:Swords", NOW, 9), NOW)
		Expect((Bodies(Asked)[1].Body :: any).Kind).toBe("Close")
		Machine.Step(Call, Asked[1].Id, Heard.Done(true))
		Asked = Machine.Step(Call, Asked[2].Id, Heard.Done(true))
		Expect(Asked[1].Ask.Kind).toBe("Read")
		Machine.Step(Call, Asked[1].Id, Heard.Read(Value(1, Old, 1)))
		Asked = Machine.Step(Call, Asked[2].Id, Heard.Read(Value(2, Old, 1)))
		Expect(#Asked).toBe(1)
		Expect(Asked[1].Ask.Kind).toBe("Remove")
		Machine.Step(Call, Asked[1].Id, Heard.Done())
		local Result = Machine.AnswerOf(Call) :: Split.Closed
		Expect(Result.Removed).toBe(1)
		Expect(Result.Left).toBe(1)
		Call, Asked = Machine.Start(Split.Close, Split.Context(SWORDS, "close:Swords", NOW, 9), NOW)
		local Gone = (Asked[2].Ask :: any).Context :: Tx.Context
		Gone.Verdict = Heard.Note({ Why = "Missing" })
		Machine.Step(Call, Asked[1].Id, Heard.Done(true))
		Asked = Machine.Step(Call, Asked[2].Id, Heard.Done("Unresolved"))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Value(1, NOW - 10, 1)))
		Expect(#Asked).toBe(0)
		Result = Machine.AnswerOf(Call) :: Split.Closed
		Expect(Result.Removed).toBe(1)
		Expect(Result.Left).toBe(1)
	end)
end)

return nil
