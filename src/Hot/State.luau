--!strict
--!optimize 2

--[=[
	State: a server's hot keys state (sheet H6 to H9): a view per quantity, each Take or Hold's Walk with its fence and
	tidies, OpenWorks, CloseWorks, a TxStep per step sent as a Tx, request Purposes and owed Take outcomes. A Tx counts
	its walk while its step is out. EndOwedCall keeps the fence's Purpose for a late result.

	Return type: A plain table of functions, and the ViewEntry, QuantityView, PartTry, FenceOut, Walk, OpenPart,
	OpenWork, CloseWork, CloseOwner, ConfirmOwner, StepOwner, ConfirmStep, GatherStep, WalkStep, TxStep, Purpose and
	HotState types.
	Example usage:
		local State = HotState.NewState()
		local View = HotState.ViewOf(State, "Shop", "global", { Name = "sword", Parts = 4 })
--]=]

local Cache = require("../Reading/Cache")
local ExtrasState = require("../Extras/State")
local Fates = require("../Stored/Items/Fates")
local GetOrMake = require("../GetOrMake").GetOrMake
local HotShapes = require("./Shapes")
local JudgingShapes = require("../Judging/Shapes")
local Names = require("../Encoding/Names")
local Numbers = require("../Writing/Numbers")
local PartBuild = require("./Part/Build")
local Reasons = require("../Constants/Reasons")
local Shapes = require("../Shapes")
local Value = require("../Stored/Value")
local Writers = require("../Writing/Writer")

type OpName = Names.OpName
type StoreKey = Names.StoreKey
type OutRead = ExtrasState.OutRead
type PartReason = Fates.PartReason
type Reason = Reasons.Reason
type OpenCall = HotShapes.OpenCall
type CloseCall = HotShapes.CloseCall
type ConfirmCall = HotShapes.ConfirmCall
type GatherCall = HotShapes.GatherCall
type QuantityName = HotShapes.QuantityName
type WalkCall = HotShapes.WalkCall
type ServerState = Shapes.ServerState
type Note = JudgingShapes.Note
type Fields = Value.Fields

export type ViewEntry = {
	read Q: number,
	read Free: number,
	read Held: number,
	read Sold: number,
	read IsSealed: boolean,
	read IsClosed: boolean,
}

type Refusal = {
	read Count: number,
	read At: number,
}

export type QuantityView = {
	Parts: { [number]: ViewEntry },
	Refusals: { [number]: Refusal },
	ReadOut: { [number]: OutRead },
	AbsentAt: { [number]: number },
}

export type PartTry = PartReason | "Fenced"

export type FenceOut = {
	RequestId: number,
	read SentAt: number,
	Errors: number,
	RetryAt: number?,
}

export type Walk = {
	read Call: WalkCall,
	read Name: OpName,
	read Stamp: number,
	read Order: { number },
	Step: number,
	Tries: { [number]: PartTry },
	HasFencedStep: boolean,
	Fence: FenceOut?,
	TxStepId: number?,
	HeardAt: number?,
	Tidies: { StoreKey },
	ReadingSince: number?,
}

export type OpenPart =
	{ read Kind: "Out", read RequestId: number, read SentAt: number, read Errors: number }
	| { read Kind: "Retry", read RetryAt: number, read Errors: number }

export type OpenWork = {
	read Call: OpenCall,
	read Stamp: number,
	read Fingerprint: number,
	Parts: { [number]: OpenPart },
}

type RemovalOut = {
	read Index: number,
	read SentAt: number,
}

export type CloseWork = {
	read Call: CloseCall,
	Pieces: { [number]: number },
	Removals: { [number]: RemovalOut },
	Removed: { number },
	Left: { number },
	Missing: { number },
	Unsent: Reason?,
}

type ViewsOfName = { [number]: QuantityView }

type ViewsOfScope = { [string]: ViewsOfName }

type ViewsOfStore = { [string]: ViewsOfScope }

export type Purpose =
	{
		read Kind: "PartRead",
		read Store: string,
		read Scope: string,
		read Quantity: QuantityName,
		read Index: number,
		read CallId: number,
		read Fraction: number,
	}
	| { read Kind: "Fence", read CallId: number }
	| { read Kind: "Open", read CallId: number, read Index: number }
	| { read Kind: "Remove", read CallId: number }

export type CloseOwner = { read Kind: "Close", read CallId: number }

export type ConfirmOwner = { read Kind: "Confirm", read Call: ConfirmCall }

export type StepOwner = { read Kind: "Walk" } | CloseOwner | ConfirmOwner | { read Kind: "Release" }

export type ConfirmStep = { read Kind: "Confirm", read Call: ConfirmCall }

export type GatherStep = { read Kind: "Gather", read Call: GatherCall, read Amounts: { [number]: number } }

