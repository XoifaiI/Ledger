--!strict
--!optimize 2

--[=[
	State: a server's transaction state (transaction sheets 5, 7, 16, 17, 18 and 21): a Call, a PendingCall, a
	Help, a Verify, an UncleanRead, a Resettle and a PendingRead (a Pending call's read, bound like a Resettle's but
	not open work the close waits for), and Purposes, which finds a result's owner by its request id. HasResolveOut
	says whether a resolve of this server's is out on a key.

	A game named walk's step also holds LaterParts, the parts its walk would try after it; SiblingFence, the sibling
	sub name it fences now; OwnMarksStanding, set when marks of its own may stand once it answered, and saying
	whether its own part is already fenced (OwnPartUnfenced, OwnPartFenced); and FenceFor, what its final fence was
	sent for. MovingOn: its own sub name was decided aborted, so a fenced or refused fence is the part's no and the
	walk goes on. Sweeping: the no speaks for the name, so the later parts are fenced before Spent. No FenceFor: a
	give-up, answered Unresolved. A Resolving names the sub name and decider it resolves, the call's own unless a
	sibling took.

	The code that owns a record changes it in place, and the fields that never change are read only.

	Return type: A plain table of functions, FenceFor and OwnMarksStanding, and the FenceFor, OwnMarksStanding,
	Phase, NameAndStamp, SentName, Failure, GiveUp, PendingCall, SiblingFence, Resolving, Call, Purpose,
	UncleanReadPurpose, UncleanFencePurpose, UncleanResolvePurpose, TouchWritePurpose, ResettleWritePurpose, Waiter,
	TouchWaiter, ResettleWaiter, WorkWaiter, LandedSeal, Help, Verify, UncleanRead, Resettle, PendingRead, TouchWake
	and TxState types.
	Example usage:
		local State = TxState.NewState()
		local HelpId = TxState.NextId(State) --> 1
--]=]

local Decision = require("../../Keys/Trades/Decision")
local Events = require("../../Shared/Events")
local Fates = require("../../Keys/Format/Items/Fates")
local JudgingShapes = require("../../Shared/OpShapes")
local Names = require("../../Keys/Encoding/Names")
local Numbers = require("../../Keys/DataStore/Numbers")
local Reads = require("../../Keys/DataStore/Reads")
local Reasons = require("../../Keys/Constants/Reasons")
local Seal = require("../../Keys/Format/Items/Seal")
local Shapes = require("../../Shared/Shapes")
local TxShapes = require("../../Shared/TradeShapes")
local Value = require("../../Keys/Format/Value")
local Work = require("../../Keys/Format/Items/Work")

type GivenAnswer = Events.Answer
type TxLeg = TxShapes.TxLeg
type OpName = Names.OpName
type StoreKey = Names.StoreKey
type Reason = Reasons.Reason
type DeciderSays = Decision.DeciderSays
type Fate = Fates.Fate
type PinnedRecord = Work.PinnedRecord
type StandingMark = Work.StandingMark
type ReadOut = Reads.ReadOut
type Kept = Value.Kept
type Gate = Seal.Gate
type Incarnation = Shapes.Incarnation
type ServerState = Shapes.ServerState
type End = TxShapes.End
type AbortedUse = TxShapes.AbortedUse
type ResolveEnd = TxShapes.ResolveEnd
type TxOutcome = TxShapes.TxOutcome
type Report = JudgingShapes.Report

local FirstAttempt = 1

export type FenceFor = "MovingOn" | "Sweeping"

local FenceFor = {
	MovingOn = "MovingOn" :: "MovingOn",
	Sweeping = "Sweeping" :: "Sweeping",
}

export type OwnMarksStanding = "OwnPartUnfenced" | "OwnPartFenced"

local OwnMarksStanding = {
	OwnPartUnfenced = "OwnPartUnfenced" :: "OwnPartUnfenced",
	OwnPartFenced = "OwnPartFenced" :: "OwnPartFenced",
}

