--!strict
--!optimize 2

--[=[
	Replies: the one way the core answers a call, an Answer command, and settles an Unresolved call's outcome, an Emit
	on the Outcome stream: true, Refused, Spent, Full, Missing, Behind or Expired as heard, else Unresolved. A named no
	carries its call's name and first send time; Busy and Closed, decided before anything is sent, carry none.

	Return type: A plain table with DoneAnswer, UnresolvedAnswer, FailedAnswer, GivenNameOf, Named, Reply, ReplyFailed,
	OutcomeStream, IsUnresolved, SettleOutcome and SettleOutcomeUnresolved, and the OutcomeEmission type.
	Example usage:
		Replies.ReplyFailed(Commands, CallId, Reasons.Closed)
--]=]

local Events = require("./Events")
local Names = require("./Encoding/Names")
local Reasons = require("./Constants/Reasons")

type Answer = Events.Answer
type Command = Events.Command
type GivenName = Names.GivenName
type OpName = Names.OpName
type StoreKey = Names.StoreKey
type Reason = Reasons.Reason

export type OutcomeEmission = { read CallId: number, read Answer: Answer }

local DoneAnswer: Answer = table.freeze({ Kind = "Succeeded" :: "Succeeded", Value = nil })

local OutcomeStream = "Outcome"

local SentNothing: { [Reason]: true } = {
	[Reasons.Busy] = true,
	[Reasons.Closed] = true,
}

local function FailedAnswer(Reason: Reason): Answer
	return { Kind = "Failed", Reason = Reason, State = nil }
end

local UnresolvedAnswer: Answer = table.freeze(FailedAnswer(Reasons.Unresolved))

local OutcomeReasons: { [Reason]: true } = {
	[Reasons.Refused] = true,
	[Reasons.Spent] = true,
	[Reasons.Full] = true,
	[Reasons.Missing] = true,
	[Reasons.Behind] = true,
	[Reasons.Expired] = true,
}

local function GivenNameOf(Name: OpName, Stamp: number): GivenName
	if Name.Kind == "Drawn" then
		return { Kind = "Drawn", Server = Name.Server, Counter = Name.Counter, Stamp = Stamp }
	end
	return { Kind = "Game", Text = Name.Text, Stamp = Stamp }
end

local function Named(Given: Answer, Name: GivenName?): Answer
	if Given.Kind ~= "Failed" or Name == nil or SentNothing[Given.Reason] then
		return Given
	end
	return {
		Kind = "Failed",
		Reason = Given.Reason,
		State = Given.State,
		Identity = Given.Identity,
		Name = Name,
		ShortReason = Given.ShortReason,
		Key = Given.Key,
	}
end

local function Reply(Commands: { Command }, CallId: number, Given: Answer)
	local Answered: Command = { Kind = "Answer", CallId = CallId, Answer = Given }
	table.insert(Commands, Answered)
end

local function ReplyFailed(Commands: { Command }, CallId: number, Reason: Reason)
	Reply(Commands, CallId, FailedAnswer(Reason))
end

local function IsUnresolved(Given: Answer): boolean
	return Given.Kind == "Failed" and Given.Reason == Reasons.Unresolved
end

local function OutcomeAnswerOf(Given: Answer): Answer
	if Given.Kind == "Succeeded" or OutcomeReasons[Given.Reason] then
		return Given
	end
	return UnresolvedAnswer
end

local function SettleOutcome(Commands: { Command }, Key: StoreKey, CallId: number, Given: Answer)
	local Emission: OutcomeEmission = { CallId = CallId, Answer = OutcomeAnswerOf(Given) }
	local Emitted: Command = { Kind = "Emit", Stream = OutcomeStream, Key = Key, Value = Emission }
	table.insert(Commands, Emitted)
end

local function SettleOutcomeUnresolved(Commands: { Command }, Key: StoreKey, CallId: number)
	SettleOutcome(Commands, Key, CallId, UnresolvedAnswer)
end

return {
	DoneAnswer = DoneAnswer,
	UnresolvedAnswer = UnresolvedAnswer,
	FailedAnswer = FailedAnswer,
	GivenNameOf = GivenNameOf,
	Named = Named,
	Reply = Reply,
	ReplyFailed = ReplyFailed,
	OutcomeStream = OutcomeStream,
	IsUnresolved = IsUnresolved,
	SettleOutcome = SettleOutcome,
	SettleOutcomeUnresolved = SettleOutcomeUnresolved,
}
