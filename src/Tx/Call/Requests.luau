--!strict
--!optimize 2

--[=[
	Requests: a Tx call's requests, each with no writer (TX-NONE), their names, and what answers teach the call
	(transaction sheets 4, 9 to 11, 15.1). An Unreadable report is an error, leaving the call clean unless caused by
	Amounts; a stored Balance is never sent again. Only an Err may clear by sending again. A newer Ledger's key reports
	Behind.

	Return type: A plain table of functions.
	Example usage:
		local Request = Requests.TentRequest(Server, Call, Key, Clock)
--]=]

local Balances = require("../Legs/Balances")
local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Decide = require("../../Judging/Decide")
local Ends = require("../Legs/Ends")
local Events = require("../../Events")
local Incarnations = require("../../Writing/Incarnations")
local JudgingShapes = require("../../Judging/Shapes")
local KindSetup = require("../../Judging/KindSetup")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Rides = require("../Rides")
local Sending = require("../../Writing/Sending")
local Shapes = require("../../Shapes")
local TxShapes = require("../Shapes")
local TxState = require("../State")
local Unreadable = require("../../Reading/Unreadable")

type Command = Events.Command
type Outcome = Events.Outcome
type TxLeg = TxShapes.TxLeg
type KeyReference = Names.KeyReference
type StoreKey = Names.StoreKey
type CommitForm = TxShapes.CommitForm
type LegForm = TxShapes.LegForm
type ResolveEnd = TxShapes.ResolveEnd
type TentForm = TxShapes.TentForm
type TxOutcome = TxShapes.TxOutcome
type Incarnation = Shapes.Incarnation
type Limits = Shapes.Limits
type Note = JudgingShapes.Note
type Report = JudgingShapes.Report
type UnreadableCause = JudgingShapes.UnreadableCause
type ServerState = Shapes.ServerState
type Setup = Shapes.Setup
type SentOp = Shapes.SentOp
type UpdateRequest = Shapes.UpdateRequest
type State = Composed.State
type Call = TxState.Call
type Purpose = TxState.Purpose

local RoutingFault = "Requests: this call is never made."
local NotALegKey = `{RoutingFault} A request of a call goes to one of its leg keys.`

local BehindReport: Report = table.freeze({ Kind = "Behind" :: "Behind" })

local function ClassifyLeg(Leg: TxLeg, Setup: Setup): LegForm
	local Declaration = Setup.Build.BalanceOps[Leg.OpKind]
	if Declaration == nil then
		return { Kind = "Game", Slot = Leg.Slot }
	end
	return {
		Kind = "Delta",
		Field = Declaration.Field,
		IsDebit = Declaration.Direction == Balances.Direction.Debit,
		Amount = Decide.BalanceAmountOf(Leg.Terms),
	}
end

local function Issue(State: State, Call: Call, Request: UpdateRequest, Purpose: Purpose, Commands: { Command }): number
	local RequestId = TxState.NewRequest(State.Server, State.Tx, Purpose)
	Call.Out[Names.KeyText(Purpose.Key)] = RequestId
	local Update: Command = { Kind = "Update", RequestId = RequestId, Target = Purpose.Key, Request = Request }
	table.insert(Commands, Update)
	return RequestId
end

local function TagFor(Server: ServerState, Call: Call, Key: StoreKey): Incarnation
	local Text = Names.KeyText(Key)
	local Held = Call.Tags[Text]
	if Held ~= nil then
		return Held
	end
	local Tag = Incarnations.IncarnationOf(Server, Cache.StoreOf(Server, Key).Setup, Key)
	Call.Tags[Text] = Tag
	return Tag
end

local function LegAt(Call: Call, Key: StoreKey): TxLeg
	local Text = Names.KeyText(Key)
	for _, Leg in Call.Legs do
		if Names.KeyText(Leg.Key) == Text then
			return Leg
		end
	end
	error(NotALegKey)
end

local function MustExistOf(Leg: TxLeg, Setup: Setup): boolean
	if Leg.MustExist ~= nil then
		return Leg.MustExist
	end
	return not Setup.CreatesOnFirstWrite
end

local function LegRequest(
	Server: ServerState,
	Call: Call,
	Leg: TxLeg,
	Form: TentForm | CommitForm,
	IsClean: boolean,
	Clock: number
): UpdateRequest
	local Op: SentOp = {
		Form = Form,
		OpKind = Leg.OpKind,
		Terms = Leg.Terms,
		Stamp = Call.Stamp,
		Incarnation = TagFor(Server, Call, Leg.Key),
		IsClean = IsClean,
	}
	return {
		Kind = "Update",
		WriterId = nil,
		Acknowledged = 0,
		MustExist = MustExistOf(Leg, KindSetup.SetupOfKey(Server, Leg.Key)),
		Ops = { Op },
		Ends = Rides.TakeFor(Server, Leg.Key, Clock, { Kind = "Call", CallId = Call.CallId }),
	}
end

local function TentRequest(Server: ServerState, Call: Call, Key: StoreKey, Clock: number): UpdateRequest
	local Leg = LegAt(Call, Key)
	local Form: TentForm = {
		Kind = "Tent",
		Name = Call.Name,
		Attempt = Call.Attempt,
		Leg = ClassifyLeg(Leg, KindSetup.SetupOfKey(Server, Key)),
		Decider = Names.ReferenceTo(Key, Call.Decider),
	}
	return LegRequest(Server, Call, Leg, Form, not Call.MayHoldMark[Names.KeyText(Key)], Clock)
end

