--!strict
--!optimize 2

--[=[
	Answers: what a report means for its op (record sheet 10).

	Spent, a fated report, a hopeful Cut or Behind answer clean or not; other definite noes need a clean
	op, else Unresolved or Unknown. A clean "absent" op meeting a value retries tagged for it, legacy too. A durable
	part refusal answers Refused; an impossible report throws.

	Return type: A plain table of functions, and the DurableMove, HopefulMove,
	ProbeMove, EndWork, Emitted, FateEmission, TurnReason and NameKind types.
	Example usage:
		Answers.DurableAnswer({ Kind = "Spent" }, true, "Timed", { Kind = "Any" })
--]=]

local Book = require("../Stored/Book")
local Events = require("../Events")
local Fates = require("../Stored/Items/Fates")
local JudgingShapes = require("../Judging/Shapes")
local Reasons = require("../Constants/Reasons")
local Shapes = require("../Shapes")
local Unreadable = require("../Reading/Unreadable")

type Identity = Book.Identity
type Answer = Events.Answer
type Reason = Reasons.Reason
type Fate = Fates.Fate
type EndWorkReport = JudgingShapes.EndWorkReport
type Report = JudgingShapes.Report
type Incarnation = Shapes.Incarnation
type UnreadableCause = JudgingShapes.UnreadableCause
type FatedReport = { read Fate: Fate, read State: unknown }
type UnreadableReport = { read Cause: UnreadableCause }
type MissingReport = { read Identity: Identity?, read Seal: unknown, read IsLegacy: boolean }
type DurableHandler = (Report, boolean, NameKind, Incarnation) -> DurableMove
type HopefulHandler = (Report, boolean, Incarnation) -> HopefulMove
type ProbeHandler = (Report, boolean) -> ProbeMove

local TurnReason = {
	Refused = "Refused" :: "Refused",
	Full = "Full" :: "Full",
	Cut = "Cut" :: "Cut",
	Behind = "Behind" :: "Behind",
	Unreadable = "Unreadable" :: "Unreadable",
}

export type TurnReason = keyof<typeof(TurnReason)>

export type NameKind = "Minted" | "Timed" | "Untimed"

export type Emitted =
	{ read Kind: "Took" }
	| { read Kind: "Turned", read Why: TurnReason, read State: unknown }
	| { read Kind: "Unknown" }

export type FateEmission = { read CallId: number, read Fate: Emitted, read OpKind: string, read Terms: unknown }

type Answered = { read Kind: "Answer", read Answer: Answer }
type Emit = { read Kind: "Emit", read Fate: Emitted }
type Restamp = { read Kind: "Restamp" }
type SendAgain = { read Kind: "SendAgain" }
type SendAgainWith = { read Kind: "SendAgainWith", read Identity: Identity? }
export type EndWork = { read Kind: "EndWork", read Report: EndWorkReport }

export type DurableMove = Answered | Restamp | SendAgain | SendAgainWith | EndWork
export type HopefulMove = Emit | Restamp | SendAgain | SendAgainWith | EndWork
export type ProbeMove = Answered | EndWork

local TookEmitted: Emitted = table.freeze({ Kind = "Took" :: "Took" })
local UnknownEmitted: Emitted = table.freeze({ Kind = "Unknown" :: "Unknown" })

local RestampMove: Restamp = table.freeze({ Kind = "Restamp" :: "Restamp" })
local SendAgainMove: SendAgain = table.freeze({ Kind = "SendAgain" :: "SendAgain" })
local TookMove: Emit = table.freeze({
	Kind = "Emit" :: "Emit",
	Fate = TookEmitted,
})
local UnknownMove: Emit = table.freeze({
	Kind = "Emit" :: "Emit",
	Fate = UnknownEmitted,
})

local RoutingFault = "Answers: this call is never given"
local ProbeWithoutReport = "a probe whose note has no probe report"
local ForgottenCleanUntimed = "a forgotten report for a clean untimed op"
local FatedReportFormat = "a fated report of %s"
local ReportFormat = "the report %s"

local function RejectReport(What: string): never
	error(`{RoutingFault} {What}. The core routed it wrongly.`)
end

local function Succeeded(Value: boolean): Answered
	return { Kind = "Answer", Answer = { Kind = "Succeeded", Value = Value } }
end

local function Failed(Reason: Reason, State: unknown, Identity: Identity?): Answered
	return {
		Kind = "Answer",
		Answer = {
			Kind = "Failed",
			Reason = Reason,
			State = State,
			Identity = Identity,
		},
	}
end

local function Unresolved(): Answered
	return Failed(Reasons.Unresolved, nil, nil)
end

local function CleanNo(Reason: Reason, IsClean: boolean): Answered
	if not IsClean then
		return Unresolved()
	end
	return Failed(Reason, nil, nil)
end

local function EndWorkOf(Report: EndWorkReport): EndWork
	return { Kind = "EndWork", Report = Report }
end

