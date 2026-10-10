--!strict
--!optimize 2

--[=[
	Ops: the part's ops judged (hot keys sheet H4 steps 1 and 3, H5). An open makes a part or changes nothing. Any
	other op meets the fp check, then its own rule. A hold ends at the run's clock plus its duration. A settled state
	past its limits is Unreadable, never encoded.

	Return type: A plain table with IsOpenRequest, JudgeOpen, OpenedReport, Judges, UsesClock and Decide.
	Example usage:
		local Verdict = PartOps.Decide(Setup, State, "Take", Terms, Escrows, Clock)
--]=]

local Balances = require("../../Tx/Legs/Balances")
local Fates = require("../../Stored/Items/Fates")
local HoldOps = require("./HoldOps")
local Holds = require("./Holds")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../Shapes")
local JudgingRun = require("../../Judging/Run")
local JudgingShapes = require("../../Judging/Shapes")
local Part = require("../../Stored/Items/Part")
local PartBuild = require("./Build")
local Settle = require("./Settle")
local Shapes = require("../../Shapes")
local VarintLimit = require("../../Constants/Record").VarintLimit
local Verdicts = require("../../Judging/Verdicts")
local Work = require("../../Stored/Items/Work")

type Declaration = Balances.Declaration
type PartReason = Fates.PartReason
type PartRecord = Part.PartRecord
type EscrowMark = Work.EscrowMark
type OpenTerms = HotShapes.OpenTerms
type TakeTerms = HotShapes.TakeTerms
type CreditTerms = HotShapes.CreditTerms
type CloseTerms = HotShapes.CloseTerms
type Setup = Shapes.Setup
type Request = Shapes.Request
type Report = JudgingShapes.Report
type Run = JudgingRun.Run
type Verdict = JudgingShapes.Verdict

type Fields = { [unknown]: unknown }
type Fingerprinted = { read Fingerprint: number? }
type Handler = (
	Setup: Setup,
	State: Fields,
	Record: PartRecord,
	Terms: unknown,
	Escrows: { EscrowMark },
	Clock: number
) -> Verdict

local RecordOf = Part.RecordOf
local FreeOf = Part.FreeOf
local DefaultArithmetic = Balances.DefaultArithmetic
local Direction = Balances.Direction
local PartOpKind = Hot.PartOpKind
local FreeField = Hot.FreeField
local PartRecordKey = Hot.PartRecordKey
local RefusedFor = Settle.RefusedFor

local PartReasons = Fates.PartReason

local FreeCredit: Declaration = table.freeze({ Field = FreeField, Direction = Direction.Credit })

local ModuleName = "Ops"
local TermsNotATable = `{ModuleName}: a part op's terms are a table. The API builds them before the core decides`
local NotJudged = `{ModuleName}: only an op kind Judges names is decided here. The caller must ask Judges first`

local function OpenedReport(): Report
	return { Kind = "Fated", Fate = { Kind = "Took" }, State = nil }
end

local function Take(Setup: Setup, State: Fields, Record: PartRecord, Terms: TakeTerms, Escrows: { EscrowMark }): Verdict
	local Refusal = Settle.TakeRefusal(State, Record, Escrows, Terms.Count)
	if Refusal ~= nil then
		return Refusal
	end
	return Settle.Taken(Setup.Build.Balances, State, Record, Terms)
end

local function Credit(
	Setup: Setup,
	State: Fields,
	Record: PartRecord,
	Terms: CreditTerms,
	Escrows: { EscrowMark }
): Verdict
	if Record.IsClosed or Record.IsSealed then
		return RefusedFor(PartReasons.Sealed)
	end
	local Allowance = Balances.Judge(State, Escrows, FreeCredit, Terms.Count)
	if Allowance == Balances.Verdict.Unreadable then
		return Verdicts.Unreadable
	end
	if Allowance == Balances.Verdict.Invalid or Allowance == Balances.Verdict.InvalidBalance then
		return Verdicts.Invalid
	end
	if Allowance == Balances.Verdict.Refused then
		return Verdicts.Refused
	end
	if FreeOf(State) + Holds.HeldUnits(Record) + Terms.Count >= VarintLimit then
		return Verdicts.Refused
	end
	local Credited = Balances.SettleValue(State, FreeField, Terms.Count, Direction.Credit, DefaultArithmetic)
	return Settle.Settling(Setup.Build.Balances, Credited, Record)
end

local function Close(
	_Setup: Setup,
	State: Fields,
	Record: PartRecord,
	_Terms: CloseTerms,
	_Escrows: { EscrowMark }
): Verdict
	local Closed = table.clone(Record)
	Closed.IsClosed = true
	local Shut = table.clone(State)
	Shut[PartRecordKey] = Closed
	return { Kind = "Took", State = Shut }
end

local JudgeBy = {
	[PartOpKind.Take] = Take,
	[PartOpKind.Credit] = Credit,
	[PartOpKind.Close] = Close,
	[PartOpKind.Hold] = HoldOps.Hold,
	[PartOpKind.Confirm] = HoldOps.Confirm,
	[PartOpKind.Release] = HoldOps.Release,
}

local function IsOpenRequest(Request: Request): boolean
	if Request.Kind ~= "Update" or #Request.Ops ~= 1 then
		return false
	end
	return Request.Ops[1].OpKind == PartOpKind.Open
end

local function OpenTermsOf(Terms: unknown): OpenTerms
	if type(Terms) ~= "table" then
		error(TermsNotATable)
	end
	return Terms :: OpenTerms
end

local function JudgeOpen(Run: Run)
	local Opening = Run.Request.Ops[1]
	Run.State = PartBuild.NewPart(OpenTermsOf(Opening.Terms))
	table.insert(Run.Decided, Opening)
	table.insert(Run.Reports, OpenedReport())
end

local function Judges(OpKind: string): boolean
	return (JudgeBy :: { [string]: Handler })[OpKind] ~= nil
end

local function UsesClock(OpKind: string): boolean
	return OpKind == PartOpKind.Hold
end

local function Decide(
	Setup: Setup,
	State: Fields,
	OpKind: string,
	Terms: unknown,
	Escrows: { EscrowMark },
	Clock: number
): Verdict
	local Rule = (JudgeBy :: { [string]: Handler })[OpKind]
	if Rule == nil then
		error(NotJudged)
	end
	if type(Terms) ~= "table" then
		error(TermsNotATable)
	end
	local Record = RecordOf(State)
	if (Terms :: Fingerprinted).Fingerprint ~= Record.Fingerprint then
		return Verdicts.Invalid
	end
	return Rule(Setup, State, Record, Terms, Escrows, Clock)
end

return {
	IsOpenRequest = IsOpenRequest,
	JudgeOpen = JudgeOpen,
	OpenedReport = OpenedReport,
	Judges = Judges,
	UsesClock = UsesClock,
	Decide = Decide,
}
