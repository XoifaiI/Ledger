--!strict
--!optimize 2

--[=[
	Reports: what a Tx call's coordinator does with each report (transaction sheets 15.1 to 15.4, A7, A8). Past
	RetryRounds errors the call answers Unresolved, still sending while an Err is among them, or Unreadable if every
	failing key is unreadable. A Refused, Full, Behind or Missing no names its deciding leg; a Refused or Full no also
	carries its State. A Tent or Commit that carried "absent" and meets a key another call made is sent again with
	that key's id while no send of it there may have run (record 5.1), so concurrent calls into a new key all land.

	Return type: A plain table of functions.
	Example usage:
		Reports.HearTent(State, Call, Key, Result, Clock, Commands)
--]=]

local AfterAnswer = require("./AfterAnswer")
local Book = require("../../Stored/Book")
local Cache = require("../../Reading/Cache")
local Composed = require("../../Composed")
local Entries = require("../../Stored/Entries")
local Events = require("../../Events")
local Fates = require("../../Stored/Items/Fates")
local JudgingShapes = require("../../Judging/Shapes")
local Lookup = require("../../Stored/Lookup")
local Marks = require("../Legs/Marks")
local NextSteps = require("./NextSteps")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Reasons = require("../../Constants/Reasons")
local Requests = require("./Requests")
local TentReports = require("./TentReports")
local TxCalls = require("./Call")
local TxState = require("../State")

type Book = Book.Book
type Command = Events.Command
type GivenAnswer = Events.Answer
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type Fate = Fates.Fate
type OpName = Names.OpName
type StoreKey = Names.StoreKey
type Reason = Reasons.Reason
type Note = JudgingShapes.Note
type State = Composed.State
type Call = TxState.Call
type Refusal = TentReports.Refusal
type DeciderRefusal = { read Fate: Fate, read State: unknown }

local TookBy = {
	Own = "Own" :: "Own",
	OtherTerms = "OtherTerms" :: "OtherTerms",
	Nobody = "Nobody" :: "Nobody",
}
type TookBy = keyof<typeof(TookBy)>

local function FailedWith(Why: Reason): GivenAnswer
	return { Kind = "Failed", Reason = Why, State = nil }
end

local function AnswerTrue(Call: Call, Commands: { Command })
	TxCalls.Answer(Call, { Kind = "Succeeded", Value = true }, Commands)
end

local function AnswerNo(Call: Call, Why: Reason, Commands: { Command })
	TxCalls.Answer(Call, FailedWith(Why), Commands)
end

local function EndWith(State: State, Call: Call, Given: GivenAnswer, Commands: { Command })
	TxCalls.Answer(Call, Given, Commands)
	TxCalls.End(State, Call, Commands)
end

local function EndNo(State: State, Call: Call, Why: Reason, Commands: { Command })
	EndWith(State, Call, FailedWith(Why), Commands)
end

local function KeepWorking(State: State, Call: Call, Clock: number, Commands: { Command })
	AnswerNo(Call, Reasons.Unresolved, Commands)
	NextSteps.SendAgainLater(State, Call, Clock)
end

local function GiveUpUnreadable(State: State, Call: Call, Clock: number, Commands: { Command })
	if not Call.IsUnclean then
		return EndNo(State, Call, Reasons.Unreadable, Commands)
	end
	if Requests.IsEachUnreadable(Call, { Call.Decider }) then
		return EndNo(State, Call, Reasons.Unresolved, Commands)
	end
	Call.GivesUp = "Unreadable"
	NextSteps.FenceFinal(State, Call, Clock, Commands)
end

local function AfterErrors(State: State, Call: Call, Erred: { StoreKey }, Clock: number, Commands: { Command })
	if Requests.HasPlatformError(Call, Erred) then
		return KeepWorking(State, Call, Clock, Commands)
	end
	if Requests.IsEachUnreadable(Call, Erred) then
		return GiveUpUnreadable(State, Call, Clock, Commands)
	end
	EndNo(State, Call, Reasons.Unresolved, Commands)
end

local function ReasonOfFate(Fate: Fate): Reason
	if Fate.Kind == "Full" then
		return Reasons.Full
	end
	return Reasons.Refused
end

local function RefusalAnswer(Refusal: Refusal): GivenAnswer
	return { Kind = "Failed", Reason = ReasonOfFate(Refusal.Fate), State = Refusal.State, Key = Refusal.Key }
end

local function BehindAnswer(Call: Call): GivenAnswer
	return { Kind = "Failed", Reason = Reasons.Behind, State = nil, Key = TentReports.BehindLeg(Call) }
