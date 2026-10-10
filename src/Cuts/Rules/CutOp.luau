--!strict
--!optimize 2

--[=[
	CutOp: the cut op in step (cuts sheets 3, 4): missing, kept, own gate, forgotten, behind, ahead, then Gate and
	Cut; a stop leaves later ops Undecided, a seal Missing (K.1). A legacy tag runs on its record, so an erase ends a
	legacy key, at most once only when no Erasable = false build runs: meeting one warns.

	Return type: A plain table with JudgeCuts.
	Example usage:
		CutOp.JudgeCuts(Run)
--]=]

local Cut = require("./Cut")
local CutShapes = require("../Shapes")
local Entries = require("../../Stored/Entries")
local Gate = require("./Gate")
local Judge = require("../../Judging/Judge")
local JudgingRun = require("../../Judging/Run")
local JudgingShapes = require("../../Judging/Shapes")
local Lookup = require("../../Stored/Lookup")
local SealedKey = require("./SealedKey")
local Shapes = require("../../Shapes")
local Timed = require("../../Stored/Items/Timed")

type CutKind = Timed.CutKind
type CutForm = CutShapes.CutForm
type NoteWarning = JudgingShapes.NoteWarning
type Report = JudgingShapes.Report
type Run = JudgingRun.Run
type SentOp = Shapes.SentOp

local ModuleName = "CutOp"
local NotACut = `{ModuleName}: a request of cut ops holds only cut ops. The caller must not mix in another form`

local FingerprintOf = Entries.FingerprintOf
local IsSameName = Lookup.IsSameName
local IsOtherIncarnation = Judge.IsOtherIncarnation
local StopWith = Judge.StopWith
local MissingWithSeal = SealedKey.MissingWithSeal

local function IsSameCut(Kind: CutKind, Fingerprint: number?, Other: CutKind, OtherFingerprint: number?): boolean
	return Kind == Other and Fingerprint == OtherFingerprint
end

local function KeptReport(Run: Run, Form: CutForm): Report?
	for _, Kept in Run.Book.CutNames do
		if not IsSameName(Kept.Name, Form.Name) then
			continue
		end
		if IsSameCut(Form.CutKind, FingerprintOf(Form.Name), Kept.Kind, Kept.Fingerprint) then
			return { Kind = "Took" }
		end
		return { Kind = "Spent" }
	end
	return nil
end

local function OwnGate(Run: Run, Form: CutForm): (Report?, boolean)
	local Held = Run.Book.Gate
	if Held == nil or not IsSameName(Held.Name, Form.Name) then
		return nil, false
	end
	if IsSameCut(Form.CutKind, FingerprintOf(Form.Name), Held.Kind, Held.Fingerprint) then
		return nil, true
	end
	return { Kind = "Spent" }, false
end

local function IsCutForgotten(Run: Run, Op: SentOp, IsOwn: boolean): boolean
	return not IsOwn and Op.Stamp <= Run.Book.CutHorizon
end

local function IsCutBehind(Run: Run): boolean
	local Build = Run.Setup.Build
	return Run.Book.Floor > Build.BreakingIndex or Run.Book.Level > Build.MigrationCount
end

local function IsCutAhead(Run: Run, Op: SentOp, IsOwn: boolean): boolean
	return not IsOwn and Op.Stamp > math.max(Run.Clock, Run.Book.CutHorizon) + Run.Setup.Limits.Ahead
end

local function JudgeRules(Run: Run, Op: SentOp, Form: CutForm): Report
	local Kept = KeptReport(Run, Form)
	if Kept ~= nil then
		return Kept
	end
	local Spent, IsOwn = OwnGate(Run, Form)
	if Spent ~= nil then
		return Spent
	end
	if IsCutForgotten(Run, Op, IsOwn) then
		return StopWith(Run, { Kind = "Forgotten" })
	end
	if IsCutBehind(Run) then
		return StopWith(Run, { Kind = "Behind" })
	end
	if IsCutAhead(Run, Op, IsOwn) then
		return StopWith(Run, { Kind = "Ahead" })
	end
	if not IsOwn then
		local Gated = Gate.GatedReport(Run, Form)
		if Gated ~= nil then
			return StopWith(Run, Gated)
		end
	end
	local Marked = Gate.PlaceGateForMarks(Run, Op, Form)
	if Marked ~= nil then
		return StopWith(Run, Marked)
	end
	local Cutting = Cut.CutKey(Run, Op, Form)
	if Cutting.Kind == "Took" or Cutting.Kind == "Sealed" then
		return Cutting
	end
	return StopWith(Run, Cutting)
end

local function IsLegacyRecord(Run: Run): boolean
	return Run.Setup.IsErasable and Run.Book.Identity == nil
end

local function NoteLegacyRecord(Run: Run)
	if not IsLegacyRecord(Run) then
		return
	end
	local Warning: NoteWarning = { Kind = "WrittenBeforeErasable" }
	table.insert(Run.Warnings, Warning)
end

local function JudgeCut(Run: Run, Op: SentOp, Form: CutForm): Report
	if IsOtherIncarnation(Run.Book, Op.Incarnation) then
		local Identity = Run.Book.Identity
		return StopWith(
			Run,
			{ Kind = "Missing", Identity = Identity, Seal = nil, IsLeftOver = false, IsLegacy = Identity == nil }
		)
	end
	return JudgeRules(Run, Op, Form)
end

local function JudgeCuts(Run: Run)
	NoteLegacyRecord(Run)
	for _, Op in Run.Request.Ops do
		local Sealed = Run.Sealed
		if Sealed ~= nil then
			table.insert(Run.Reports, MissingWithSeal(Sealed, false))
			continue
		end
		if Run.IsStopped then
			local Undecided: Report = { Kind = "Undecided" }
			table.insert(Run.Reports, Undecided)
			continue
		end
		local Form = Op.Form
		if Form.Kind ~= "Cut" then
			error(NotACut)
		end
		table.insert(Run.Reports, JudgeCut(Run, Op, Form))
	end
end

return {
	JudgeCuts = JudgeCuts,
}
