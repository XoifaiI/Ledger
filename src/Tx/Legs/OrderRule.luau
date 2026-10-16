--!strict
--!optimize 2

--[=[
	OrderRule: how a write other than a leg's own mark is judged beside the marks of P (transaction sheet 13),
	and every write's migration block (sheet 8 rule 5a).

	Escrow marks never stop a balance or part op. Others run the commute check, up to GameOpMarksMost marks; all
	runs refusing refuse it, by the rules unless all by the cap.

	Return type: A plain table with JudgeOrder, JudgeBesideEscrow and MigrationBlocks, and the EscrowJudgement type.
	Example usage:
		local Stopping = OrderRule.JudgeOrder(Run, Op)
		if Stopping ~= nil then
			return Stopping
		end
--]=]

local Balances = require("./Balances")
local Decide = require("../../Judging/Decide")
local Guards = require("../../Judging/Guards")
local JudgingRun = require("../../Judging/Run")
local JudgingShapes = require("../../Judging/Shapes")
local Marks = require("./Marks")
local Shapes = require("../../Shapes")
local Work = require("../../Stored/Items/Work")

type State = { [unknown]: unknown }
type Outcome = Guards.Outcome<State>
type EscrowMark = Work.EscrowMark
type Mark = Work.Mark
type Report = JudgingShapes.Report
type Run = JudgingRun.Run
type SentOp = Shapes.SentOp
type Setup = Shapes.Setup
type Verdict = JudgingShapes.Verdict

export type EscrowJudgement =
	{ read Kind: "Stopped", read Report: Report }
	| { read Kind: "AsOnState" }
	| { read Kind: "RefusedByRules" }

local Direction = Balances.Direction

local UnreadableAmountReport: Report =
	table.freeze({ Kind = "Unreadable" :: "Unreadable", Cause = "Amounts" :: "Amounts" })
local UnreadableAmounts: EscrowJudgement =
	table.freeze({ Kind = "Stopped" :: "Stopped", Report = UnreadableAmountReport })
local AsOnState: EscrowJudgement = table.freeze({ Kind = "AsOnState" :: "AsOnState" })
local RefusedByRules: EscrowJudgement = table.freeze({ Kind = "RefusedByRules" :: "RefusedByRules" })

local function ReadEscrowAmounts(Escrows: { EscrowMark }, Setup: Setup): { unknown } | "Unreadable"
	local EscrowAmounts: { unknown } = {}
	for _, Escrow in Escrows do
		local Arithmetic = Setup.Build.Balances[Escrow.Field]
		if Arithmetic == nil then
			return Balances.Verdict.Unreadable
		end
		local Amount = Balances.FromStored(Escrow.Amount, Arithmetic)
		if Amount == nil then
			return Balances.Verdict.Unreadable
		end
		table.insert(EscrowAmounts, Amount)
	end
	return EscrowAmounts
end

local function HoldsReadableBalances(Base: State, Escrows: { EscrowMark }, Setup: Setup): boolean
	for _, Escrow in Escrows do
		local Arithmetic = Setup.Build.Balances[Escrow.Field]
		if Balances.ReadBalance(Base, Escrow.Field, Arithmetic) == nil then
			return false
		end
	end
	return true
end

local function SettleSubset(
	Base: State,
	Escrows: { EscrowMark },
	EscrowAmounts: { unknown },
	Mask: number,
	Setup: Setup
): State
	local Settled = Base
	for Index, Escrow in Escrows do
		if not bit32.btest(Mask, bit32.lshift(1, Index - 1)) then
			continue
		end
		local AmountDirection = if Escrow.IsDebit then Direction.Debit else Direction.Credit
		local Arithmetic = Setup.Build.Balances[Escrow.Field]
		Settled = Balances.SettleValue(Settled, Escrow.Field, EscrowAmounts[Index], AmountDirection, Arithmetic)
	end
	return Settled
end

