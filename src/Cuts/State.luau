--!strict
--!optimize 2

--[=[
	State: a server's cut state (cuts sheet 8): a CutCall per call, a helper per key, Purposes that find a result's
	owner, and the seals watched. A helper's id is negative (Numbers.NewHelperId). Removed keeps each sent removal's rt
	by seal; RemovedTimes, by rt, lets old ones go without a walk. Judged keeps, by key, name and stamp, the incarnation
	a cut that may have taken effect was judged for, until W[cut] past its stamp, so a resend carries it.

	Calls change in place; fixed fields are read only.

	Return type: A plain table of functions, and the Phase, GateWaiter, Drain, CutCall, SealWatch, SealCheck,
	Purpose, SentRemoval, JudgedCut and CutsState types.
	Example usage:
		local State = CutState.NewState()
		local Cutting = CutState.FindCall(State, CallId)
--]=]

local CutShapes = require("./Shapes")
local DueTimes = require("../DueTimes")
local Names = require("../Encoding/Names")
local Numbers = require("../Writing/Numbers")
local Seal = require("../Stored/Items/Seal")
local Shapes = require("../Shapes")
local Timed = require("../Stored/Items/Timed")
local TxShapes = require("../Tx/Shapes")
local TxState = require("../Tx/State")
local Value = require("../Stored/Value")
local Work = require("../Stored/Items/Work")

type Name = Names.Name
type OpName = Names.OpName
type StoreKey = Names.StoreKey
type Fields = Value.Fields
type Gate = Seal.Gate
type CutKind = Timed.CutKind
type End = TxShapes.End
type Incarnation = Shapes.Incarnation
type ServerState = Shapes.ServerState
type Role = CutShapes.Role
type TouchWaiter = TxState.TouchWaiter
type StandingMark = Work.StandingMark
type DueTimes<Item> = DueTimes.DueTimes<Item>

export type Phase = "Identity" | "Cutting" | "Draining" | "Stamping" | "Waiting" | "Done"

export type GateWaiter = { read Kind: "Tx", read CallId: number } | TouchWaiter

export type Drain = {
	Fences: { [string]: number },
	Marks: { StandingMark },
	FenceMissing: { [number]: boolean },
	Decided: boolean,
	HasErredFence: boolean,
	AskedAt: { [number]: number },
	Reads: { [number]: number },
	VerifyId: number?,
}

export type CutCall = {
	read CallId: number,
	read Key: StoreKey,
	read CutKind: CutKind,
	Name: OpName,
	Stamp: number,
	read Given: Fields?,
	read Role: Role,
	HasRedrawn: boolean,
	IsHandleResend: boolean,
	Incarnation: Incarnation?,
	MayHaveWritten: boolean,
	ErrorsInARow: number,
	ReadErrors: number,
	QuietRounds: number,
	RoundsWithoutProgress: number,
	HasWarnedUnreachable: boolean,
	HasWarnedUnnamed: boolean,
	RetryAt: number?,
	Out: number?,
	HasAnswered: boolean,
	read Started: number,
	CarriedGate: Gate?,
	Drain: Drain?,
	WaitUntil: number?,
	Phase: Phase,
}

export type SealWatch = {
	read Key: StoreKey,
	read Name: Name,
	read RemovalStamp: number,
	read At: number,
	read Kind: "Check" | "Stamp",
}

export type SealCheck = {
	read Kind: "SealCheck",
	read Key: StoreKey,
	read Name: Name,
	read RemovalStamp: number,
}

export type Purpose =
	{ read Kind: "IncarnationRead", read CallId: number, read Key: StoreKey }
	| { read Kind: "Cut", read CallId: number, read Key: StoreKey, read Carried: { End } }
	| { read Kind: "Fence", read CallId: number, read Decider: StoreKey, read Key: StoreKey }
	| { read Kind: "OrphanRead", read CallId: number, read Mark: number, read Key: StoreKey }
	| { read Kind: "SealStamp", read Key: StoreKey, read RemovalStamp: number, read CallId: number? }
	| { read Kind: "Removal", read Key: StoreKey, read RemovalStamp: number }
	| SealCheck

