--!strict
--!optimize 2

--[=[
	Call: a cut call's name, fingerprint, incarnation read, requests and answer (cuts sheets 8.1, 1.3). Requests never
	create and have no writer; a helper's op and unseen keys' reads go first. A judged name keeps its incarnation until
	W[cut] past its stamp (record 3.1); from then this server's own drawn name answers Expired unsent, so a resend never
	cuts a later key. Legacy-tagged sends warn once per store; only Reports warns of a rejected balance.

	Return type: A plain table of functions.
	Example usage:
		Call.Begin(State, Event, Arrived, Clock, Commands)
--]=]

local Book = require("../../Stored/Book")
local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Cuts = require("../../Constants/Cuts")
local CutShapes = require("../Shapes")
local CutState = require("../State")
local DueTimes = require("../../DueTimes")
local Durable = require("../../Writing/Durable")
local Entries = require("../../Stored/Entries")
local Events = require("../../Events")
local HashInputs = require("../../Encoding/HashInputs")
local Incarnations = require("../../Writing/Incarnations")
local Json = require("../../Encoding/Json")
local Losses = require("../../Stored/Items/Losses")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Reasons = require("../../Constants/Reasons")
local Removal = require("../Seals/Removal")
local Replies = require("../../Replies")
local Rides = require("../../Tx/Rides")
local Seal = require("../../Stored/Items/Seal")
local Shapes = require("../../Shapes")
local Timed = require("../../Stored/Items/Timed")
local TxShapes = require("../../Tx/Shapes")
local Unreadable = require("../../Reading/Unreadable")
local Value = require("../../Stored/Value")

type Command = Events.Command
type GivenAnswer = Events.Answer
type ReadOutcome = Events.ReadOutcome
type OpName = Names.OpName
type Reason = Reasons.Reason
type Fields = Value.Fields
type LossRecords = Losses.LossRecords
type Identity = Book.Identity
type Gate = Seal.Gate
type CutKind = Timed.CutKind
type CutAnswer = CutShapes.CutAnswer
type CutForm = CutShapes.CutForm
type EraseCall = CutShapes.EraseCall
type ResetCall = CutShapes.ResetCall
type Incarnation = Shapes.Incarnation
type SentOp = Shapes.SentOp
type ServerState = Shapes.ServerState
type UpdateRequest = Shapes.UpdateRequest
type State = Composed.State
type CutCall = CutState.CutCall
type Purpose = CutState.Purpose
type Carrier = TxShapes.Carrier
type Cause = Unreadable.Cause

local CutOpKind = Cuts.CutOpKind

local RoutingFault = "Call: this call is never made."
local NoFirstSendTime =
	`{RoutingFault} A cut's game name carries its first send time, and Api/Validate throws without it.`
local NoGateFingerprint = `{RoutingFault} A gate held under a game name carries its fingerprint.`

local WrittenBeforeErasableWarning = "this key was written before the store %s was erasable. An erase is at most "
	.. "once only when no server of a build with Erasable = false still runs: let the update that made the store "
	.. "erasable reach every server (Migrate to latest update, or a restart) before erasing. The cut goes on as on any "
	.. "key. Ledger warns of this once per store."

local function CutKindOf(Event: EraseCall | ResetCall): CutKind
	if Event.Method == "Erase" then
		return "Erase"
	end
	return "Reset"
end

local function GivenOf(Event: EraseCall | ResetCall): Fields?
	if Event.Method == "Reset" then
		return Event.Given
	end
	return nil
end

local function TermsDigest(Server: ServerState, Kind: CutKind, Given: Fields?): buffer
	local GivenText = if Given ~= nil then Json.CanonicalJson(Given) else nil
	return HashInputs.Hash(Server.Encoding, HashInputs.CutInput(Kind == "Erase", GivenText))
end