export type Phase =
	"RetryRead"
	| "Tents"
	| "Commit"
	| "FinalFence"
	| "SiblingFence"
	| "CleaningFence"
	| "Helping"
	| "Verifying"
	| "GateWait"
	| "Resolving"
	| "Holding"
	| "Done"

export type NameAndStamp = { read Name: OpName, read Stamp: number }

export type SentName = { read Text: string, read Digest: string }

export type Failure = "Err" | "Unreadable" | "Amounts" | "Balance"

export type GiveUp = "Behind" | "Unreadable"

export type PendingCall = {
	read CallId: number,
	read Legs: { TxLeg },
	read DeciderIndex: number,
	read Started: number,
	read Named: NameAndStamp,
	read Remembers: SentName?,
	read IsStep: boolean,
	read LaterParts: { number },
	Out: { [string]: number },
	Errors: { [string]: number },
}

export type SiblingFence =
	{ read Kind: "Served", read Part: number }
	| { read Kind: "Sweep", Position: number }

export type Resolving = {
	read Name: OpName,
	read Decider: StoreKey,
	read Outcome: TxOutcome,
	read Attempt: number,
	read DeciderValue: number?,
	Left: number,
	HasUnresolved: boolean,
	RidesDueAt: number?,
}

export type Call = {
	read CallId: number,
	Phase: Phase,
	Name: OpName,
	Stamp: number,
	read Legs: { TxLeg },
	read DeciderIndex: number,
	read Decider: StoreKey,
	read OtherKeys: { StoreKey },
	Attempt: number,
	Mine: { [string]: boolean },
	MayHoldMark: { [string]: boolean },
	IsUnclean: boolean,
	CommitMayHaveWritten: boolean,
	MayHaveRun: { [string]: boolean },
	CommitMissed: boolean,
	Erred: boolean,
	Rounds: number,
	Tags: { [string]: Incarnation },
	Out: { [string]: number },
	Errors: { [string]: number },
	LastFailures: { [string]: Failure },
	HasAnswered: boolean,
	OwesOutcome: boolean,
	read Started: number,
	WaitUntil: number?,
	HasRedrawn: boolean,
	OtherMarkOn: { [string]: boolean },
	Verifying: number?,
	TentReports: { [string]: Report },
	GivesUp: GiveUp?,
	Resolving: Resolving?,
	Gate: Gate?,
	GatedAt: ("Tents" | "Commit")?,
	read IsStep: boolean,
	read LaterParts: { number },
	Given: GivenAnswer?,
	DeciderFate: Fate?,
	ResendAt: number?,
	Resends: number,
	FenceFor: FenceFor?,
	SiblingFence: SiblingFence?,
	OwnMarksStanding: OwnMarksStanding?,
	TookPart: number?,
	TookValue: number?,
}

export type UncleanReadPurpose = {
	read Kind: "UncleanRead",
	read ReadRequestId: number,
	read Blocker: number,
	read Key: StoreKey,
}

export type UncleanFencePurpose = {
	read Kind: "UncleanFence",
	read ReadRequestId: number,
	read Blocker: number,
	read Key: StoreKey,
}

export type UncleanResolvePurpose = {
	read Kind: "UncleanResolve",
	read ReadRequestId: number,
	read Key: StoreKey,
	read Carried: { End },
}

export type TouchWritePurpose = { read Kind: "TouchWrite", read Key: StoreKey, read Carried: { End } }

export type ResettleWritePurpose = {
	read Kind: "ResettleWrite",
	read CallId: number,
	read Key: StoreKey,
	read Carried: { End },
}