local function IsTook(Fate: Fate): boolean
	return Fate.Kind == "Took" or Fate.Kind == "TookWith"
end

local function AnswerStoredFate(Fate: Fate, State: unknown): Answered
	if IsTook(Fate) then
		return Succeeded(true)
	end
	if Fate.Kind == "Refused" then
		return Failed(Reasons.Refused, State, nil)
	end
	if Fate.Kind == "Full" then
		return Failed(Reasons.Full, State, nil)
	end
	if Fate.Kind == "RefusedFor" then
		return Failed(Reasons.Refused, nil, nil)
	end
	return Failed(Reasons.Spent, nil, nil)
end

local function MetAnotherIncarnation(Report: MissingReport): boolean
	return Report.Identity ~= nil or Report.IsLegacy
end

local function SendAgainWithOf(Report: MissingReport, Carried: Incarnation): SendAgainWith?
	if Carried.Kind ~= "Absent" or Report.Seal ~= nil or not MetAnotherIncarnation(Report) then
		return nil
	end
	return { Kind = "SendAgainWith", Identity = Report.Identity }
end

local function AnswerForgotten(IsClean: boolean, Kind: NameKind): DurableMove
	if not IsClean then
		return Unresolved()
	end
	if Kind == "Minted" then
		return RestampMove
	end
	if Kind == "Timed" then
		return Failed(Reasons.Expired, nil, nil)
	end
	return RejectReport(ForgottenCleanUntimed)
end

local function DurableFated(Report: FatedReport): DurableMove
	return AnswerStoredFate(Report.Fate, Report.State)
end

local function DurableSpent(): DurableMove
	return Failed(Reasons.Spent, nil, nil)
end

local function DurableForgotten(_Report: Report, IsClean: boolean, Kind: NameKind): DurableMove
	return AnswerForgotten(IsClean, Kind)
end

local function DurableAhead(_Report: Report, IsClean: boolean, Kind: NameKind): DurableMove
	if Kind == "Minted" and IsClean then
		return RestampMove
	end
	return SendAgainMove
end

local function DurableUndecided(): DurableMove
	return SendAgainMove
end

local function DurableUnreadable(Report: UnreadableReport, IsClean: boolean): DurableMove
	if Report.Cause == "Amounts" then
		return Unresolved()
	end
	return CleanNo(Unreadable.ReasonOf(Report.Cause), IsClean)
end

local function DurableEndWork(Report: EndWorkReport): DurableMove
	return EndWorkOf(Report)
end

local function DurableMissing(
	Report: MissingReport,
	IsClean: boolean,
	_Kind: NameKind,
	Carried: Incarnation
): DurableMove
	if not IsClean then
		return Unresolved()
	end
	local Again = SendAgainWithOf(Report, Carried)
	if Again ~= nil then
		return Again
	end
	return Failed(Reasons.Missing, nil, Report.Identity)
end

local function DurableNoRoom(Report: EndWorkReport, IsClean: boolean): DurableMove
	if #Report.Marks > 0 then
		return EndWorkOf(Report)
	end
	return CleanNo(Reasons.NoRoom, IsClean)
end

local function DurableBehind(_Report: Report, IsClean: boolean): DurableMove
	return CleanNo(Reasons.Behind, IsClean)
end

local function DurableInvalid(_Report: Report, IsClean: boolean): DurableMove
	return CleanNo(Reasons.Invalid, IsClean)
end

local function DurableWorn(_Report: Report, IsClean: boolean): DurableMove
	return CleanNo(Reasons.Full, IsClean)
end

local function DurableCut(): DurableMove
	return Unresolved()
end

local DurableAnswers = {
	Fated = DurableFated,
	Spent = DurableSpent,
	Forgotten = DurableForgotten,
	Ahead = DurableAhead,
	Undecided = DurableUndecided,
	Unreadable = DurableUnreadable,
	Overdue = DurableEndWork,
	Blocked = DurableEndWork,
	Marks = DurableSpent,
	Missing = DurableMissing,
	NoRoom = DurableNoRoom,
	Behind = DurableBehind,
	Invalid = DurableInvalid,
	Worn = DurableWorn,
	Cut = DurableCut,
}

local function DurableAnswer(Report: Report, IsClean: boolean, Kind: NameKind, Carried: Incarnation): DurableMove
	local Answer = (DurableAnswers :: { [string]: DurableHandler })[Report.Kind]
	if Answer == nil then
		return RejectReport(string.format(ReportFormat, Report.Kind))
	end
	return Answer(Report, IsClean, Kind, Carried)
end

local function TurnAway(Why: TurnReason, State: unknown): Emit
	return { Kind = "Emit", Fate = { Kind = "Turned", Why = Why, State = State } }
end

local function MoveForStoredFate(Fate: Fate, State: unknown): HopefulMove
	if IsTook(Fate) then
		return TookMove
	end
	if Fate.Kind == "Refused" then
		return TurnAway(TurnReason.Refused, State)
	end
	if Fate.Kind == "Full" then
		return TurnAway(TurnReason.Full, State)
	end
	return RejectReport(string.format(FatedReportFormat, Fate.Kind))