local function RememberGameName(State: State, Event: EraseCall | ResetCall, Text: string, Commands: { Command }): OpName
	local Server = State.Server
	local Digest = TermsDigest(Server, CutKindOf(Event), GivenOf(Event))
	Durable.WarnIfOtherTerms(Server, Event.Key, Text, Digest, Commands)
	return { Kind = "Game", Text = Text, Fingerprint = HashInputs.NameFingerprint(Digest) }
end

local function NameFor(
	State: State,
	Event: EraseCall | ResetCall,
	Clock: number,
	Commands: { Command }
): (OpName, number)
	local Supplied = Event.Name
	if Supplied == nil then
		return Numbers.DrawnName(State.Server), Clock
	end
	if Supplied.Kind == "Drawn" then
		return { Kind = "Drawn", Server = Supplied.Server, Counter = Supplied.Counter }, Supplied.Stamp
	end
	if Supplied.Stamp == nil then
		error(NoFirstSendTime)
	end
	return RememberGameName(State, Event, Supplied.Text, Commands), Supplied.Stamp
end

local function GateOpName(Held: Gate): OpName
	local Name = Held.Name
	if Name.Kind == "Drawn" then
		return { Kind = "Drawn", Server = Name.Server, Counter = Name.Counter }
	end
	if Held.Fingerprint == nil then
		error(NoGateFingerprint)
	end
	return { Kind = "Game", Text = Name.Text, Fingerprint = Held.Fingerprint }
end

local function JudgedText(Call: CutCall): string
	return Removal.SealText(Call.Key, Entries.PlainName(Call.Name), Call.Stamp)
end

local function KeepJudged(State: State, Call: CutCall)
	local Tag = Call.Incarnation
	if Call.Role ~= "Cutter" or Tag == nil or Tag.Kind == "Absent" or Tag.Kind == "Any" then
		return
	end
	local Text = JudgedText(Call)
	local Until = Call.Stamp + Cache.StoreOf(State.Server, Call.Key).Setup.Limits.CutWindow
	State.Cuts.Judged[Text] = { Incarnation = Tag, Until = Until }
	DueTimes.Add(State.Cuts.JudgedTimes, Text, Until)
end

local function JudgedTagOf(State: State, Call: CutCall, Clock: number): Incarnation?
	local Judged = State.Cuts.Judged
	for _, Text in DueTimes.TakeDue(State.Cuts.JudgedTimes, Clock) do
		local Held = Judged[Text]
		if Held ~= nil and Held.Until <= Clock then
			Judged[Text] = nil
		end
	end
	local Held = Judged[JudgedText(Call)]
	return if Held ~= nil then Held.Incarnation else nil
end

local function KeepTag(Server: ServerState, Call: CutCall): Incarnation
	local Held = Call.Incarnation
	if Held ~= nil then
		return Held
	end
	local Tag = Incarnations.IncarnationOf(Server, Cache.StoreOf(Server, Call.Key).Setup, Call.Key)
	Call.Incarnation = Tag
	return Tag
end

local function OpOf(Form: CutForm, Stamp: number, Tag: Incarnation, IsClean: boolean): SentOp
	return { Form = Form, OpKind = CutOpKind, Terms = nil, Stamp = Stamp, Incarnation = Tag, IsClean = IsClean }
end

local function OwnForm(Server: ServerState, Call: CutCall): CutForm
	return {
		Kind = "Cut",
		Name = Call.Name,
		CutKind = Call.CutKind,
		Role = Call.Role,
		Given = Call.Given,
		Sender = Numbers.ServerNumberOf(Server),
	}
end

local function HelperForm(Server: ServerState, Held: Gate): CutForm
	return {
		Kind = "Cut",
		Name = GateOpName(Held),
		CutKind = Held.Kind,
		Role = "Helper",
		Given = nil,
		Sender = Numbers.ServerNumberOf(Server),
	}
end

local function CarrierOf(Call: CutCall): Carrier
	return { Kind = "Cut", CallId = Call.CallId }
end

