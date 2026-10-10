--!strict
--!optimize 2

--[=[
	Reports: how a cut call hears each report (cuts sheets 8.2, 9). A call that may have written answers Unresolved, not
	a no; one resent under its handed-back name has not, and never redraws. A seal naming this server its sealer is
	removed or watched however heard, and a seal a write landed is new, so an earlier removal of its name and rt does
	not cover it. Answered calls drop after ErrorsBeforeUnresolved rounds without progress; the touch heals the key. A
	Reset that took answers the loss records its write left on the key, as an Erase answers its seal's.

	Return type: A plain table with HearCut, AfterStamp and TimeOut.
	Example usage:
		Reports.HearCut(State, Cutting, Result, Clock, Commands)
--]=]

local Book = require("../../Stored/Book")
local Cache = require("../../Reading/Cache")
local Call = require("./Call")
local Composed = require("../../Composed")
local CutState = require("../State")
local Drain = require("./Drain")
local Events = require("../../Events")
local Help = require("../../Tx/Work/Help")
local JudgingShapes = require("../../Judging/Shapes")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Reasons = require("../../Constants/Reasons")
local Removal = require("../Seals/Removal")
local SealItems = require("../../Stored/Items/Seal")
local Sending = require("../../Writing/Sending")
local Stamps = require("../Seals/Stamps")
local TxState = require("../../Tx/State")
local Losses = require("../../Stored/Items/Losses")
local Value = require("../../Stored/Value")
local Work = require("../../Stored/Items/Work")

type Command = Events.Command
type Outcome = Events.Outcome
type Identity = Book.Identity
type Reason = Reasons.Reason
type EndWorkReport = JudgingShapes.EndWorkReport
type Note = JudgingShapes.Note
type Report = JudgingShapes.Report
type Gate = SealItems.Gate
type Seal = SealItems.Seal
type Mark = Work.Mark
type LossRecords = Losses.LossRecords
type Value = Value.Value
type State = Composed.State
type CutCall = CutState.CutCall
type Waiter = TxState.Waiter

type SealedReport = { read Seal: Seal }
type MissingReport = { read Identity: Identity?, read Seal: Seal?, read IsLeftOver: boolean }
type MarksReport = { read Marks: { Mark } }
type GatedByReport = { read Gate: Gate }
type WaitReport = { read At: number }
type Handler = (State, CutCall, Report, number, { Command }) -> ()

local RoutingFault = "Reports: this report is never heard."
local UnheardReport = `{RoutingFault} A cut call is never given the report %s. The core routed it wrongly.`

local UnnamedBalanceWarning = "the balance field %s holds a value its arithmetic rejects, so a cut on this key "
	.. "cannot land until the field is repaired. The call answers Unresolved."

local MinimumWait = 1
local CarriedStops = { Marks = true, Behind = true, Wait = true, Undecided = true, Missing = true }
local HelperGone: Report = table.freeze({ Kind = "Gone" :: "Gone" })

local function IsWrittenBy(Result: Outcome): boolean
	if Result.Kind == "Err" then
		return false
	end
	return Result.Kind == "Ok" or Result.Note.Closure.Wrote
end

local function WarnUnnamedBalance(Cutting: CutCall, Note: Note, Commands: { Command })
	if Cutting.HasWarnedUnnamed then
		return
	end
	for _, Warning in Note.Warnings do
		if Warning.Kind == "UnnamedBalance" then
			Cutting.HasWarnedUnnamed = true
			local Text = string.format(UnnamedBalanceWarning, Warning.Field)
			local Warn: Command = { Kind = "Warn", Key = Cutting.Key, Text = Text }
			table.insert(Commands, Warn)
			return
		end
	end
end

local function HasMetLegacyRecord(Note: Note): boolean
	for _, Warning in Note.Warnings do
		if Warning.Kind == "WrittenBeforeErasable" then
			return true
		end
	end
	return false
end

local function WarnIfMetLegacyRecord(State: State, Cutting: CutCall, Note: Note, Commands: { Command })
	if HasMetLegacyRecord(Note) then
		Call.WarnWrittenBeforeErasable(State, Cutting, Commands)
	end
end