end

local function HopefulFated(Report: FatedReport): HopefulMove
	return MoveForStoredFate(Report.Fate, Report.State)
end

local function HopefulCut(): HopefulMove
	return TurnAway(TurnReason.Cut, nil)
end

local function HopefulBehind(): HopefulMove
	return TurnAway(TurnReason.Behind, nil)
end

local function HopefulForgotten(_Report: Report, IsClean: boolean): HopefulMove
	if not IsClean then
		return UnknownMove
	end
	return RestampMove
end

local function HopefulAhead(_Report: Report, IsClean: boolean): HopefulMove
	if not IsClean then
		return SendAgainMove
	end
	return RestampMove
end

local function HopefulUndecided(): HopefulMove
	return SendAgainMove
end

local function UnreadableFate(Cause: UnreadableCause): Emitted
	if Cause == "Newer" then
		return { Kind = "Turned", Why = TurnReason.Behind, State = nil }
	end
	return { Kind = "Turned", Why = TurnReason.Unreadable, State = nil }
end

local function HopefulUnreadable(Report: UnreadableReport, IsClean: boolean): HopefulMove
	if not IsClean then
		return UnknownMove
	end
	return { Kind = "Emit", Fate = UnreadableFate(Report.Cause) }
end

local function HopefulEndWork(Report: EndWorkReport): HopefulMove
	return EndWorkOf(Report)
end

local function HopefulMissing(Report: MissingReport, IsClean: boolean, Carried: Incarnation): HopefulMove
	if not IsClean then
		return UnknownMove
	end
	local Again = SendAgainWithOf(Report, Carried)
	if Again ~= nil then
		return Again
	end
	return TurnAway(TurnReason.Cut, nil)
end

local function HopefulWorn(_Report: Report, IsClean: boolean): HopefulMove
	if not IsClean then
		return UnknownMove
	end
	return TurnAway(TurnReason.Full, nil)
end

local HopefulAnswers = {
	Fated = HopefulFated,
	Cut = HopefulCut,
	Behind = HopefulBehind,
	Forgotten = HopefulForgotten,
	Ahead = HopefulAhead,
	Undecided = HopefulUndecided,
	Unreadable = HopefulUnreadable,
	Overdue = HopefulEndWork,
	Blocked = HopefulEndWork,
	Missing = HopefulMissing,
	Worn = HopefulWorn,
}

local function HopefulAnswer(Report: Report, IsClean: boolean, Carried: Incarnation): HopefulMove
	local Answer = (HopefulAnswers :: { [string]: HopefulHandler })[Report.Kind]
	if Answer == nil then
		return RejectReport(string.format(ReportFormat, Report.Kind))
	end
	return Answer(Report, IsClean, Carried)
end

local function ProbeFated(Report: FatedReport): ProbeMove
	return Succeeded(IsTook(Report.Fate))
end

local function ProbeLanded(): ProbeMove
	return Succeeded(false)
end

local function ProbeEndWork(Report: EndWorkReport): ProbeMove
	return EndWorkOf(Report)
end

local function ProbeUnresolved(): ProbeMove
	return Unresolved()
end

local function ProbeUnreadable(Report: UnreadableReport): ProbeMove
	if Report.Cause == "Amounts" then
		return Unresolved()
	end
	return Failed(Unreadable.ReasonOf(Report.Cause), nil, nil)
end

local function ProbeForgotten(_Report: Report, IsForgottenAnyKind: boolean): ProbeMove
	if not IsForgottenAnyKind then
		return Unresolved()
	end
	return Failed(Reasons.Expired, nil, nil)
end

local function ProbeMissing(): ProbeMove
	return Failed(Reasons.Missing, nil, nil)
end

local ProbeAnswers = {
	Fated = ProbeFated,
	Landed = ProbeLanded,
	Overdue = ProbeEndWork,
	Forgotten = ProbeForgotten,
	Missing = ProbeMissing,
	Worn = ProbeUnresolved,
	Unreadable = ProbeUnreadable,
	Marks = ProbeUnresolved,
}

local function DidApplyAnswer(ProbeReport: Report?, IsForgottenAnyKind: boolean): ProbeMove
	if ProbeReport == nil then
		return RejectReport(ProbeWithoutReport)
	end
	local Answer = (ProbeAnswers :: { [string]: ProbeHandler })[ProbeReport.Kind]
	if Answer == nil then
		return RejectReport(string.format(ReportFormat, ProbeReport.Kind))
	end
	return Answer(ProbeReport, IsForgottenAnyKind)
end

return {
	DurableAnswer = DurableAnswer,
	HopefulAnswer = HopefulAnswer,
	DidApplyAnswer = DidApplyAnswer,
	UnreadableFate = UnreadableFate,
	IsTook = IsTook,
}