local function CutRequest(Server: ServerState, Call: CutCall, Clock: number): UpdateRequest
	local Tag = KeepTag(Server, Call)
	local IsClean = not Call.MayHaveWritten
	local Ops: { SentOp } = {}
	local Carried = Call.CarriedGate
	if Carried ~= nil then
		table.insert(Ops, OpOf(HelperForm(Server, Carried), Carried.Stamp, Tag, IsClean))
	end
	table.insert(Ops, OpOf(OwnForm(Server, Call), Call.Stamp, Tag, IsClean))
	return {
		Kind = "Update",
		WriterId = nil,
		Acknowledged = 0,
		MustExist = true,
		Ops = Ops,
		Ends = Rides.TakeFor(Server, Call.Key, Clock, CarrierOf(Call)),
	}
end

local function WarnWrittenBeforeErasable(State: State, Call: CutCall, Commands: { Command })
	local Store = Call.Key.Store
	local Warned = State.Cuts.LegacyWarnedStores
	if Warned[Store] then
		return
	end
	Warned[Store] = true
	local Text = string.format(WrittenBeforeErasableWarning, Store)
	local Warn: Command = { Kind = "Warn", Key = Call.Key, Text = Text }
	table.insert(Commands, Warn)
end

local function IsLegacyTagged(Call: CutCall): boolean
	local Tag = Call.Incarnation
	return Tag ~= nil and Tag.Kind == "Legacy"
end