local function LearnFromAnswer(State: State, Cutting: CutCall, Result: Outcome, Commands: { Command })
	if Result.Kind == "Err" or IsWrittenBy(Result) then
		Cutting.MayHaveWritten = true
		Call.KeepJudged(State, Cutting)
	end
	if Result.Kind == "Err" then
		return
	end
	local Server = State.Server
	local Key = Cutting.Key
	Numbers.LearnFromNote(Server, Numbers.EntryFor(Server, Key), Key, Cache.StoreOf(Server, Key).Setup, Result.Note)
	local Landed = Result.Note.WrittenValue
	if Result.Kind == "Ok" and Landed ~= nil and Landed.Kind == "Sealed" then
		Removal.ForgetSent(State, Key, Landed.Seal.Name, Landed.Seal.RemovalStamp)
	end
	Sending.WarnFromNote(Key, Result.Note, Commands)
	WarnUnnamedBalance(Cutting, Result.Note, Commands)
	WarnIfMetLegacyRecord(State, Cutting, Result.Note, Commands)
	if Cutting.Role == "Helper" then
		Server.WorkSeen[Names.KeyText(Key)] = nil
	end
end

local function HeardReport(Cutting: CutCall, Note: Note): Report
	local Reports = Note.Reports
	local Own = Reports[#Reports]
	if #Reports == 1 then
		return Own
	end
	local Carried = Reports[1]
	if CarriedStops[Carried.Kind] then
		return Carried
	end
	Cutting.CarriedGate = nil
	if Carried.Kind ~= "Took" and Carried.Kind ~= "Sealed" and Own.Kind == "Undecided" then
		return HelperGone
	end
	return Own
end

local function CleanOr(Cutting: CutCall, Reason: Reason): Reason
	if Cutting.MayHaveWritten then
		return Reasons.Unresolved
	end
	return Reason
end

local function EndTrue(State: State, Cutting: CutCall, Commands: { Command })
	Call.KeepJudged(State, Cutting)
	Call.AnswerTrue(Cutting, Commands)
	CutState.EndCall(State.Cuts, Cutting)
end

local function EndNo(State: State, Cutting: CutCall, Reason: Reason, Commands: { Command })
	Call.AnswerNo(Cutting, Reason, Commands)
	CutState.EndCall(State.Cuts, Cutting)
end

local function WaitFor(Cutting: CutCall, At: number, Clock: number)
	Cutting.Phase = "Waiting"
	Cutting.WaitUntil = math.max(At, Clock + MinimumWait)
end

local function OnTook(State: State, Cutting: CutCall, _Report: Report, _Clock: number, Commands: { Command })
	EndTrue(State, Cutting, Commands)
end

local function OnResetTook(State: State, Cutting: CutCall, Written: Value?, Commands: { Command })
	if Written == nil or Written.Kind ~= "Kept" then
		return EndTrue(State, Cutting, Commands)
	end
	local Kept = Written.Book
	local Records: LossRecords = { Events = Kept.Losses.Events, Returns = Kept.Losses.Returns, Slots = Kept.Slots }
	Call.KeepJudged(State, Cutting)
	Call.AnswerNamed(Cutting, Records, Commands)
	CutState.EndCall(State.Cuts, Cutting)
end

local function OnSealed(State: State, Cutting: CutCall, Report: SealedReport, Clock: number, Commands: { Command })
	Call.KeepJudged(State, Cutting)
	Call.AnswerNamed(Cutting, Report.Seal.Records, Commands)
	Stamps.AfterSeal(State, Cutting, Report.Seal, Clock, Commands)
	CutState.EndCall(State.Cuts, Cutting)
end

local function OnSpent(State: State, Cutting: CutCall, _Report: Report, _Clock: number, Commands: { Command })
	EndNo(State, Cutting, Reasons.Spent, Commands)
end

local function MayRedraw(Cutting: CutCall): boolean
	if Cutting.Name.Kind ~= "Drawn" or Cutting.IsHandleResend then
		return false
	end
	return not Cutting.HasRedrawn and not Cutting.HasAnswered
end

local function OnForgotten(State: State, Cutting: CutCall, _Report: Report, Clock: number, Commands: { Command })
	if Cutting.MayHaveWritten then
		return EndNo(State, Cutting, Reasons.Unresolved, Commands)
	end
	if MayRedraw(Cutting) then
		return Call.Redraw(State, Cutting, Clock, Commands)
	end
	EndNo(State, Cutting, Reasons.Expired, Commands)
end

local function OnBehind(State: State, Cutting: CutCall, _Report: Report, _Clock: number, Commands: { Command })
	EndNo(State, Cutting, CleanOr(Cutting, Reasons.Behind), Commands)
end

local function OnFull(State: State, Cutting: CutCall, _Report: Report, _Clock: number, Commands: { Command })
	EndNo(State, Cutting, CleanOr(Cutting, Reasons.Full), Commands)
end

local function OnWorn(State: State, Cutting: CutCall, _Report: Report, _Clock: number, Commands: { Command })
	EndNo(State, Cutting, Reasons.Unresolved, Commands)
end

local function OnMarks(State: State, Cutting: CutCall, Report: MarksReport, Clock: number, Commands: { Command })
	Drain.Start(State, Cutting, Report.Marks, Clock, Commands)
end

local function AnswerMissingOrEnd(State: State, Cutting: CutCall, Identity: Identity?, Commands: { Command })
	if Cutting.CutKind == "Erase" and (Cutting.MayHaveWritten or Cutting.IsHandleResend) then
		return EndTrue(State, Cutting, Commands)
	end
	if not Cutting.MayHaveWritten then
		Call.AnswerMissing(Cutting, Identity, Commands)
		return CutState.EndCall(State.Cuts, Cutting)
	end
	EndNo(State, Cutting, Reasons.Unresolved, Commands)
end

local function OnMissing(State: State, Cutting: CutCall, Report: MissingReport, Clock: number, Commands: { Command })
	local Sealed = Report.Seal
	if Report.IsLeftOver and Sealed ~= nil then
		local IsSent = Stamps.StampFor(State, Cutting.Key, Sealed.RemovalStamp, Cutting.CallId, Clock, Commands)
		if IsSent then
			Cutting.Phase = "Stamping"
			return
		end
	end
	AnswerMissingOrEnd(State, Cutting, Report.Identity, Commands)
end

local function AfterStamp(State: State, Cutting: CutCall, Commands: { Command })
	AnswerMissingOrEnd(State, Cutting, nil, Commands)
end

local function OnGatedBy(State: State, Cutting: CutCall, Report: GatedByReport, Clock: number, Commands: { Command })
	Cutting.CarriedGate = Report.Gate
	Call.SendCut(State, Cutting, Clock, Commands)
end

local function OnGone(State: State, Cutting: CutCall, _Report: Report, Clock: number, Commands: { Command })
	Cutting.CarriedGate = nil
	Call.SendCut(State, Cutting, Clock, Commands)
end

local function OnAhead(_State: State, Cutting: CutCall, _Report: Report, Clock: number, _Commands: { Command })
	WaitFor(Cutting, Cutting.Stamp, Clock)
end

local function OnWait(_State: State, Cutting: CutCall, Report: WaitReport, Clock: number, _Commands: { Command })
	WaitFor(Cutting, Report.At, Clock)
end

local function OnOverdue(State: State, Cutting: CutCall, Report: EndWorkReport, Clock: number, Commands: { Command })
	Cutting.Phase = "Waiting"
	local For: Waiter = { Kind = "Cut", CallId = Cutting.CallId }
	local HelpId = Help.StartHelp(State, For, Cutting.Key, Report, Clock, Commands)
	if State.Tx.Helps[HelpId] == nil then
		Call.SendCut(State, Cutting, Clock, Commands)
	end
end

local Handlers = {
	Took = OnTook,
	Sealed = OnSealed,
	Spent = OnSpent,
	Forgotten = OnForgotten,
	Behind = OnBehind,
	Full = OnFull,
	Worn = OnWorn,
	Marks = OnMarks,
	Missing = OnMissing,
	GatedBy = OnGatedBy,
	Gone = OnGone,
	Ahead = OnAhead,
	Undecided = OnAhead,
	Wait = OnWait,
	Overdue = OnOverdue,
}

local function HearHelper(State: State, Cutting: CutCall, Report: Report, Clock: number, Commands: { Command })
	if Report.Kind == "Marks" then
		return Drain.Start(State, Cutting, Report.Marks, Clock, Commands)
	end
	if Report.Kind == "Wait" then
		return OnWait(State, Cutting, Report, Clock, Commands)
	end
	if Report.Kind == "Ahead" or Report.Kind == "Undecided" then
		return OnAhead(State, Cutting, Report, Clock, Commands)
	end
	if Report.Kind == "Overdue" then
		return OnOverdue(State, Cutting, Report, Clock, Commands)
	end
	if Report.Kind == "Sealed" then
		Stamps.WatchHelperSeal(State, Cutting.Key, Report.Seal)
	end
	CutState.EndCall(State.Cuts, Cutting)
end

local function OnError(State: State, Cutting: CutCall, Clock: number, Commands: { Command })
	Cutting.ErrorsInARow += 1
	local Limits = Cache.StoreOf(State.Server, Cutting.Key).Setup.Limits
	if Cutting.ErrorsInARow >= Limits.ErrorsBeforeUnresolved then
		if Cutting.Role == "Helper" then
			return CutState.EndCall(State.Cuts, Cutting)
		end
		Call.AnswerNo(Cutting, Reasons.Unresolved, Commands)
	end
	Cutting.Phase = "Waiting"
	Cutting.RetryAt = Clock + Sending.RetryGap(Cutting.ErrorsInARow, Limits)
end

local function IsWithoutProgress(State: State, Cutting: CutCall, Report: Report): boolean
	if Report.Kind == "Unreadable" then
		return true
	end
	return Report.Kind == "Marks" and Drain.IsRoundWithoutProgress(State, Cutting)
end

local function DropIfStuck(State: State, Cutting: CutCall, Report: Report): boolean
	if not IsWithoutProgress(State, Cutting, Report) then
		Cutting.RoundsWithoutProgress = 0
		return false
	end
	if not Cutting.HasAnswered then
		return false
	end
	Cutting.RoundsWithoutProgress += 1
	local Limits = Cache.StoreOf(State.Server, Cutting.Key).Setup.Limits
	if Cutting.RoundsWithoutProgress < Limits.ErrorsBeforeUnresolved then
		return false
	end
	CutState.EndCall(State.Cuts, Cutting)
	return true
end

local function HearCut(State: State, Cutting: CutCall, Result: Outcome, Clock: number, Commands: { Command })
	Cutting.Out = nil
	LearnFromAnswer(State, Cutting, Result, Commands)
	if Result.Kind == "Err" then
		return OnError(State, Cutting, Clock, Commands)
	end
	local Carried = Result.Note.Reports[1]
	if Cutting.CarriedGate ~= nil and Carried.Kind == "Sealed" then
		Stamps.WatchHelperSeal(State, Cutting.Key, Carried.Seal)
	end
	local Report = HeardReport(Cutting, Result.Note)
	if DropIfStuck(State, Cutting, Report) then
		return
	end
	if Report.Kind == "Unreadable" then
		if Report.Cause == "Amounts" or Cutting.Role == "Helper" then
			return OnError(State, Cutting, Clock, Commands)
		end
		return Call.EndUnreadable(State, Cutting, Report.Cause, Commands)
	end
	Cutting.ErrorsInARow = 0
	if Cutting.Role == "Helper" then
		return HearHelper(State, Cutting, Report, Clock, Commands)
	end
	if Report.Kind == "Took" and Cutting.CutKind == "Reset" then
		return OnResetTook(State, Cutting, Result.Note.WrittenValue, Commands)
	end
	local Handle = (Handlers :: { [string]: Handler })[Report.Kind]
	if Handle == nil then
		error(string.format(UnheardReport, Report.Kind))
	end
	Handle(State, Cutting, Report, Clock, Commands)
end

local function TimeOut(Cutting: CutCall, Commands: { Command })
	Call.AnswerNo(Cutting, Reasons.Unresolved, Commands)
end

return {
	HearCut = HearCut,
	AfterStamp = AfterStamp,
	TimeOut = TimeOut,
}
