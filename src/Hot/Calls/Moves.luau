--!strict
--!optimize 2

--[=[
	Moves: Confirm, Release and the minted Deposit are writer ops; Deposit from a key and Withdraw are plain Txs; a
	Confirm with legs is a step Tx (hot keys sheet H8). A step's answer stays on its Tx call for Delivery. An
	unnamed Deposit goes to the home part. Final parts move only u between them.

	Return type: A plain table with the CanStart functions, the Start functions, OnConfirmOut, OnReleaseOut and
	OnConfirmTx.
	Example usage:
		if Moves.CanStartRelease(State, Call) then Moves.StartRelease(State, Call, Arrived, Clock, Commands) end
--]=]

local Composed = require("../../Composed")
local Events = require("../../Events")
local Fates = require("../../Stored/Items/Fates")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../Shapes")
local HotState = require("../State")
local InFlight = require("../../Reading/InFlight")
local JoinPartOp = require("../Part/Join").JoinPartOp
local Numbers = require("../../Writing/Numbers")
local PartBuild = require("../Part/Build")
local Replies = require("../../Replies")
local Reports = require("../Walk/Reports")
local Shapes = require("../../Shapes")
local StepAnswer = require("../../Tx/Call/StepAnswer")
local TxCalls = require("../../Tx/Call/Call")
local TxServer = require("../../Tx/Server")
local TxShapes = require("../../Tx/Shapes")
local View = require("../Walk/View")

type Answer = Events.Answer
type Command = Events.Command
type Fate = Fates.Fate
type ConfirmCall = HotShapes.ConfirmCall
type ConfirmTerms = HotShapes.ConfirmTerms
type CreditTerms = HotShapes.CreditTerms
type DepositCall = HotShapes.DepositCall
type HotCall = HotShapes.HotCall
type ReleaseCall = HotShapes.ReleaseCall
type ReleaseTerms = HotShapes.ReleaseTerms
type WithdrawCall = HotShapes.WithdrawCall
type TxLeg = TxShapes.TxLeg
type ConfirmOwner = HotState.ConfirmOwner
type ConfirmStep = HotState.ConfirmStep
type StepOwner = HotState.StepOwner
type StepOut = Shapes.StepOut
type WaitingForm = Shapes.WaitingForm
type State = Composed.State

local PartOpKind = Hot.PartOpKind
local PartReasons = Fates.PartReason

local CreditLegAt = 2

local ModuleName = "Moves"
local RoutingFault = `{ModuleName}: this call is never made.`
local NoReason = `{RoutingFault} A step that is neither took nor a part's no was answered with a reason.`
local NotUnits = `{RoutingFault} A withdrawal to a part moves units, and the API checks the amount.`
local NotAStockMove = `{RoutingFault} A final quantity's parts move only units between them, and the API refuses `
	.. "any other field."

local function CanSendTo(State: State, Call: HotCall, Part: number): boolean
	local Server = State.Server
	return Server.ServerNumber ~= nil and InFlight.CanWrite(Server, HotState.PartKeyOf(Call, Part))
end

local function PartOfDeposit(State: State, Call: DepositCall): number
	local To = Call.To
	if To.Kind == "Part" then
		return To.Index
	end
	local Server = State.Server
	return View.HomePart(Server.Encoding, Call.Quantity, Numbers.ServerNumberOf(Server))
end

local function CanStartConfirm(State: State, Call: ConfirmCall): boolean
	if #Call.Legs > 0 then
		return State.Server.ServerNumber ~= nil
	end
	return CanSendTo(State, Call, Call.Hold.Part)
end

local function CanStartRelease(State: State, Call: ReleaseCall): boolean
	return CanSendTo(State, Call, Call.Hold.Part)
end

local function CanStartDeposit(State: State, Call: DepositCall): boolean
	if State.Server.ServerNumber == nil then
		return false
	end
	if Call.IsMinted then
		return CanSendTo(State, Call, PartOfDeposit(State, Call))
	end
	return true
end

local function CanStartWithdraw(State: State): boolean
	return State.Server.ServerNumber ~= nil
end

local function FingerprintOf(State: State, Call: HotCall): number
	return PartBuild.FingerprintOf(State.Server.Encoding, Call.Quantity)
end

local function ConfirmAnswerOf(Call: ConfirmCall, Fate: Fate): Answer?
	if Fate.Kind == "Took" or Fate.Kind == "TookWith" then
		return Reports.TookAnswer(Call.Hold.Part, Fate)
	end
	if Fate.Kind == "RefusedFor" and Fate.Reason == PartReasons.Gone then
		return Reports.ShortAnswerOf(PartReasons.Gone)
	end
	return nil
end

local function StartConfirm(State: State, Call: ConfirmCall, Arrived: number, Clock: number, Commands: { Command })
	local Terms: ConfirmTerms = {
		Fingerprint = FingerprintOf(State, Call),
		Id = Call.Hold.Id,
		Count = Call.Hold.Count,
		Price = Call.Price,
	}
	local Confirming = PartBuild.PartLeg(Call, Call.Hold.Part, PartOpKind.Confirm, Terms)
	if #Call.Legs > 0 then
		HotState.AddTxStep(State.Hot, Call.CallId, { Kind = "Confirm", Call = Call })
		return TxCalls.BeginStep(State, PartBuild.PartTx(Call.CallId, Confirming, Call.Legs), Arrived, Clock, Commands)
	end
	local Form: WaitingForm = { Kind = "Timed", Name = Numbers.DrawnName(State.Server), Stamp = Clock }
	local Op = PartBuild.NewStepOp(Form, PartOpKind.Confirm, Terms, Call.CallId, Arrived)
	HotState.AddStepOwner(State.Hot, Call.CallId, { Kind = "Confirm", Call = Call })
	JoinPartOp(State, Confirming.Key, Op, Call.Fraction, Clock, Commands)