export type WalkStep = { read Kind: "Walk", read CallId: number }

export type TxStep = ConfirmStep | GatherStep | WalkStep

export type HotState = {
	Views: { [string]: ViewsOfStore },
	StepOwners: { [number]: StepOwner },
	TxSteps: { [number]: TxStep },
	Walks: { [number]: Walk },
	Outcomes: { [number]: StoreKey },
	Opens: { [number]: OpenWork },
	Closes: { [number]: CloseWork },
	Purposes: { [number]: Purpose },
}

local NoShownState = "State: this call is never made. A part that answers is reported with the part's state."

local function NewView(): QuantityView
	return { Parts = {}, Refusals = {}, ReadOut = {}, AbsentAt = {} }
end

local function NewState(): HotState
	return {
		Views = {},
		StepOwners = {},
		TxSteps = {},
		Walks = {},
		Outcomes = {},
		Opens = {},
		Closes = {},
		Purposes = {},
	}
end

local function ViewOf(State: HotState, Store: string, Scope: string, Quantity: QuantityName): QuantityView
	local OfStore = GetOrMake(State.Views, Store, function(): ViewsOfStore
		return {}
	end)
	local OfScope = GetOrMake(OfStore, Scope, function(): ViewsOfScope
		return {}
	end)
	local OfName = GetOrMake(OfScope, Quantity.Name, function(): ViewsOfName
		return {}
	end)
	return GetOrMake(OfName, Quantity.Parts, NewView)
end

local function NewRequest(Server: ServerState, State: HotState, Purpose: Purpose): number
	local RequestId = Numbers.NewRequestId(Server)
	State.Purposes[RequestId] = Purpose
	return RequestId
end

local function AddStepOwner(State: HotState, CallId: number, Owner: StepOwner)
	State.StepOwners[CallId] = Owner
end

local function AddTxStep(State: HotState, CallId: number, Step: TxStep)
	State.TxSteps[CallId] = Step
end

local function PartKeyOf(Call: PartBuild.PartPlace, Part: number): StoreKey
	return PartBuild.PartKey(Call.Store, Call.Scope, Call.Quantity, Part)
end

local function CurrentPart(Walk: Walk): number
	return Walk.Order[Walk.Step]
end

local function CurrentKey(Walk: Walk): StoreKey
	return PartKeyOf(Walk.Call, CurrentPart(Walk))
end

local function HasUnheardStep(Server: ServerState, Walk: Walk): boolean
	local Writer = Writers.WriterFor(Server, CurrentKey(Walk))
	return Writer ~= nil and Writers.HasUnheardOf(Writer, Walk.Call.CallId)
end

local function EndCall(State: HotState, CallId: number)
	local Walking = State.Walks[CallId]
	if Walking == nil then
		return
	end
	if Walking.Fence ~= nil then
		State.Purposes[Walking.Fence.RequestId] = nil
	end
	State.StepOwners[CallId] = nil
	State.Walks[CallId] = nil
end

local function EndOwedCall(State: HotState, CallId: number, Key: StoreKey)
	State.Outcomes[CallId] = Key
	State.StepOwners[CallId] = nil
	State.Walks[CallId] = nil
end

local function StateOf(Note: Note): Fields
	local Shown = Note.State
	if type(Shown) ~= "table" then
		error(NoShownState)
	end
	return Shown :: Fields
end

local function OpBoundOf(Server: ServerState, Store: string): number
	return Cache.StoreNamed(Server, Store).Setup.Limits.OpBound
end

local function HasUnheardPiece(Server: ServerState, Work: CloseWork): boolean
	for PieceId, Part in Work.Pieces do
		local Writer = Writers.WriterFor(Server, PartKeyOf(Work.Call, Part))
		if Writer ~= nil and Writers.HasUnheardOf(Writer, PieceId) then
			return true
		end
	end
	return false
end

local function OpenCount(State: HotState, Server: ServerState): number
	local Count = 0
	for _, Walk in State.Walks do
		if (Walk.TxStepId == nil or Walk.HeardAt ~= nil) and not HasUnheardStep(Server, Walk) then
			Count += 1
		end
	end
	for _ in State.Opens do
		Count += 1
	end
	for _, Work in State.Closes do
		if not HasUnheardPiece(Server, Work) then
			Count += 1
		end
	end
	return Count
end

return {
	NewState = NewState,
	ViewOf = ViewOf,
	NewRequest = NewRequest,
	PartKeyOf = PartKeyOf,
	CurrentPart = CurrentPart,
	CurrentKey = CurrentKey,
	AddStepOwner = AddStepOwner,
	AddTxStep = AddTxStep,
	EndCall = EndCall,
	EndOwedCall = EndOwedCall,
	StateOf = StateOf,
	OpBoundOf = OpBoundOf,
	OpenCount = OpenCount,
}