end

local function AbortWith(State: State, Call: Call, Given: GivenAnswer, Clock: number, Commands: { Command })
	TxCalls.Answer(Call, Given, Commands)
	AfterAnswer.SendAbortResolves(State, Call, Clock, Commands)
end

local function AbortCall(State: State, Call: Call, Why: Reason, Clock: number, Commands: { Command })
	AbortWith(State, Call, FailedWith(Why), Clock, Commands)
end

local function AbortRefused(State: State, Call: Call, Refused: DeciderRefusal, Clock: number, Commands: { Command })
	Call.DeciderFate = Refused.Fate
	local Refusal: Refusal = { Key = Call.Decider, Fate = Refused.Fate, State = Refused.State }
	AbortWith(State, Call, RefusalAnswer(Refusal), Clock, Commands)
end

local function CommitCall(
	State: State,
	Call: Call,
	Attempt: number,
	DeciderValue: number?,
	Clock: number,
	Commands: { Command }
)
	AnswerTrue(Call, Commands)
	AfterAnswer.SendCommitResolves(State, Call, Attempt, DeciderValue, Clock, Commands)
end

local function GiveUpBehind(State: State, Call: Call, Clock: number, Commands: { Command })
	Call.GivesUp = "Behind"
	if Call.IsUnclean then
		return NextSteps.FenceFinal(State, Call, Clock, Commands)
	end
	EndWith(State, Call, BehindAnswer(Call), Commands)
end

local function Redraw(State: State, Call: Call, Clock: number, Commands: { Command })
	Call.Name = Names.WithPart(Numbers.DrawnName(State.Server), Call.Name.Part)
	Call.Stamp = Clock
	Call.HasRedrawn = true
	Call.Attempt = TxState.FirstAttempt
	Call.Mine = {}
	Call.TentReports = {}
	NextSteps.SendTentsAgain(State, Call, Clock, Commands)
end

local function AfterForgotten(State: State, Call: Call, Clock: number, Commands: { Command })
	if Call.IsUnclean then
		return NextSteps.FenceFinal(State, Call, Clock, Commands)
	end
	if Call.Name.Kind == "Drawn" and not Call.HasRedrawn then
		return Redraw(State, Call, Clock, Commands)
	end
	EndNo(State, Call, Reasons.Expired, Commands)
end

local function AfterMissing(State: State, Call: Call, Leg: TentReports.MissingLeg, Clock: number, Commands: { Command })
	if Call.IsUnclean then
		return NextSteps.FenceFinal(State, Call, Clock, Commands)
	end
	local Answer: GivenAnswer =
		{ Kind = "Failed", Reason = Reasons.Missing, State = nil, Identity = Leg.Identity, Key = Leg.Key }
	TxCalls.Answer(Call, Answer, Commands)
	TxCalls.End(State, Call, Commands)
end

local function AfterTents(State: State, Call: Call, Clock: number, Commands: { Command })
	local Refusal = TentReports.FirstRefusal(Call)
	if Refusal ~= nil then
		return AbortWith(State, Call, RefusalAnswer(Refusal), Clock, Commands)
	end
	if NextSteps.AreAllMine(Call) then
		return NextSteps.StartCommit(State, Call, Clock, Commands)
	end
	if TentReports.FirstWhere(Call, TentReports.EndsInFence) ~= nil then
		return NextSteps.FenceFinal(State, Call, Clock, Commands)
	end
	if TentReports.FirstWhere(Call, TentReports.IsBehindReport) ~= nil then
		return GiveUpBehind(State, Call, Clock, Commands)
	end
	if TentReports.FirstWhere(Call, TentReports.IsForgottenReport) ~= nil then
		return AfterForgotten(State, Call, Clock, Commands)
	end
	local Missing = TentReports.FirstMissingLeg(Call)
	if Missing ~= nil then
		return AfterMissing(State, Call, Missing, Clock, Commands)
	end
	local Gated = TentReports.FirstWhere(Call, TentReports.IsGatedReport)
	if Gated ~= nil and Gated.Kind == "Gated" then
		return NextSteps.WaitOutGate(State, Call, Gated.Gate, Clock, Commands)
	end
	local Blocked = TentReports.BlockedTents(Call)
	if #Blocked > 0 then
		return NextSteps.HelpWith(State, Call, Blocked, Clock, Commands)
	end
	if TentReports.FirstWhere(Call, TentReports.IsSentAgainReport) ~= nil then
		return NextSteps.SendAgainLater(State, Call, Clock)
	end
	if TentReports.HasErredKey(Call) then
		return AfterErrors(State, Call, Call.OtherKeys, Clock, Commands)
	end
	EndNo(State, Call, Reasons.Unresolved, Commands)
