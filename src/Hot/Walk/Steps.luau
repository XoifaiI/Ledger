--!strict
--!optimize 2

--[=[
	Steps: what a walk sends for a part and under what name (sheet H3, H6). A step is a one key op under sub name
	x.p, or, with legs, a Tx of the part's take and the legs. A named take's fingerprint is its first step's.

	Return type: A plain table with HasLegs, NameAndStampOf, RememberGivenName, SendOpStep and SendTxStep.
	Example usage:
		local Name, Stamp = Steps.NameAndStampOf(Server, Call, FirstPart, Clock)
--]=]

local Cache = require("../../Reading/Cache")
local Composed = require("../../Composed")
local Durable = require("../../Writing/Durable")
local Entries = require("../../Stored/Entries")
local Events = require("../../Events")
local HashInputs = require("../../Encoding/HashInputs")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../Shapes")
local HotState = require("../State")
local JoinPartOp = require("../Part/Join").JoinPartOp
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local PartBuild = require("../Part/Build")
local Shapes = require("../../Shapes")
local Terms = require("../../Tx/Call/Terms")
local TxCalls = require("../../Tx/Call/Call")

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
	TxCalls.BeginSubStep(State, StepTxOf(Server, Call, Part, StepId), Named, JoinedAt, Clock, Commands)
	return StepId
end

return {
	HasLegs = HasLegs,
	NameAndStampOf = NameAndStampOf,
	RememberGivenName = RememberGivenName,
	SendOpStep = SendOpStep,
	SendTxStep = SendTxStep,
}