local function SendTent(State: State, Call: Call, Key: StoreKey, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Request = TentRequest(State.Server, Call, Key, Clock)
	local Purpose: Purpose = { Kind = "Tent", CallId = Call.CallId, Key = Key, Carried = Request.Ends }
	Issue(State, Call, Request, Purpose, Commands)
end

local function CommitRequest(Server: ServerState, Call: Call, Clock: number): UpdateRequest
	local OtherLegs: { KeyReference } = {}
	for _, Key in Call.OtherKeys do
		table.insert(OtherLegs, Names.ReferenceTo(Call.Decider, Key))
	end
	local Leg = Call.Legs[Call.DeciderIndex]
	local Form: CommitForm = {
		Kind = "Commit",
		Name = Call.Name,
		Attempt = Call.Attempt,
		Leg = ClassifyLeg(Leg, KindSetup.SetupOfKey(Server, Call.Decider)),
		OtherLegs = OtherLegs,
	}
	return LegRequest(Server, Call, Leg, Form, not Call.CommitMayHaveWritten, Clock)
end

local function FenceRequest(Call: Call, IsFinal: boolean): UpdateRequest
	local Fence: TxShapes.FenceEnd = {
		Kind = "Fence",
		Name = Call.Name,
		Stamp = Call.Stamp,
		Attempt = Call.Attempt,
		IsFinal = IsFinal,
	}
	return Ends.EndsRequest({ Fence })
end

local function ResolveEnd(
	Call: Call,
	Key: StoreKey,
	Outcome: TxOutcome,
	Attempt: number,
	DeciderValue: number?
): ResolveEnd
	return {
		Kind = "Resolve",
		Name = Call.Name,
		Stamp = Call.Stamp,
		Attempt = Attempt,
		Outcome = Outcome,
		Decider = Names.ReferenceTo(Key, Call.Decider),
		DeciderValue = DeciderValue,
	}
end

local function LimitsOf(Server: ServerState, Call: Call): Limits
	return Cache.StoreOf(Server, Call.Decider).Setup.Limits
end

local function OwnReportOf(Note: Note): Report
	local OfOp = Note.Reports[1]
	if OfOp ~= nil then
		return OfOp
	end
	return Note.EndReports[1]
end

local function CountError(Call: Call, Text: string)
	Call.Erred = true
	Call.Errors[Text] = (Call.Errors[Text] or 0) + 1
end

local function MarkErred(Call: Call, Text: string)
	Call.IsUnclean = true
	CountError(Call, Text)
end

local function CountUnreadable(Call: Call, Text: string, Cause: UnreadableCause)
	if Cause == "Amounts" then
		MarkErred(Call, Text)
		Call.LastFailures[Text] = "Amounts"
		return
	end
	CountError(Call, Text)
	if Cause == "Balance" then
		Call.LastFailures[Text] = "Balance"
		return
	end
	Call.LastFailures[Text] = "Unreadable"
end

local function LearnFromAnswer(State: State, Call: Call, Key: StoreKey, Result: Outcome, Commands: { Command }): Report?
	local Text = Names.KeyText(Key)
	Call.Out[Text] = nil
	if Result.Kind == "Err" then
		MarkErred(Call, Text)
		Call.LastFailures[Text] = "Err"
		return nil
	end
	local Note = Result.Note
	if Note.Closure.Wrote then
		Call.IsUnclean = true
	end
	local Server = State.Server
	local Own = OwnReportOf(Note)
	if Own.Kind == "Unreadable" then
		Unreadable.WarnOfReport(Server, Key, Own, Commands)
		if Own.Cause ~= "Newer" then
			CountUnreadable(Call, Text, Own.Cause)
			return nil
		end
		Own = BehindReport
	end
	Numbers.LearnFromNote(Server, Numbers.EntryFor(Server, Key), Key, Cache.StoreOf(Server, Key).Setup, Note)
	Sending.WarnFromNote(Key, Note, Commands)
	Call.Errors[Text] = nil
	Call.LastFailures[Text] = nil
	return Own
end

local function HasPlatformError(Call: Call, Keys: { StoreKey }): boolean
	for _, Key in Keys do
		if Call.LastFailures[Names.KeyText(Key)] == "Err" then
			return true
		end
	end
	return false
end

local function IsEachUnreadable(Call: Call, Keys: { StoreKey }): boolean
	local HasUnreadable = false
	for _, Key in Keys do
		local Failure = Call.LastFailures[Names.KeyText(Key)]
		if Failure == "Unreadable" or Failure == "Balance" then
			HasUnreadable = true
		elseif Failure ~= nil then
			return false
		end
	end
	return HasUnreadable
end

local function IsResendDue(Server: ServerState, Call: Call, Key: StoreKey): boolean
	local Text = Names.KeyText(Key)
	if Call.LastFailures[Text] == "Balance" then
		return false
	end
	return Call.Errors[Text] <= LimitsOf(Server, Call).RetryRounds
end

return {
	ClassifyLeg = ClassifyLeg,
	Issue = Issue,
	TagFor = TagFor,
	TentRequest = TentRequest,
	SendTent = SendTent,
	CommitRequest = CommitRequest,
	FenceRequest = FenceRequest,
	ResolveEnd = ResolveEnd,
	LimitsOf = LimitsOf,
	MarkErred = MarkErred,
	LearnFromAnswer = LearnFromAnswer,
	IsResendDue = IsResendDue,
	HasPlatformError = HasPlatformError,
	IsEachUnreadable = IsEachUnreadable,
}