local function SendCut(State: State, Call: CutCall, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Server = State.Server
	local Request = CutRequest(Server, Call, Clock)
	if IsLegacyTagged(Call) then
		WarnWrittenBeforeErasable(State, Call, Commands)
	end
	local Purpose: Purpose = { Kind = "Cut", CallId = Call.CallId, Key = Call.Key, Carried = Request.Ends }
	local RequestId = CutState.NewRequest(Server, State.Cuts, Purpose)
	Call.Out = RequestId
	Call.Phase = "Cutting"
	Call.RetryAt = nil
	Call.WaitUntil = nil
	local Update: Command = { Kind = "Update", RequestId = RequestId, Target = Call.Key, Request = Request }
	table.insert(Commands, Update)
end

local function AskIncarnation(State: State, Call: CutCall, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Purpose: Purpose = { Kind = "IncarnationRead", CallId = Call.CallId, Key = Call.Key }
	local RequestId = CutState.NewRequest(State.Server, State.Cuts, Purpose)
	Call.Out = RequestId
	Call.Phase = "Identity"
	local Get: Command = { Kind = "Get", RequestId = RequestId, Target = Call.Key }
	table.insert(Commands, Get)
end

local function SendFirst(State: State, Call: CutCall, Clock: number, Commands: { Command })
	if Incarnations.IsUnseen(State.Server, Call.Key) then
		return AskIncarnation(State, Call, Clock, Commands)
	end
	SendCut(State, Call, Clock, Commands)
end

local function IsOwnNameAged(State: State, Event: EraseCall | ResetCall, Clock: number): boolean
	local Supplied = Event.Name
	if Supplied == nil or Supplied.Kind ~= "Drawn" then
		return false
	end
	local Server = State.Server
	if Supplied.Server ~= Numbers.ServerNumberOf(Server) then
		return false
	end
	return Clock - Supplied.Stamp >= Cache.StoreOf(Server, Event.Key).Setup.Limits.CutWindow
end

local function Begin(State: State, Event: EraseCall | ResetCall, Arrived: number, Clock: number, Commands: { Command })
	local Name, Stamp = NameFor(State, Event, Clock, Commands)
	if IsOwnNameAged(State, Event, Clock) then
		local Expired = Replies.FailedAnswer(Reasons.Expired)
		return Replies.Reply(Commands, Event.CallId, Replies.Named(Expired, Replies.GivenNameOf(Name, Stamp)))
	end
	local Call =
		CutState.NewCall(Event.CallId, Event.Key, CutKindOf(Event), Name, Stamp, GivenOf(Event), "Cutter", Arrived)
	Call.IsHandleResend = Event.Name ~= nil and Event.Name.Kind == "Drawn"
	Call.Incarnation = JudgedTagOf(State, Call, Clock)
	State.Cuts.Calls[Call.CallId] = Call
	SendFirst(State, Call, Clock, Commands)
end

local function Answer(Call: CutCall, Given: GivenAnswer, Commands: { Command })
	if Call.HasAnswered then
		return
	end
	Call.HasAnswered = true
	Replies.Reply(Commands, Call.CallId, Replies.Named(Given, Replies.GivenNameOf(Call.Name, Call.Stamp)))
end

local function AnswerTrue(Call: CutCall, Commands: { Command })
	local Done: CutAnswer = { Name = Replies.GivenNameOf(Call.Name, Call.Stamp), Namings = nil }
	Answer(Call, { Kind = "Succeeded", Value = Done }, Commands)
end

local function AnswerNamed(Call: CutCall, Namings: LossRecords, Commands: { Command })
	local Done: CutAnswer = { Name = Replies.GivenNameOf(Call.Name, Call.Stamp), Namings = Namings }
	Answer(Call, { Kind = "Succeeded", Value = Done }, Commands)
end

local function AnswerMissing(Call: CutCall, Held: Identity?, Commands: { Command })
	Answer(Call, { Kind = "Failed", Reason = Reasons.Missing, State = nil, Identity = Held }, Commands)
end

local function AnswerNo(Call: CutCall, Reason: Reason, Commands: { Command })
	Answer(Call, Replies.FailedAnswer(Reason), Commands)
end

local function GiveUp(State: State, Call: CutCall, Commands: { Command })
	AnswerNo(Call, Reasons.Unresolved, Commands)
	CutState.EndCall(State.Cuts, Call)
end

local function EndUnreadable(State: State, Call: CutCall, Cause: Cause, Commands: { Command })
	if Cause ~= "Balance" then
		Unreadable.Warn(State.Server, Call.Key, Cause, Commands)
	end
	if Call.MayHaveWritten then
		return GiveUp(State, Call, Commands)
	end
	AnswerNo(Call, Unreadable.ReasonOf(Cause), Commands)
	CutState.EndCall(State.Cuts, Call)
end

local function OnIncarnationRead(
	State: State,
	Call: CutCall,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
)
	Call.Out = nil
	local Server = State.Server
	local Setup = Cache.StoreOf(Server, Call.Key).Setup
	if Fetched.Kind == "Failed" then
		Call.ReadErrors += 1
		if Call.ReadErrors <= Setup.Limits.RetryRounds then
			return AskIncarnation(State, Call, Clock, Commands)
		end
		return GiveUp(State, Call, Commands)
	end
	local Read = Numbers.LearnStored(Server, Call.Key, Setup, Fetched, Clock)
	if Read.Kind == "Unreadable" then
		return EndUnreadable(State, Call, Read.Cause, Commands)
	end
	SendCut(State, Call, Clock, Commands)
end

local function Redraw(State: State, Call: CutCall, Clock: number, Commands: { Command })
	Call.Name = Numbers.DrawnName(State.Server)
	Call.Stamp = Clock
	Call.HasRedrawn = true
	SendCut(State, Call, Clock, Commands)
end

local function AfterWork(State: State, CallId: number, Clock: number, Commands: { Command })
	local Working = CutState.FindCall(State.Cuts, CallId)
	if Working ~= nil then
		SendCut(State, Working, Clock, Commands)
	end
end

return {
	GateOpName = GateOpName,
	Begin = Begin,
	OnIncarnationRead = OnIncarnationRead,
	CarrierOf = CarrierOf,
	CutRequest = CutRequest,
	KeepJudged = KeepJudged,
	SendFirst = SendFirst,
	SendCut = SendCut,
	WarnWrittenBeforeErasable = WarnWrittenBeforeErasable,
	AnswerTrue = AnswerTrue,
	AnswerNamed = AnswerNamed,
	AnswerMissing = AnswerMissing,
	AnswerNo = AnswerNo,
	EndUnreadable = EndUnreadable,
	Redraw = Redraw,
	AfterWork = AfterWork,
}
