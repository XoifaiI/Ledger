--!strict
--!optimize 2

--[=[
	Terms: the terms of a Tx call (transaction sheets 3.6, 7 and 15.4): how its legs are classified, which leg decides,
	the digest of its terms, and the sent names that remember a game name with them.

	A game name is remembered at the call's first send (Charter item 33), with its digest; no name, nothing.

	Return type: A plain table of functions, and the CallName type.
	Example usage:
		local Forms = Terms.ClassifyLegs(Server, Event)
		local DeciderIndex = Terms.ChooseDecider(Forms, Event.Hot)
--]=]

local Balances = require("../Legs/Balances")
local Events = require("../../Events")
local HashInputs = require("../../Encoding/HashInputs")
local Json = require("../../Encoding/Json")
local KindSetup = require("../../Judging/KindSetup")
local Names = require("../../Encoding/Names")
local Requests = require("./Requests")
local SentNames = require("../../Writing/SentNames")
local Shapes = require("../../Shapes")
local TxShapes = require("../Shapes")
local TxState = require("../State")

type Command = Events.Command
type TxCall = Events.TxCall
type TxLeg = TxShapes.TxLeg
type TxLegInput = HashInputs.TxLegInput
type OpName = Names.OpName
type StoreKey = Names.StoreKey
type LegForm = TxShapes.LegForm
type ServerState = Shapes.ServerState
type Setup = Shapes.Setup
type NameAndStamp = TxState.NameAndStamp
type PendingCall = TxState.PendingCall
type SentName = TxState.SentName

export type CallName = {
	read Given: NameAndStamp?,
	read Remembers: SentName?,
}

local NoName: CallName = table.freeze({ Given = nil, Remembers = nil })

local OtherTermsWarning = "the transaction name %s was used with other terms than a call this server sent "
	.. "before. A call that finds the earlier one decided answers Spent."

local RoutingFault = "Terms: this call is never made."
local DrawnNameGiven = `{RoutingFault} A Tx takes a game name or none, and Api/Validate throws on a drawn one.`
local NoFirstSendTime = `{RoutingFault} A Tx game name carries its first send time, and Api/Validate throws without it.`
local DeltaNotDeclared = `{RoutingFault} A delta leg's op kind is one its store declares.`

local function ChooseDecider(Legs: { LegForm }, Hot: number?): number
	if Hot ~= nil then
		return Hot
	end
	local GameLegs: { number } = {}
	local FirstCredit: number? = nil
	for Index, Form in Legs do
		if Form.Kind == "Game" then
			table.insert(GameLegs, Index)
		elseif FirstCredit == nil and not Form.IsDebit then
			FirstCredit = Index
		end
	end
	if #GameLegs == 1 then
		return GameLegs[1]
	end
	return FirstCredit or #Legs
end

local function ClassifyLegs(Server: ServerState, Event: TxCall): { LegForm }
	local Forms: { LegForm } = {}
	for _, Leg in Event.Legs do
		table.insert(Forms, Requests.ClassifyLeg(Leg, KindSetup.SetupOfKey(Server, Leg.Key)))
	end
	return Forms
end

local function BodyTextOf(Leg: TxLeg, Form: LegForm, Setup: Setup): string
	if Form.Kind == "Game" then
		return Json.CanonicalJson(Leg.Terms)
	end
	local Declaration = Setup.Build.BalanceOps[Leg.OpKind]
	if Declaration == nil then
		error(DeltaNotDeclared)
	end
	return Balances.ArithmeticOf(Declaration).Encode(Form.Amount)
end

local function PathTextOf(Leg: TxLeg): string?
	if Leg.Slot ~= nil then
		return Json.CanonicalJson(Leg.Slot)
	end
	return nil
end

local function LegInput(Leg: TxLeg, Form: LegForm, Setup: Setup): TxLegInput
	return {
		Store = Leg.Key.Store,
		Scope = Leg.Key.Scope,
		Key = Leg.Key.Key,
		OpKind = Leg.OpKind,
		MustExist = Leg.MustExist,
		PathCj = PathTextOf(Leg),
		BodyText = BodyTextOf(Leg, Form, Setup),
	}
end

local function InputsOf(Server: ServerState, Event: TxCall, Forms: { LegForm }): { TxLegInput }
	local Inputs: { TxLegInput } = {}
	for Index, Leg in Event.Legs do
		table.insert(Inputs, LegInput(Leg, Forms[Index], KindSetup.SetupOfKey(Server, Leg.Key)))
	end
	return Inputs
end

local function TermsDigest(Server: ServerState, Inputs: { TxLegInput }, DeciderIndex: number): buffer
	local DeciderPosition = DeciderIndex - 1
	return HashInputs.Hash(Server.Encoding, HashInputs.TxInput(Inputs, DeciderPosition))
end

local function DigestOf(Server: ServerState, Event: TxCall): buffer
	local Forms = ClassifyLegs(Server, Event)
	return TermsDigest(Server, InputsOf(Server, Event, Forms), ChooseDecider(Forms, Event.Hot))
end

local function WarnOtherTerms(Decider: StoreKey, Text: string, Commands: { Command })
	local Warn: Command = { Kind = "Warn", Key = Decider, Text = string.format(OtherTermsWarning, Text) }
	table.insert(Commands, Warn)
end

local function NameOfCall(Server: ServerState, Event: TxCall, Forms: { LegForm }, DeciderIndex: number): CallName
	local Name = Event.Name
	if Name == nil then
		return NoName
	end
	if Name.Kind == "Drawn" then
		error(DrawnNameGiven)
	end
	if Name.Stamp == nil then
		error(NoFirstSendTime)
	end
	local Digest = TermsDigest(Server, InputsOf(Server, Event, Forms), DeciderIndex)
	local Named: OpName = { Kind = "Game", Text = Name.Text, Fingerprint = HashInputs.NameFingerprint(Digest) }
	local Sent: SentName = { Text = Name.Text, Digest = buffer.tostring(Digest) }
	return { Given = { Name = Named, Stamp = Name.Stamp }, Remembers = Sent }
end

local function RememberSent(Server: ServerState, Pending: PendingCall, Commands: { Command }): boolean
	local Sent = Pending.Remembers
	if Sent == nil then
		return false
	end
	local Decider = Pending.Legs[Pending.DeciderIndex].Key
	local Result = SentNames.Remember(Server, SentNames.TxEntry(Sent.Text), Sent.Digest)
	if Result == SentNames.Remembered.OtherTerms then
		WarnOtherTerms(Decider, Sent.Text, Commands)
	end
	return Result ~= SentNames.Remembered.New
end

return {
	ChooseDecider = ChooseDecider,
	ClassifyLegs = ClassifyLegs,
	LegInput = LegInput,
	TermsDigest = TermsDigest,
	DigestOf = DigestOf,
	NameOfCall = NameOfCall,
	RememberSent = RememberSent,
}