export type Purpose =
	{ read Kind: "IncarnationRead", read CallId: number, read Key: StoreKey }
	| { read Kind: "RetryRead", read CallId: number, read Key: StoreKey }
	| { read Kind: "Tent", read CallId: number, read Key: StoreKey, read Carried: { End } }
	| { read Kind: "Commit", read CallId: number, read Key: StoreKey, read Carried: { End } }
	| { read Kind: "FinalFence", read CallId: number, read Key: StoreKey }
	| { read Kind: "SiblingFence", read CallId: number, read Key: StoreKey }
	| { read Kind: "CleaningFence", read CallId: number, read Key: StoreKey }
	| { read Kind: "Resolve", read CallId: number, read Key: StoreKey }
	| { read Kind: "PendingRead", read CallId: number, read Key: StoreKey }
	| { read Kind: "ResettleRead", read CallId: number, read Key: StoreKey }
	| { read Kind: "HelpRead", read HelpId: number, read Blocker: number, read Key: StoreKey }
	| { read Kind: "HelpFence", read HelpId: number, read Blocker: number, read Key: StoreKey }
	| { read Kind: "VerifyRead", read VerifyId: number, read Record: number, read Key: StoreKey }
	| { read Kind: "VerifyResolve", read VerifyId: number, read Record: number, read Key: StoreKey }
	| { read Kind: "Prove", read VerifyId: number, read Key: StoreKey }
	| { read Kind: "TouchRead", read Key: StoreKey }
	| UncleanReadPurpose
	| UncleanFencePurpose
	| UncleanResolvePurpose
	| TouchWritePurpose
	| ResettleWritePurpose

export type TouchWaiter = { read Kind: "Touch", read Key: StoreKey }

export type ResettleWaiter = { read Kind: "Resettle", read CallId: number }

export type WorkWaiter = TouchWaiter | ResettleWaiter

export type Waiter =
	{ read Kind: "Writer", read Key: StoreKey }
	| { read Kind: "Call", read CallId: number }
	| WorkWaiter
	| { read Kind: "Read", read ReadRequestId: number }
	| { read Kind: "Help", read HelpId: number }
	| { read Kind: "Cut", read CallId: number }

export type LandedSeal = { read Key: StoreKey, read RemovalStamp: number }

export type Help = {
	read Id: number,
	read For: Waiter,
	read Key: StoreKey,
	read Blockers: { StandingMark },
	read AskedAt: { [number]: number },
	read EndsToRide: { ResolveEnd },
	read Waiting: { [number]: number },
	Left: number,
}

export type Verify = {
	read Id: number,
	read Decider: StoreKey,
	read Records: { PinnedRecord },
	read Resolved: { [number]: { [string]: boolean } },
	read Missing: { [number]: { [string]: StoreKey } },
	Cancelled: boolean,
	IsProving: boolean,
	Left: number,
	read Seals: { [string]: LandedSeal },
	read For: Waiter,
}

export type UncleanRead = {
	read Out: ReadOut,
	read Kept: Kept,
	read Viewed: { [unknown]: unknown },
	read AskedAt: number,
	read Marks: { StandingMark },
	read Says: { [number]: DeciderSays },
	read Fenced: { [number]: boolean },
	Left: number,
}

export type Resettle = {
	read CallId: number,
	read Key: StoreKey,
	read Started: number,
}

export type PendingRead = {
	read CallId: number,
	read Key: StoreKey,
	read Started: number,
	read RequestId: number,
}

export type TouchWake = { read Key: StoreKey, read At: number }

export type TxState = {
	PendingCalls: { [number]: PendingCall },
	Calls: { [number]: Call },
	Purposes: { [number]: Purpose },
	Helps: { [number]: Help },
	Verifies: { [number]: Verify },
	FirstSeen: { [string]: number },
	SeenOrder: { string },
	SeenNext: number,
	TouchAt: { [string]: TouchWake },
	Unclean: { [number]: UncleanRead },
	Resettles: { [number]: Resettle },
	PendingReads: { [number]: PendingRead },
	StepFailures: { [number]: Reason },
	UnreachableWarned: { [string]: { [string]: true } },
	NextId: number,
}