end

local function HasOtherMark(Note: Note, Name: OpName): boolean
	for _, Item in Note.Work do
		if Item.Kind ~= "Pinned" and not Marks.IsOfUse(Item, Name) then
			return true
		end
	end
	return false
end

local function HearTent(State: State, Call: Call, Key: StoreKey, Result: Outcome, Clock: number, Commands: { Command })
	local Text = Names.KeyText(Key)
	local Report = Requests.LearnFromAnswer(State, Call, Key, Result, Commands)
	if Result.Kind == "Err" or Report == nil then
		Call.MayHoldMark[Text] = true
		Call.OtherMarkOn[Text] = true
		Call.TentReports[Text] = nil
		if Requests.IsResendDue(State.Server, Call, Key) then
			return Requests.SendTent(State, Call, Key, Clock, Commands)
		end
	elseif Requests.RetagOnMissing(Call, Key, Report) then
		Call.TentReports[Text] = nil
		return Requests.SendTent(State, Call, Key, Clock, Commands)
	else
		Call.TentReports[Text] = Report
		if Report.Kind == "Mine" then
			Call.Mine[Text] = true
		end
		if Report.Kind == "Mine" or Result.Note.Closure.Wrote then
			Call.MayHoldMark[Text] = true
		end
		Call.OtherMarkOn[Text] = HasOtherMark(Result.Note, Call.Name)
	end
	if next(Call.Out) == nil then
		AfterTents(State, Call, Clock, Commands)
	end
end

local function NextAttempt(State: State, Call: Call, Clock: number, Commands: { Command })
	Call.Attempt += 1
	Call.Mine = {}
	Call.TentReports = {}
	NextSteps.SendTentsAgain(State, Call, Clock, Commands)
end

local function AfterFencedCommit(
	State: State,
	Call: Call,
	Fenced: { read Attempt: number, read IsFinal: boolean },
	Clock: number,
	Commands: { Command }
)
	if Fenced.IsFinal then
		Call.DeciderFate = { Kind = "Fenced" :: "Fenced", Attempt = Fenced.Attempt, IsFinal = true }
		return AbortCall(State, Call, Reasons.Spent, Clock, Commands)
	end
	if Call.Attempt < Requests.LimitsOf(State.Server, Call).MaxAttempts then
		return NextAttempt(State, Call, Clock, Commands)
	end
	NextSteps.FenceFinal(State, Call, Clock, Commands)
end

local function AfterCommit(State: State, Call: Call, Result: Outcome, Clock: number, Commands: { Command })
	local Report = Requests.LearnFromAnswer(State, Call, Call.Decider, Result, Commands)
	if Result.Kind == "Err" or Report == nil then
		Call.CommitMayHaveWritten = true
		if Requests.IsResendDue(State.Server, Call, Call.Decider) then
			return NextSteps.SendCommit(State, Call, Clock, Commands)
		end
		return AfterErrors(State, Call, { Call.Decider }, Clock, Commands)
	end
	if Result.Note.Closure.Wrote then
		Call.CommitMayHaveWritten = true
	end
	if Report.Kind == "Committed" then
		return CommitCall(State, Call, Report.Attempt, Report.DeciderValue, Clock, Commands)
	end
	if Report.Kind == "Fenced" then
		return AfterFencedCommit(State, Call, Report, Clock, Commands)
	end
	if Report.Kind == "Large" then
		return NextSteps.FenceFinal(State, Call, Clock, Commands)
	end
	if Report.Kind == "Other" then
		return AbortCall(State, Call, Reasons.Spent, Clock, Commands)
	end
	if Report.Kind == "Refused" then
		return AbortRefused(State, Call, Report, Clock, Commands)
	end
	if Report.Kind == "Invalid" and not Call.CommitMayHaveWritten then
		return EndNo(State, Call, Reasons.Invalid, Commands)
	end
	if Requests.RetagOnMissing(Call, Call.Decider, Report) then
		return NextSteps.SendCommit(State, Call, Clock, Commands)
	end
	if Report.Kind == "Forgotten" or Report.Kind == "Missing" then
		return NextSteps.FenceFinal(State, Call, Clock, Commands)
	end
	if Report.Kind == "Behind" then
		return GiveUpBehind(State, Call, Clock, Commands)
	end
	if Report.Kind == "Gated" then
		return NextSteps.WaitOutGate(State, Call, Report.Gate, Clock, Commands)
	end
	if Report.Kind == "Owed" then
		return NextSteps.AfterOwed(State, Call, Report.Marks, Clock, Commands)
	end
	local Working = TentReports.EndWorkOf(Report)
	if Working ~= nil then
		return NextSteps.HelpWith(State, Call, { { Key = Call.Decider, Report = Working } }, Clock, Commands)
	end
	if TentReports.IsSentAgainReport(Report) then
		return NextSteps.SendAgainLater(State, Call, Clock)
	end
	EndNo(State, Call, Reasons.Unresolved, Commands)