export type SentRemoval = { read Text: string, read RemovalStamp: number }

export type JudgedCut = { read Incarnation: Incarnation, read Until: number }

export type CutsState = {
	Calls: { [number]: CutCall },
	Helpers: { [string]: CutCall },
	Waiters: { [string]: { GateWaiter } },
	Purposes: { [number]: Purpose },
	Watches: { [string]: SealWatch },
	Stamping: { [string]: number },
	Removed: { [string]: number },
	RemovedTimes: DueTimes<SentRemoval>,
	Judged: { [string]: JudgedCut },
	JudgedTimes: DueTimes<string>,
	LegacyWarnedStores: { [string]: boolean },
}

local function NewState(): CutsState
	return {
		Calls = {},
		Helpers = {},
		Waiters = {},
		Purposes = {},
		Watches = {},
		Stamping = {},
		Removed = {},
		RemovedTimes = {},
		Judged = {},
		JudgedTimes = {},
		LegacyWarnedStores = {},
	}
end

local function FindCall(State: CutsState, CallId: number): CutCall?
	local Found = State.Calls[CallId]
	if Found ~= nil then
		return Found
	end
	for _, Helping in State.Helpers do
		if Helping.CallId == CallId then
			return Helping
		end
	end
	return nil
end

local function NewRequest(Server: ServerState, State: CutsState, Purpose: Purpose): number
	local RequestId = Numbers.NewRequestId(Server)
	State.Purposes[RequestId] = Purpose
	return RequestId
end

local function NewCall(
	CallId: number,
	Key: StoreKey,
	CutKind: CutKind,
	Name: OpName,
	Stamp: number,
	Given: Fields?,
	Role: Role,
	Started: number
): CutCall
	return {
		CallId = CallId,
		Key = Key,
		CutKind = CutKind,
		Name = Name,
		Stamp = Stamp,
		Given = Given,
		Role = Role,
		HasRedrawn = false,
		IsHandleResend = false,
		Incarnation = nil,
		MayHaveWritten = false,
		ErrorsInARow = 0,
		ReadErrors = 0,
		QuietRounds = 0,
		RoundsWithoutProgress = 0,
		HasWarnedUnreachable = false,
		HasWarnedUnnamed = false,
		RetryAt = nil,
		Out = nil,
		HasAnswered = false,
		Started = Started,
		CarriedGate = nil,
		Drain = nil,
		WaitUntil = nil,
		Phase = "Cutting",
	}
end

local function EndCall(State: CutsState, Call: CutCall)
	Call.Phase = "Done"
	if Call.Role == "Helper" then
		State.Helpers[Names.KeyText(Call.Key)] = nil
	else
		State.Calls[Call.CallId] = nil
	end
end

local function IsOutstanding(Draining: Drain): boolean
	return next(Draining.Fences) ~= nil or next(Draining.Reads) ~= nil or Draining.VerifyId ~= nil
end

local function IsWorking(Open: CutCall): boolean
	if not Open.HasAnswered or Open.Out ~= nil or Open.Phase == "Stamping" then
		return true
	end
	return Open.Drain ~= nil and IsOutstanding(Open.Drain)
end

local function OpenCount(State: CutsState): number
	local Count = 0
	for _, Open in State.Calls do
		if IsWorking(Open) then
			Count += 1
		end
	end
	for _ in State.Helpers do
		Count += 1
	end
	return Count
end

return {
	NewState = NewState,
	FindCall = FindCall,
	NewRequest = NewRequest,
	NewCall = NewCall,
	EndCall = EndCall,
	IsOutstanding = IsOutstanding,
	OpenCount = OpenCount,
}
