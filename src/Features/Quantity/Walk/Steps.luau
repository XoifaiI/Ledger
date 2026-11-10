--!strict
--!optimize 2

--[=[
	Steps: what a walk sends for a part and under what name (sheet H3, H6). A step is a one key op under sub name
	x.p, or, with legs, a Tx of the part's take and the legs. A named take's fingerprint is its first step's. Under
	a game name a step Tx is told the parts after its own in the walk's order, which it fences to answer for the name.

	Return type: A plain table with HasLegs, NameAndStampOf, RememberGivenName, SendOpStep and SendTxStep.
	Example usage:
		local Name, Stamp = Steps.NameAndStampOf(Server, Call, FirstPart, Clock)
--]=]

local Cache = require("../../../Keys/DataStore/Cache")
local Composed = require("../../../Shared/Composed")
local Durable = require("../../../Keys/DataStore/Durable")
local Entries = require("../../../Keys/Format/Entries")
local Events = require("../../../Shared/Events")
local HashInputs = require("../../../Keys/Encoding/HashInputs")
local Hot = require("../../../Keys/Constants/Hot")
local HotShapes = require("../../../Shared/QuantityShapes")
local HotState = require("../State")
local JoinPartOp = require("../../../Keys/Quantity/Join").JoinPartOp
local Names = require("../../../Keys/Encoding/Names")
local Numbers = require("../../../Keys/DataStore/Numbers")
local PartBuild = require("../../../Keys/Quantity/Build")
local Shapes = require("../../../Shared/Shapes")
local Terms = require("../../Trades/Call/Terms")
local TxCalls = require("../../Trades/Call/Call")

type Command = Events.Command
type TxCall = Events.TxCall
type TakePriceInput = HashInputs.TakePriceInput
type OpName = Names.OpName
type HoldTerms = HotShapes.HoldTerms
type TakeCall = HotShapes.TakeCall
type TakeTerms = HotShapes.TakeTerms
type ServerState = Shapes.ServerState
type Setup = Shapes.Setup
type WaitingForm = Shapes.WaitingForm
type WaitingOp = Shapes.WaitingOp
type State = Composed.State
type Walk = HotState.Walk

local PartOpKind = Hot.PartOpKind

local ModuleName = "Steps"
local ProceedsNotDeclared = `{ModuleName}: a quantity's proceeds field is a balance field its store declares. `
	.. "The API checks it before the core decides"

local function PricesOf(Setup: Setup, Call: TakeCall): { TakePriceInput }
	local Prices: { TakePriceInput } = {}
	for _, Field in Call.Quantity.Proceeds do
		local Amount = Call.Price[Field]
		if Amount == nil then
			continue
		end
		local Arithmetic = Setup.Build.Balances[Field]
		if Arithmetic == nil then
			error(ProceedsNotDeclared)
		end
		table.insert(Prices, { Field = Field, AmountText = Arithmetic.Encode(Amount) })
	end
	return Prices
end

local function TakeTermsOf(Server: ServerState, Call: TakeCall): TakeTerms
	local Fingerprint = PartBuild.FingerprintOf(Server.Encoding, Call.Quantity)
	return { Fingerprint = Fingerprint, Count = Call.Count, Price = Call.Price }
end

local function StepTxOf(Server: ServerState, Call: TakeCall, Part: number, StepId: number): TxCall
	local Leg = PartBuild.PartLeg(Call, Part, PartOpKind.Take, TakeTermsOf(Server, Call))
	return PartBuild.PartTx(StepId, Leg, Call.Legs)
end

local function HasLegs(Call: TakeCall): boolean
	return #Call.Legs > 0
end

local function TermsDigestOf(Server: ServerState, Setup: Setup, Call: TakeCall, FirstPart: number): buffer
	if HasLegs(Call) then
		return Terms.DigestOf(Server, StepTxOf(Server, Call, FirstPart, Call.CallId))
	end
	local Quantity = Call.Quantity
	local Input = HashInputs.TakeInput(Quantity.Name, Quantity.Parts, Call.Count, PricesOf(Setup, Call))
	return HashInputs.Hash(Server.Encoding, Input)
end

local function NameAndStampOf(Server: ServerState, Call: TakeCall, FirstPart: number, Clock: number): (OpName, number)
	local Given = Call.Name
	if Given == nil then
		return Numbers.DrawnName(Server), Clock
	end
	local Setup = Cache.StoreNamed(Server, Call.Store).Setup
	local Digest = TermsDigestOf(Server, Setup, Call, FirstPart)
	return { Kind = "Game", Text = Given.Text, Fingerprint = HashInputs.NameFingerprint(Digest) }, Given.Stamp
end

local function RememberGivenName(Server: ServerState, Call: TakeCall, FirstPart: number, Commands: { Command })
	local Given = Call.Name
	if Given == nil then
		return
	end
	local Setup = Cache.StoreNamed(Server, Call.Store).Setup
	local Digest = TermsDigestOf(Server, Setup, Call, FirstPart)
	Durable.WarnIfOtherTerms(Server, HotState.PartKeyOf(Call, FirstPart), Given.Text, Digest, Commands)
end

local function StepOp(Server: ServerState, Walk: Walk, Part: number, JoinedAt: number): WaitingOp
	local Call = Walk.Call
	local Fingerprint = PartBuild.FingerprintOf(Server.Encoding, Call.Quantity)
	local Form: WaitingForm = { Kind = "Timed", Name = Names.WithPart(Walk.Name, Part), Stamp = Walk.Stamp }
	if Call.Method == "Take" then
		return PartBuild.NewStepOp(Form, PartOpKind.Take, TakeTermsOf(Server, Call), Call.CallId, JoinedAt)
	end
	local Holding: HoldTerms = {
		Fingerprint = Fingerprint,
		Id = Entries.PlainName(Walk.Name),
		Count = Call.Count,
		Duration = Call.Duration,
	}
	return PartBuild.NewStepOp(Form, PartOpKind.Hold, Holding, Call.CallId, JoinedAt)
end

local function SendOpStep(State: State, Walk: Walk, JoinedAt: number, Clock: number, Commands: { Command }): boolean
	local Part = HotState.CurrentPart(Walk)
	local Key = HotState.PartKeyOf(Walk.Call, Part)
	local Op = StepOp(State.Server, Walk, Part, JoinedAt)
	return JoinPartOp(State, Key, Op, Walk.Call.Fraction, Clock, Commands)
end

local function LaterPartsOf(Walk: Walk): { number }
	if Walk.Name.Kind ~= "Game" then
		return {}
	end
	return table.move(Walk.Order, Walk.Step + 1, #Walk.Order, 1, {})
end

local function SendTxStep(
	State: State,
	Walk: Walk,
	Call: TakeCall,
	JoinedAt: number,
	Clock: number,
	Commands: { Command }
): number
	local Server = State.Server
	local StepId = Numbers.NewHelperId(Server)
	local Part = HotState.CurrentPart(Walk)
	local Named = { Name = Names.WithPart(Walk.Name, Part), Stamp = Walk.Stamp }
	HotState.AddTxStep(State.Hot, StepId, { Kind = "Walk", CallId = Call.CallId })
	local LaterParts = LaterPartsOf(Walk)
	TxCalls.BeginSubStep(State, StepTxOf(Server, Call, Part, StepId), Named, LaterParts, JoinedAt, Clock, Commands)
	return StepId
end

return {
	HasLegs = HasLegs,
	NameAndStampOf = NameAndStampOf,
	RememberGivenName = RememberGivenName,
	SendOpStep = SendOpStep,
	SendTxStep = SendTxStep,
}