end

local function StartRelease(State: State, Call: ReleaseCall, Arrived: number, Clock: number, Commands: { Command })
	local Terms: ReleaseTerms = { Fingerprint = FingerprintOf(State, Call), Id = Call.Hold.Id }
	local Key = HotState.PartKeyOf(Call, Call.Hold.Part)
	local Op = PartBuild.NewStepOp({ Kind = "Minted" }, PartOpKind.Release, Terms, Call.CallId, Arrived)
	HotState.AddStepOwner(State.Hot, Call.CallId, { Kind = "Release" })
	JoinPartOp(State, Key, Op, Call.Fraction, Clock, Commands)
end

local function StartDeposit(State: State, Call: DepositCall, Arrived: number, Clock: number, Commands: { Command })
	local Part = PartOfDeposit(State, Call)
	local Terms: CreditTerms = { Fingerprint = FingerprintOf(State, Call), Count = Call.Count }
	if not Call.IsMinted then
		local Legs: { TxLeg } = { Call.From, PartBuild.CreditLeg(Call, Part, Terms) }
		return TxServer.OnCall(State, PartBuild.TxOf(Call.CallId, Legs, CreditLegAt), Arrived, Clock, Commands)
	end
	local Key = HotState.PartKeyOf(Call, Part)
	local Op = PartBuild.NewCallOp({ Kind = "Minted" }, PartOpKind.Credit, Terms, Call.CallId, Arrived)
	JoinPartOp(State, Key, Op, Call.Fraction, Clock, Commands)
end

local function StartWithdraw(State: State, Call: WithdrawCall, Arrived: number, Clock: number, Commands: { Command })
	local Debit = PartBuild.DebitLeg(Call, Call.Part, Call.Field, Call.Amount)
	local To = Call.To
	if To.Kind == "Key" then
		return TxServer.OnCall(State, PartBuild.RuledTxOf(Call.CallId, { Debit, To.Credit }), Arrived, Clock, Commands)
	end
	if Call.Quantity.Mode == Hot.Mode.Final and Call.Field ~= Hot.FreeField then
		error(NotAStockMove)
	end
	local Count = Call.Amount
	if type(Count) ~= "number" then
		error(NotUnits)
	end
	local Terms: CreditTerms = { Fingerprint = FingerprintOf(State, Call), Count = Count }
	local Legs: { TxLeg } = { Debit, PartBuild.CreditLeg(Call, To.Index, Terms) }
	TxServer.OnCall(State, PartBuild.TxOf(Call.CallId, Legs, CreditLegAt), Arrived, Clock, Commands)
end

local function OnConfirmOut(State: State, Owner: ConfirmOwner, Out: StepOut, _Clock: number, Commands: { Command })
	State.Hot.StepOwners[Out.CallId] = nil
	local Given: Answer? = nil
	if Out.Kind == "Heard" and Out.Report.Kind == "Fated" then
		Given = ConfirmAnswerOf(Owner.Call, Out.Report.Fate)
	end
	if Given ~= nil then
		return Replies.Reply(Commands, Out.CallId, Given)
	end
	if Out.Reason == nil then
		error(NoReason)
	end
	Replies.ReplyFailed(Commands, Out.CallId, Out.Reason)
end

local function OnReleaseOut(State: State, _Owner: StepOwner, Out: StepOut, _Clock: number, Commands: { Command })
	State.Hot.StepOwners[Out.CallId] = nil
	if Out.Reason ~= nil then
		return Replies.ReplyFailed(Commands, Out.CallId, Out.Reason)
	end
	Replies.Reply(Commands, Out.CallId, { Kind = "Succeeded", Value = true })
end

local function FateOfTaken(Taken: StepAnswer.StepAnswer): Fate?
	if Taken.Given.Kind ~= "Succeeded" then
		return Taken.DeciderFate
	end
	if Taken.DeciderValue ~= nil then
		return { Kind = "TookWith", Value = Taken.DeciderValue }
	end
	return { Kind = "Took" }
end

local function OnConfirmTx(CallId: number, Step: ConfirmStep, Taken: StepAnswer.StepAnswer, Commands: { Command })
	local Fate = FateOfTaken(Taken)
	if Fate ~= nil then
		local Given = ConfirmAnswerOf(Step.Call, Fate)
		if Given ~= nil then
			return Replies.Reply(Commands, CallId, Given)
		end
	end
	Replies.Reply(Commands, CallId, Taken.Given)
end

return {
	CanStartConfirm = CanStartConfirm,
	CanStartRelease = CanStartRelease,
	CanStartDeposit = CanStartDeposit,
	CanStartWithdraw = CanStartWithdraw,
	StartConfirm = StartConfirm,
	StartRelease = StartRelease,
	StartDeposit = StartDeposit,
	StartWithdraw = StartWithdraw,
	OnConfirmOut = OnConfirmOut,
	OnReleaseOut = OnReleaseOut,
	OnConfirmTx = OnConfirmTx,
}