local function IsSameState(Left: State, Right: State): boolean
	local LeftOutcome: Outcome = { Kind = "State", State = Left }
	local RightOutcome: Outcome = { Kind = "State", State = Right }
	return Guards.CompareRuns(LeftOutcome, RightOutcome) == nil
end

local function EscrowBlocked(Escrows: { EscrowMark }, Setup: Setup): EscrowJudgement
	local Blockers: { Mark } = {}
	for _, Escrow in Escrows do
		table.insert(Blockers, Escrow)
	end
	return { Kind = "Stopped", Report = Marks.BlockedReport(Blockers, Setup.Limits) }
end

local function Takes(Verdict: Verdict): boolean
	return Verdict.Kind == "Took" or Verdict.Kind == "TookWith"
end

local function JudgeBesideEscrow(
	Setup: Setup,
	Base: State,
	Escrows: { EscrowMark },
	OpKind: string,
	Terms: unknown,
	Clock: number
): EscrowJudgement
	if #Escrows > Setup.Limits.GameOpMarksMost then
		return EscrowBlocked(Escrows, Setup)
	end
	local EscrowAmounts = ReadEscrowAmounts(Escrows, Setup)
	if EscrowAmounts == "Unreadable" or not HoldsReadableBalances(Base, Escrows, Setup) then
		return UnreadableAmounts
	end

	local First = Decide.DecideOnState(Setup, Base, OpKind, Terms, Decide.NoMarks, Clock)
	local FirstKind = Decide.JudgedOf(First).Kind
	local FirstTakes = Takes(First)
	local HasOtherRefusal = false
	for Mask = 1, 2 ^ #Escrows - 1 do
		local Settled = SettleSubset(Base, Escrows, EscrowAmounts, Mask, Setup)
		local Verdict = Decide.DecideOnState(Setup, Settled, OpKind, Terms, Decide.NoMarks, Clock)
		if Takes(Verdict) ~= FirstTakes then
			return EscrowBlocked(Escrows, Setup)
		end
		if Decide.JudgedOf(Verdict).Kind ~= FirstKind then
			if FirstTakes then
				return EscrowBlocked(Escrows, Setup)
			end
			HasOtherRefusal = true
		end
		if First.Kind == "Took" and Verdict.Kind == "Took" then
			local Expected = SettleSubset(First.State, Escrows, EscrowAmounts, Mask, Setup)
			if not IsSameState(Expected, Verdict.State) then
				return EscrowBlocked(Escrows, Setup)
			end
		end
	end
	if HasOtherRefusal then
		return RefusedByRules
	end
	return AsOnState
end

local function JudgeOrder(Run: Run, Op: SentOp): Report?
	local Exclusive = Marks.ExclusiveOf(Run.Book)
	if Exclusive ~= nil then
		return Marks.BlockedReport({ Exclusive }, Run.Setup.Limits)
	end
	local Escrows = Marks.EscrowMarksOf(Run.Book.Work)
	if #Escrows == 0 then
		return nil
	end
	if Run.Setup.Build.BalanceOps[Op.OpKind] ~= nil or Decide.IsPartRule(Run.Setup, Op.OpKind) then
		return nil
	end
	local Judgement = JudgeBesideEscrow(Run.Setup, Run.State, Escrows, Op.OpKind, Op.Terms, Run.Clock)
	if Judgement.Kind == "Stopped" then
		return Judgement.Report
	end
	return nil
end

local function MigrationBlocks(Run: Run): Report?
	if Run.Book.Level >= Run.Setup.Build.MigrationCount then
		return nil
	end
	local Standing = Marks.MarksIn(Run.Book)
	if #Standing == 0 then
		return nil
	end
	return Marks.BlockedReport(Standing, Run.Setup.Limits)
end

return {
	JudgeOrder = JudgeOrder,
	JudgeBesideEscrow = JudgeBesideEscrow,
	MigrationBlocks = MigrationBlocks,
}
