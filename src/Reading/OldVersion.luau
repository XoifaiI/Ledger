--!strict
--!optimize 2

--[=[
	OldVersion: what one old version of a key answers, for Store:PeekVersion: the state exactly as that version saved
	it, at the level it was saved at, with no migration run and no unfinished trade work applied. It learns nothing
	about the key. A tombstone or a seal answers Missing; a newer Ledger's value answers Behind.

	Return type: A plain table with AnswerOf.
	Example usage:
		local Answered = OldVersion.AnswerOf(Setup, Raw)
--]=]

local Events = require("../Events")
local Reasons = require("../Constants/Reasons")
local Replies = require("../Replies")
local Shapes = require("../Shapes")
local Unreadable = require("./Unreadable")
local Value = require("../Stored/Value")

type Answer = Events.Answer
type Setup = Shapes.Setup

local MissingAnswer = table.freeze(Replies.FailedAnswer(Reasons.Missing))

local function AnswerOf(Setup: Setup, Raw: unknown): Answer
	if Raw == nil then
		return MissingAnswer
	end
	local Decoded = Value.DecodeStored(Raw, Setup.Build, Setup.Limits.WindowUnit)
	if Decoded.Kind == "Unreadable" then
		return Replies.FailedAnswer(Unreadable.ReasonOf(Decoded.Cause))
	end
	if Decoded.Kind == "Sealed" then
		return MissingAnswer
	end
	return { Kind = "Succeeded", Value = Decoded.State }
end

return {
	AnswerOf = AnswerOf,
}
