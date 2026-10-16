--!strict
--!optimize 2

--[=[
	Decide: the step of J.9 for one op on any state: the new state, or why not.

	Balances judges a balance op kind: an unreadable escrow amount is Unreadable, a stored balance field the
	arithmetic rejects is InvalidBalance (refused in a write, Invalid at Apply). PartOps judges a part's kinds;
	a kind its reducer gives no state for is Invalid.

	Return type: A plain table with DecideOnState, NoMarks, UsesClock, IsPartRule, JudgedOf, StopOf, FateOf and
	BalanceAmountOf.
	Example usage:
		local Terms = { Kind = "SpendGold", Amount = 50 }
		local Verdict = Decide.DecideOnState(Setup, State, Terms.Kind, Terms, Decide.NoMarks, Clock)
		if Verdict.Kind == "Took" then ... end
--]=]

local Balances = require("../Tx/Legs/Balances")
local Fates = require("../Stored/Items/Fates")
local Guards = require("./Guards")
local Json = require("../Encoding/Json")
local JudgingShapes = require("./Shapes")
local PartOps = require("../Hot/Part/Ops")
local Record = require("../Constants/Record")
local Shapes = require("../Shapes")
local Verdicts = require("./Verdicts")
local Work = require("../Stored/Items/Work")

type EscrowMark = Work.EscrowMark
type Declaration = Balances.Declaration
type Arithmetic = Balances.Arithmetic
type Setup = Shapes.Setup
type Verdict = JudgingShapes.Verdict
type Judged = JudgingShapes.Judged
type Fate = Fates.Fate
type Report = JudgingShapes.Report

local PartKind = Record.KeyKind.Part

local NoMarks: { EscrowMark } = {}
table.freeze(NoMarks)

local ModuleName = "Decide"
local TermsNotATable =
	`{ModuleName}: a balance op's terms are a table with an Amount. The API checks them before the core decides`

local NoFate = `{ModuleName}: a judgement that stops has no fate. The caller must ask StopOf first`

local function BalanceAmountOf(Terms: unknown): unknown
	if type(Terms) ~= "table" then
		error(TermsNotATable)
	end
	return (Terms :: { [unknown]: unknown }).Amount
end

local function DecideBalanceOp(
	Setup: Setup,
	State: { [unknown]: unknown },
	Declaration: Declaration,
	Terms: unknown,
	Marks: { EscrowMark }
): Verdict
	local Amount = BalanceAmountOf(Terms)
	local BalanceVerdict = Balances.Judge(State, Marks, Declaration, Amount)
	if BalanceVerdict == Balances.Verdict.Unreadable then
		return Verdicts.Unreadable
	end
	if BalanceVerdict == Balances.Verdict.Invalid then
		return Verdicts.Invalid
	end
	if BalanceVerdict == Balances.Verdict.InvalidBalance then
		return Verdicts.InvalidBalance
	end
	if BalanceVerdict == Balances.Verdict.Refused then
		return Verdicts.Refused
	end
	local Arithmetic = Balances.ArithmeticOf(Declaration)
	local Settled = Balances.SettleValue(State, Declaration.Field, Amount, Declaration.Direction, Arithmetic)
	if Json.Size(Settled) > Setup.Limits.StateCap then
		return Verdicts.Full
	end
	return { Kind = "Took", State = Settled }
end

local function DecideOnState(
	Setup: Setup,
	State: { [unknown]: unknown },
	OpKind: string,
	Terms: unknown,
	Marks: { EscrowMark },
	Clock: number
): Verdict
	local Build = Setup.Build
	local Limits = Setup.Limits
	local Declaration = Build.BalanceOps[OpKind]
	if Declaration ~= nil then
		return DecideBalanceOp(Setup, State, Declaration, Terms, Marks)
	end
	if Build.KeyKind == PartKind and PartOps.Judges(OpKind) then
		return PartOps.Decide(Setup, State, OpKind, Terms, Marks, Clock)
	end
	local Declared, Undeclared = Guards.SplitUndeclared(State, Build.Declared)
	local Outcome = Guards.RunReducer(Build.Reducer, Declared, Terms, Limits)
	if Outcome.Kind == "NoState" then
		if Build.KeyKind == PartKind then
			return Verdicts.Invalid
		end
		return Verdicts.NoState
	end
	if Outcome.Kind == "Unstorable" then
		return Verdicts.Unstorable
	end
	if Outcome.Kind ~= "State" then
		return Verdicts.Refused
	end
	if Guards.AddsUndeclared(Outcome.State, Build.Declared) then
		return Verdicts.Refused
	end
	if Balances.HoldsInvalidBalance(Outcome.State, Build.Balances) then
		return Verdicts.Refused
	end
	local Whole = Guards.PutBack(Outcome.State, Undeclared)
	if Json.Size(Whole) > Limits.StateCap then
		return Verdicts.Full
	end
	return { Kind = "Took", State = Whole }
end

local function UsesClock(Setup: Setup, OpKind: string): boolean
	return Setup.Build.KeyKind == PartKind and PartOps.UsesClock(OpKind)
end

local function IsPartRule(Setup: Setup, OpKind: string): boolean
	return Setup.Build.KeyKind == PartKind and PartOps.Judges(OpKind)
end

local function JudgedOf(Verdict: Verdict): Judged
	if Verdict.Kind == "Took" then
		return { Kind = "Took" }
	end
	if Verdict.Kind == "TookWith" then
		return { Kind = "TookWith", Value = Verdict.Value }
	end
	if Verdict.Kind == "RefusedFor" then
		return { Kind = "RefusedFor", Reason = Verdict.Reason }
	end
	if Verdict.Kind == "Full" then
		return { Kind = "Full" }
	end
	if Verdict.Kind == "Unreadable" then
		return { Kind = "Unreadable" }
	end
	if Verdict.Kind == "Invalid" then
		return { Kind = "Invalid" }
	end
	return { Kind = "Refused" }
end

local function StopOf(Outcome: { read Kind: string }): Report?
	if Outcome.Kind == "Unreadable" then
		return { Kind = "Unreadable", Cause = "Amounts" }
	end
	if Outcome.Kind == "Invalid" then
		return { Kind = "Invalid" }
	end
	return nil
end

local function FateOf(Judged: Judged): Fate
	if Judged.Kind == "Unreadable" or Judged.Kind == "Invalid" then
		error(NoFate)
	end
	return Judged
end

return {
	NoMarks = NoMarks,
	UsesClock = UsesClock,
	IsPartRule = IsPartRule,
	DecideOnState = DecideOnState,
	JudgedOf = JudgedOf,
	StopOf = StopOf,
	FateOf = FateOf,
	BalanceAmountOf = BalanceAmountOf,
}
