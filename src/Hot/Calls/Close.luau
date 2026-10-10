--!strict
--!optimize 2

--[=[
	Close: a quantity's Close (hot keys sheet H7). It asks each part's writer for a close, a piece each. A closed,
	empty part strictly more than SealAge past its t_open is removed, unless the close reached its deadline. A piece
	shed Busy or answered Closed gives the Close that reason when no piece closed a part. A call answers once.

	Return type: A plain table of functions.
	Example usage:
		Close.StartClose(State, Call, Clock, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Events = require("../../Events")
local Holds = require("../Part/Holds")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../Shapes")
local HotState = require("../State")
local InFlight = require("../../Reading/InFlight")
local JoinPartOp = require("../Part/Join").JoinPartOp
local JudgingShapes = require("../../Judging/Shapes")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Part = require("../../Stored/Items/Part")
local PartBuild = require("../Part/Build")
local Reasons = require("../../Constants/Reasons")
local Replies = require("../../Replies")
local Shapes = require("../../Shapes")
local Sorted = require("../../Sorted")

type Command = Events.Command
type StoreKey = Names.StoreKey
type CloseCall = HotShapes.CloseCall
type CloseTerms = HotShapes.CloseTerms
type Closed = HotShapes.Closed
type Note = JudgingShapes.Note
type Reason = Reasons.Reason
type ServerState = Shapes.ServerState
type StepOut = Shapes.StepOut
type State = Composed.State
type CloseWork = HotState.CloseWork
type HotPurpose = HotState.Purpose

local PartOpKind = Hot.PartOpKind

local ModuleName = "Close"
local NoCloseWork = `{ModuleName}: this call is never made. A removal result is heard only while its Close is open.`
local LateToClose = `{ModuleName}: this call is never made. A step heard after its call answered goes to Outcomes.`

local function DropClose(State: State, Work: CloseWork)
	for RequestId in Work.Removals do
		State.Hot.Purposes[RequestId] = nil
	end
	State.Hot.Closes[Work.Call.CallId] = nil
end

local function FailClose(State: State, Work: CloseWork, Reason: Reason, Commands: { Command })
	DropClose(State, Work)
	Replies.ReplyFailed(Commands, Work.Call.CallId, Reason)
end

local function UnsentReasonOf(Reason: Reason): Reason?
	if Reason == Reasons.Busy or Reason == Reasons.Closed then
		return Reason
	end
	return nil
end

local function HasClosedPart(Work: CloseWork): boolean
	return #Work.Removed > 0 or #Work.Left > 0
end

local function AnswerIfDone(State: State, Work: CloseWork, Commands: { Command })
	if next(Work.Pieces) ~= nil or next(Work.Removals) ~= nil then
		return
	end
	local Unsent = Work.Unsent
	if Unsent ~= nil and HasClosedPart(Work) then
		return FailClose(State, Work, Reasons.Unresolved, Commands)
	end
	if Unsent ~= nil then
		return FailClose(State, Work, Unsent, Commands)
	end
	table.sort(Work.Removed)
	table.sort(Work.Left)
	table.sort(Work.Missing)
	local Given: Closed = { Removed = Work.Removed, Left = Work.Left, Missing = Work.Missing }
	DropClose(State, Work)
	Replies.Reply(Commands, Work.Call.CallId, { Kind = "Succeeded", Value = Given })
end

local function CanStartClose(State: State, Call: CloseCall): boolean
	if State.Server.ServerNumber == nil then
		return false
	end
	for Index = 0, Call.Quantity.Parts - 1 do
		if not InFlight.CanWrite(State.Server, HotState.PartKeyOf(Call, Index)) then
			return false
		end
	end
	return true
end

local function StartClose(State: State, Call: CloseCall, Arrived: number, Clock: number, Commands: { Command })
	local Server = State.Server
	local Terms: CloseTerms = { Fingerprint = PartBuild.FingerprintOf(Server.Encoding, Call.Quantity) }
	local Work: CloseWork = {
		Call = Call,
		Pieces = {},
		Removals = {},
		Removed = {},
		Left = {},
		Missing = {},
		Unsent = nil,
	}
	State.Hot.Closes[Call.CallId] = Work
	for Index = 0, Call.Quantity.Parts - 1 do
		local PieceId = Numbers.NewHelperId(Server)
		Work.Pieces[PieceId] = Index
		HotState.AddStepOwner(State.Hot, PieceId, { Kind = "Close", CallId = Call.CallId })
		local Key = HotState.PartKeyOf(Call, Index)
		local Op = PartBuild.NewStepOp({ Kind = "Minted" }, PartOpKind.Close, Terms, PieceId, Arrived)
		JoinPartOp(State, Key, Op, Call.Fraction, Clock, Commands)
	end
end

local function IsRemovable(Server: ServerState, Key: StoreKey, Note: Note, Clock: number): boolean
	local Setup = Cache.StoreOf(Server, Key).Setup
	local Shown = HotState.StateOf(Note)
	local Record = Part.RecordOf(Shown)
	local OpenedAt = Record.OpenedAt
	if OpenedAt == nil or Clock - OpenedAt <= Setup.Limits.SealAge then
		return false
	end
	return Holds.IsEmpty(Shown, Record, Note.Work, Setup.Build.Balances)
end

local function SendRemove(State: State, Work: CloseWork, Index: number, Clock: number, Commands: { Command })
	local Purpose: HotPurpose = { Kind = "Remove", CallId = Work.Call.CallId }
	local RequestId = HotState.NewRequest(State.Server, State.Hot, Purpose)
	Work.Removals[RequestId] = { Index = Index, SentAt = Clock }
	local Remove: Command = { Kind = "Remove", RequestId = RequestId, Target = HotState.PartKeyOf(Work.Call, Index) }
	table.insert(Commands, Remove)
end

local function OnCloseOut(State: State, CallId: number, Out: StepOut, Clock: number, Commands: { Command })
	if Out.Kind == "Late" then
		error(LateToClose)
	end
	local Work = State.Hot.Closes[CallId]
	if Work == nil then
		return
	end
	local Index = Work.Pieces[Out.CallId]
	Work.Pieces[Out.CallId] = nil
	if Out.Kind == "Answered" then
		local Unsent = UnsentReasonOf(Out.Reason)
		if Unsent == nil then
			return FailClose(State, Work, Reasons.Unresolved, Commands)
		end
		if Work.Unsent ~= Reasons.Closed then
			Work.Unsent = Unsent
		end
		return AnswerIfDone(State, Work, Commands)
	end
	local Key = HotState.PartKeyOf(Work.Call, Index)
	if Out.Report.Kind == "Missing" then
		table.insert(Work.Missing, Index)
	elseif Out.Reason ~= nil then
		return FailClose(State, Work, Out.Reason, Commands)
	elseif not Closing.IsPastDeadline(State.Sessions, Clock) and IsRemovable(State.Server, Key, Out.Note, Clock) then
		SendRemove(State, Work, Index, Clock, Commands)
	else
		table.insert(Work.Left, Index)
	end
	AnswerIfDone(State, Work, Commands)
end

local function OnRemoved(State: State, CallId: number, RequestId: number, IsOk: boolean, Commands: { Command })
	local Work = State.Hot.Closes[CallId]
	if Work == nil then
		error(NoCloseWork)
	end
	local Sent = Work.Removals[RequestId]
	Work.Removals[RequestId] = nil
	local Listed = if IsOk then Work.Removed else Work.Left
	table.insert(Listed, Sent.Index)
	AnswerIfDone(State, Work, Commands)
end

local function ActOnClose(State: State, Work: CloseWork, Clock: number, Commands: { Command })
	local Bound = HotState.OpBoundOf(State.Server, Work.Call.Store)
	for _, RequestId in Sorted.SortedIds(Work.Removals) do
		local Sent = Work.Removals[RequestId]
		if Clock >= Sent.SentAt + Bound then
			State.Hot.Purposes[RequestId] = nil
			Work.Removals[RequestId] = nil
			table.insert(Work.Left, Sent.Index)
		end
	end
	AnswerIfDone(State, Work, Commands)
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	for _, CallId in Sorted.SortedIds(State.Hot.Closes) do
		ActOnClose(State, State.Hot.Closes[CallId], Clock, Commands)
	end
end

local function NextWake(State: State, Clock: number): number?
	local Soonest: number? = nil
	for _, Work in State.Hot.Closes do
		local Bound = HotState.OpBoundOf(State.Server, Work.Call.Store)
		for _, Sent in Work.Removals do
			Soonest = Composed.EarliestAfter(Soonest, Sent.SentAt + Bound, Clock)
		end
	end
	return Soonest
end

local function EndUnresolved(State: State, Commands: { Command })
	for _, CallId in Sorted.SortedIds(State.Hot.Closes) do
		FailClose(State, State.Hot.Closes[CallId], Reasons.Unresolved, Commands)
	end
end

return {
	CanStartClose = CanStartClose,
	StartClose = StartClose,
	OnCloseOut = OnCloseOut,
	OnRemoved = OnRemoved,
	OnClock = OnClock,
	NextWake = NextWake,
	EndUnresolved = EndUnresolved,
}