end

local function AfterFenceMissing(State: State, Call: Call, Clock: number, Commands: { Command })
	if Call.Rounds >= Requests.LimitsOf(State.Server, Call).RetryRounds then
		return EndNo(State, Call, Reasons.Unresolved, Commands)
	end
	Call.Rounds += 1
	NextSteps.FenceFinal(State, Call, Clock, Commands)
end

local function AfterFinalFence(State: State, Call: Call, Result: Outcome, Clock: number, Commands: { Command })
	local Report = Requests.LearnFromAnswer(State, Call, Call.Decider, Result, Commands)
	if Report == nil then
		if Requests.IsResendDue(State.Server, Call, Call.Decider) then
			return NextSteps.FenceFinal(State, Call, Clock, Commands)
		end
		return EndNo(State, Call, Reasons.Unresolved, Commands)
	end
	if Report.Kind == "Committed" then
		return CommitCall(State, Call, Report.Attempt, Report.DeciderValue, Clock, Commands)
	end
	if Report.Kind == "Fenced" and Call.GivesUp == "Behind" then
		return AbortWith(State, Call, BehindAnswer(Call), Clock, Commands)
	end
	if Report.Kind == "Fenced" and Call.GivesUp == "Unreadable" then
		return AbortCall(State, Call, Reasons.Unreadable, Clock, Commands)
	end
	if Report.Kind == "Fenced" then
		return AbortCall(State, Call, Reasons.Spent, Clock, Commands)
	end
	if Report.Kind == "Refused" then
		return AbortRefused(State, Call, Report, Clock, Commands)
	end
	if Report.Kind == "Forgotten" then
		return AbortCall(State, Call, Reasons.Unresolved, Clock, Commands)
	end
	if Report.Kind == "Missing" then
		return AfterFenceMissing(State, Call, Clock, Commands)
	end
	EndNo(State, Call, Reasons.Unresolved, Commands)
end

local function SameTerms(Fingerprint: number?, Name: OpName): TookBy
	if Fingerprint == Entries.FingerprintOf(Name) then
		return TookBy.Own
	end
	return TookBy.OtherTerms
end

local function DecisionTookBy(DeciderBook: Book, Name: OpName): TookBy
	local Pinned = Marks.PinnedOf(DeciderBook, Name)
	if Pinned ~= nil then
		return SameTerms(Pinned.Opening.Fingerprint, Name)
	end
	local Entry = Lookup.FindTimedEntry(DeciderBook, Name)
	if Entry ~= nil and (Entry.Fate.Kind == "Took" or Entry.Fate.Kind == "TookWith") then
		return SameTerms(Entry.Fingerprint, Name)
	end
	return TookBy.Nobody
end

local function AfterRetryRead(State: State, Call: Call, Fetched: ReadOutcome, Clock: number, Commands: { Command })
	Call.Out[Names.KeyText(Call.Decider)] = nil
	local Server = State.Server
	local Took = TookBy.Nobody
	if Fetched.Kind ~= "Failed" then
		local Read =
			Numbers.LearnStored(Server, Call.Decider, Cache.StoreOf(Server, Call.Decider).Setup, Fetched, Clock)
		if Read.Kind == "Kept" then
			Took = DecisionTookBy(Read.Kept.Book, Call.Name)
		end
	end
	if Took == TookBy.Own then
		AnswerTrue(Call, Commands)
		return TxCalls.End(State, Call, Commands)
	end
	if Took == TookBy.OtherTerms then
		return EndNo(State, Call, Reasons.Spent, Commands)
	end
	Call.Phase = "Tents"
	TxCalls.SendFirstTents(State, Call, Clock, Commands)
end

local function TimeOut(Call: Call, Commands: { Command })
	AnswerNo(Call, Reasons.Unresolved, Commands)
end

return {
	HearTent = HearTent,
	AfterCommit = AfterCommit,
	AfterFinalFence = AfterFinalFence,
	AfterRetryRead = AfterRetryRead,
	TimeOut = TimeOut,
}
