--!strict
--!optimize 2

--[=[
	Open: a quantity's Open (hot keys sheet H7). It sends each part's open alone, with no writer, and sends or
	resends only while the clock reads at most RemoveSend past t_open and the close has not reached its deadline.
	A part that reports took is done. The call answers once.

	Return type: A plain table of functions.
	Example usage:
		Open.StartOpen(State, Call, Clock, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Events = require("../../Events")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../Shapes")
local HotState = require("../State")
local Incarnations = require("../../Writing/Incarnations")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local PartBuild = require("../Part/Build")
local Reasons = require("../../Constants/Reasons")
local Record = require("../../Constants/Record")
local Removal = require("../../Cuts/Seals/Removal")
local Replies = require("../../Replies")
local Sending = require("../../Writing/Sending")
local Shapes = require("../../Shapes")
local Sorted = require("../../Sorted")

type Answer = Events.Answer
type Command = Events.Command
type Outcome = Events.Outcome
type StoreKey = Names.StoreKey
type OpenCall = HotShapes.OpenCall
type ServerState = Shapes.ServerState
type SentOp = Shapes.SentOp
type UpdateRequest = Shapes.UpdateRequest
type State = Composed.State
type HotPurpose = HotState.Purpose
type OpenWork = HotState.OpenWork

local PartOpKind = Hot.PartOpKind

local NoErrors = 0
local UnusedSequence = Record.FirstSequence

local OpenedAnswer: Answer = table.freeze({ Kind = "Succeeded" :: "Succeeded", Value = true })

local ModuleName = "Open"
local NoOpenOut = `{ModuleName}: this call is never made. An open result is heard only while the part's open is out.`

local function OpenRequest(
	Server: ServerState,
	Work: OpenWork,
	Key: StoreKey,
	Index: number,
	IsClean: boolean
): UpdateRequest
	local Setup = Cache.StoreOf(Server, Key).Setup
	local Terms = PartBuild.OpenTerms(Work.Call.Quantity, Index, Work.Stamp, Work.Fingerprint)
	local Op: SentOp = {
		Form = { Kind = "Minted", Sequence = UnusedSequence },
		OpKind = PartOpKind.Open,
		Terms = Terms,
		Stamp = Work.Stamp,
		Incarnation = Incarnations.IncarnationOf(Server, Setup, Key),
		IsClean = IsClean,
	}
	return { Kind = "Update", WriterId = nil, Acknowledged = 0, MustExist = false, Ops = { Op }, Ends = {} }
end

local function SendOpen(
	State: State,
	Work: OpenWork,
	Index: number,
	Errors: number,
	Clock: number,
	Commands: { Command }
)
	local Server = State.Server
	local Key = HotState.PartKeyOf(Work.Call, Index)
	local Purpose: HotPurpose = { Kind = "Open", CallId = Work.Call.CallId, Index = Index }
	local RequestId = HotState.NewRequest(Server, State.Hot, Purpose)
	Work.Parts[Index] = { Kind = "Out", RequestId = RequestId, SentAt = Clock, Errors = Errors }
	local Update: Command = {
		Kind = "Update",
		RequestId = RequestId,
		Target = Key,
		Request = OpenRequest(Server, Work, Key, Index, Errors == NoErrors),
	}
	table.insert(Commands, Update)
end

local function StartOpen(State: State, Call: OpenCall, _Arrived: number, Clock: number, Commands: { Command })
	local Work: OpenWork = {
		Call = Call,
		Stamp = Clock,
		Fingerprint = PartBuild.FingerprintOf(State.Server.Encoding, Call.Quantity),
		Parts = {},
	}
	State.Hot.Opens[Call.CallId] = Work
	for Index = 0, Call.Quantity.Parts - 1 do
		SendOpen(State, Work, Index, NoErrors, Clock, Commands)
	end
end

local function DropOpen(State: State, Work: OpenWork)
	for _, Sent in Work.Parts do
		if Sent.Kind == "Out" then
			State.Hot.Purposes[Sent.RequestId] = nil
		end
	end
	State.Hot.Opens[Work.Call.CallId] = nil
end

local function FailOpen(State: State, Work: OpenWork, Commands: { Command })
	DropOpen(State, Work)
	Replies.ReplyFailed(Commands, Work.Call.CallId, Reasons.Unresolved)
end

local function OnOpenResult(
	State: State,
	Work: OpenWork,
	Index: number,
	Result: Outcome,
	Clock: number,
	Commands: { Command }
)
	local Sent = Work.Parts[Index]
	if Sent == nil then
		error(NoOpenOut)
	end
	local Server = State.Server
	local Key = HotState.PartKeyOf(Work.Call, Index)
	local Setup = Cache.StoreOf(Server, Key).Setup
	if Result.Kind == "Err" then
		local Errors = Sent.Errors + 1
		if Errors >= Setup.Limits.ErrorsBeforeUnresolved then
			return FailOpen(State, Work, Commands)
		end
		local RetryAt = Clock + Sending.RetryGap(Errors, Setup.Limits)
		Work.Parts[Index] = { Kind = "Retry", RetryAt = RetryAt, Errors = Errors }
		return
	end
	local Note = Result.Note
	Numbers.LearnFromNote(Server, Numbers.EntryFor(Server, Key), Key, Setup, Note)
	Sending.WarnFromNote(Key, Note, Commands)
	local Report = Note.Reports[1]
	if Report.Kind ~= "Fated" or Report.Fate.Kind ~= "Took" then
		return FailOpen(State, Work, Commands)
	end
	Work.Parts[Index] = nil
	if next(Work.Parts) ~= nil then
		return
	end
	DropOpen(State, Work)
	Replies.Reply(Commands, Work.Call.CallId, OpenedAnswer)
end

local function ActOnOpen(State: State, Work: OpenWork, Clock: number, Commands: { Command })
	local Limits = Cache.StoreNamed(State.Server, Work.Call.Store).Setup.Limits
	for _, Index in Sorted.SortedIds(Work.Parts) do
		local Sent = Work.Parts[Index]
		if Sent.Kind == "Out" then
			if Clock >= Sent.SentAt + HotState.OpBoundOf(State.Server, Work.Call.Store) then
				return FailOpen(State, Work, Commands)
			end
		elseif Clock >= Sent.RetryAt then
			if not Removal.IsWithinRemoveSend(Work.Stamp, Clock, Limits) then
				return FailOpen(State, Work, Commands)
			end
			if Closing.IsPastDeadline(State.Sessions, Clock) then
				continue
			end
			SendOpen(State, Work, Index, Sent.Errors, Clock, Commands)
		end
	end
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	for _, CallId in Sorted.SortedIds(State.Hot.Opens) do
		ActOnOpen(State, State.Hot.Opens[CallId], Clock, Commands)
	end
end

local function NextWake(State: State, Clock: number): number?
	local Soonest: number? = nil
	for _, Work in State.Hot.Opens do
		local Bound = HotState.OpBoundOf(State.Server, Work.Call.Store)
		for _, Sent in Work.Parts do
			local At = if Sent.Kind == "Out" then Sent.SentAt + Bound else Sent.RetryAt
			Soonest = Composed.EarliestAfter(Soonest, At, Clock)
		end
	end
	return Soonest
end

local function EndUnresolved(State: State, Commands: { Command })
	for _, CallId in Sorted.SortedIds(State.Hot.Opens) do
		FailOpen(State, State.Hot.Opens[CallId], Commands)
	end
end

return {
	StartOpen = StartOpen,
	OnOpenResult = OnOpenResult,
	OnClock = OnClock,
	NextWake = NextWake,
	EndUnresolved = EndUnresolved,
}
