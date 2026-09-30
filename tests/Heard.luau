--!strict

--[=[

	Heard: The replies a machine hears, built by hand for cases that step a machine directly.

	Note fills a note with an empty landing and lays the given fields over it. Sent is the reply to
	a Send that heard that note, Read the reply to a Read of a value, Done the reply to a Wait or a
	Run, and Failed the reply to an ask that kept failing. Every reply comes back at NOW.

	Return type: A table with Note, Sent, Read, Done, Failed and NOW.
	Example usage:
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Fenced" }))
--]=]

local Asks = require("../src/Machine/Asks")
local Clock = require("../src/Machine/Clock")
local Types = require("../src/Record/Types")

local NOW = Clock.Now()

local function Note(Fields: { [string]: any }): Types.Note
	local Made: { [string]: any } = { Fates = {}, Whys = {}, Decided = {}, Writes = 1, Cuts = 0, Horizon = 0, CutHorizon = 0 }
	for Field, Value in Fields do
		Made[Field] = Value
	end
	return Made :: any
end

local function Sent(Fields: { [string]: any }, Wrote: boolean?): Asks.Heard
	return Asks.Noted(Note(Fields), NOW, Wrote)
end

local function Read(Value: unknown): Asks.Heard
	return Asks.Got(Value, NOW)
end

local function Done(Answer: unknown?): Asks.Heard
	return Asks.Done(NOW, Answer)
end

local function Failed(Wrote: boolean?): Asks.Heard
	return Asks.Failed(NOW, Wrote == true)
end

return {
	Note = Note,
	Sent = Sent,
	Read = Read,
	Done = Done,
	Failed = Failed,
	NOW = NOW,
}