local function NewState(): TxState
	return {
		PendingCalls = {},
		Calls = {},
		Purposes = {},
		Helps = {},
		Verifies = {},
		FirstSeen = {},
		SeenOrder = {},
		SeenNext = 1,
		TouchAt = {},
		Unclean = {},
		Resettles = {},
		PendingReads = {},
		StepFailures = {},
		UnreachableWarned = {},
		NextId = 1,
	}
end

local function NextId(State: TxState): number
	local Id = State.NextId
	State.NextId += 1
	return Id
end

local function NewCall(Pending: PendingCall, Phase: Phase): Call
	local OtherKeys: { StoreKey } = {}
	for Index, Leg in Pending.Legs do
		if Index ~= Pending.DeciderIndex then
			table.insert(OtherKeys, Leg.Key)
		end
	end
	return {
		CallId = Pending.CallId,
		Phase = Phase,
		Name = Pending.Named.Name,
		Stamp = Pending.Named.Stamp,
		Legs = Pending.Legs,
		DeciderIndex = Pending.DeciderIndex,
		Decider = Pending.Legs[Pending.DeciderIndex].Key,
		OtherKeys = OtherKeys,
		Attempt = FirstAttempt,
		Mine = {},
		MayHoldMark = {},
		IsUnclean = false,
		CommitMayHaveWritten = false,
		MayHaveRun = {},
		CommitMissed = false,
		Erred = false,
		Rounds = 0,
		Tags = {},
		Out = {},
		Errors = {},
		LastFailures = {},
		HasAnswered = false,
		OwesOutcome = false,
		Started = Pending.Started,
		WaitUntil = nil,
		HasRedrawn = false,
		OtherMarkOn = {},
		Verifying = nil,
		TentReports = {},
		GivesUp = nil,
		Resolving = nil,
		Gate = nil,
		GatedAt = nil,
		IsStep = Pending.IsStep,
		LaterParts = Pending.LaterParts,
		Given = nil,
		DeciderFate = nil,
		ResendAt = nil,
		Resends = 0,
		FenceFor = nil,
		SiblingFence = nil,
		OwnMarksStanding = nil,
		TookPart = nil,
		TookValue = nil,
	}
end

local function EndCall(State: TxState, Call: Call)
	Call.Phase = "Done"
	if Call.Given == nil then
		State.Calls[Call.CallId] = nil
	end
end

local function NewRequest(Server: ServerState, State: TxState, Purpose: Purpose): number
	local RequestId = Numbers.NewRequestId(Server)
	State.Purposes[RequestId] = Purpose
	return RequestId
end

local function AbortedUses(State: TxState): { AbortedUse }
	local Aborted: { AbortedUse } = {}
	for _, Answered in State.Calls do
		local Resolving = Answered.Resolving
		if Resolving ~= nil and Resolving.Outcome ~= "Commit" then
			table.insert(Aborted, { Name = Answered.Name, Attempt = Resolving.Attempt })
		end
	end
	return Aborted
end

local function HasResolveOut(State: TxState, Key: StoreKey): boolean
	local Text = Names.KeyText(Key)
	for _, Purpose in State.Purposes do
		if Purpose.Kind == "Resolve" and Names.KeyText(Purpose.Key) == Text then
			return true
		end
	end
	return false
end

local function OpenCount(State: TxState): number
	local Count = 0
	for _, Open in State.Calls do
		if not Open.HasAnswered or next(Open.Out) ~= nil or Open.Given ~= nil then
			Count += 1
		end
	end
	for _ in State.Resettles do
		Count += 1
	end
	for _ in State.PendingCalls do
		Count += 1
	end
	return Count
end

return {
	FirstAttempt = FirstAttempt,
	FenceFor = FenceFor,
	OwnMarksStanding = OwnMarksStanding,
	OpenCount = OpenCount,
	HasResolveOut = HasResolveOut,
	AbortedUses = AbortedUses,
	NewState = NewState,
	NextId = NextId,
	NewCall = NewCall,
	EndCall = EndCall,
	NewRequest = NewRequest,
}
