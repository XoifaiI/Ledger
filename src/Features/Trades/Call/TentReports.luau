--!strict
--!optimize 2

--[=[
	TentReports: what the reports of a Tx call's Tents say, read over its other keys in leg order: the first refusal,
	with its leg and state, missing leg, fence, behind, forgotten or gated report, the keys that hold the call up, and a
	key whose Tent erred past RetryRounds (transaction sheet 15.1). A Behind names its leg, else the decider. A sweep
	report is one a game named step answers Spent for, once the later parts are fenced. A refusal's answer names its
	leg and state, Refused or Full by its fate.

	Return type: A plain table of functions, and the MissingLeg and Refusal types.
	Example usage:
		local Missing = TentReports.FirstMissingLeg(Call)
--]=]

local Book = require("../../../Keys/Format/Book")
local Events = require("../../../Shared/Events")
local Fates = require("../../../Keys/Format/Items/Fates")
local JudgingShapes = require("../../../Shared/OpShapes")
local Names = require("../../../Keys/Encoding/Names")
local NextSteps = require("./NextSteps")
local Reasons = require("../../../Keys/Constants/Reasons")
local TxState = require("../State")

type GivenAnswer = Events.Answer
type Reason = Reasons.Reason
type Fate = Fates.Fate
type Identity = Book.Identity
type StoreKey = Names.StoreKey
type EndWorkReport = JudgingShapes.EndWorkReport
type Report = JudgingShapes.Report
type Call = TxState.Call
type BlockedKey = NextSteps.BlockedKey

export type MissingLeg = { read Key: StoreKey, read Identity: Identity? }

export type Refusal = { read Key: StoreKey, read Fate: Fate, read State: unknown }

local function EndWorkOf(Report: Report): EndWorkReport?
	if Report.Kind == "Blocked" or Report.Kind == "NoRoom" or Report.Kind == "Overdue" then
		return Report
	end
	return nil
end

local function RefusalFate(Report: Report): Fate?
	if Report.Kind == "Refused" then
		return Report.Fate
	end
	if Report.Kind == "Decided" and (Report.Fate.Kind == "Refused" or Report.Fate.Kind == "Full") then
		return Report.Fate
	end
	return nil
end

local function IsServedReport(Report: Report): boolean
	return Report.Kind == "Served"
end

local function IsSweepReport(Report: Report): boolean
	if Report.Kind == "Other" or Report.Kind == "Large" then
		return true
	end
	return Report.Kind == "Decided" and (Report.Fate.Kind == "Took" or Report.Fate.Kind == "TookWith")
end

local function IsSupersededReport(Report: Report): boolean
	return Report.Kind == "Superseded"
end

local function IsAbortedReport(Report: Report): boolean
	return Report.Kind == "Decided" and Report.Fate.Kind == "Aborted"
end

local function EndsInFence(Report: Report): boolean
	return IsSweepReport(Report) or IsSupersededReport(Report) or IsAbortedReport(Report)
end

local function IsBehindReport(Report: Report): boolean
	return Report.Kind == "Behind"
end

local function IsForgottenReport(Report: Report): boolean
	return Report.Kind == "Forgotten"
end

local function IsGatedReport(Report: Report): boolean
	return Report.Kind == "Gated"
end

local function IsSentAgainReport(Report: Report): boolean
	return Report.Kind == "Ahead" or Report.Kind == "Undecided"
end

local function FirstWhere(Call: Call, Test: (Report: Report) -> boolean): Report?
	for _, Key in Call.OtherKeys do
		local Report = Call.TentReports[Names.KeyText(Key)]
		if Report ~= nil and Test(Report) then
			return Report
		end
	end
	return nil
end

local function HasErredKey(Call: Call): boolean
	for _, Key in Call.OtherKeys do
		local Text = Names.KeyText(Key)
		if not Call.Mine[Text] and Call.TentReports[Text] == nil then
			return true
		end
	end
	return false
end

local function FirstMissingLeg(Call: Call): MissingLeg?
	for _, Key in Call.OtherKeys do
		local Report = Call.TentReports[Names.KeyText(Key)]
		if Report ~= nil and Report.Kind == "Missing" then
			return { Key = Key, Identity = Report.Identity }
		end
	end
	return nil
end

local function FirstRefusal(Call: Call): Refusal?
	for _, Key in Call.OtherKeys do
		local Report = Call.TentReports[Names.KeyText(Key)]
		local Fate = if Report == nil then nil else RefusalFate(Report)
		if Report ~= nil and Fate ~= nil then
			return { Key = Key, Fate = Fate, State = if Report.Kind == "Refused" then Report.State else nil }
		end
	end
	return nil
end

local function ReasonOfFate(Fate: Fate): Reason
	if Fate.Kind == "Full" then
		return Reasons.Full
	end
	return Reasons.Refused
end

local function RefusalAnswer(Refusal: Refusal): GivenAnswer
	return { Kind = "Failed", Reason = ReasonOfFate(Refusal.Fate), State = Refusal.State, Key = Refusal.Key }
end

local function BehindLeg(Call: Call): StoreKey
	for _, Key in Call.OtherKeys do
		local Report = Call.TentReports[Names.KeyText(Key)]
		if Report ~= nil and IsBehindReport(Report) then
			return Key
		end
	end
	return Call.Decider
end

local function BlockedTents(Call: Call): { BlockedKey }
	local Held: { BlockedKey } = {}
	for _, Key in Call.OtherKeys do
		local Report = Call.TentReports[Names.KeyText(Key)]
		local Working = if Report == nil then nil else EndWorkOf(Report)
		if Working ~= nil then
			table.insert(Held, { Key = Key, Report = Working })
		end
	end
	return Held
end

return {
	EndWorkOf = EndWorkOf,
	RefusalFate = RefusalFate,
	IsServedReport = IsServedReport,
	IsSweepReport = IsSweepReport,
	IsSupersededReport = IsSupersededReport,
	EndsInFence = EndsInFence,
	IsBehindReport = IsBehindReport,
	IsForgottenReport = IsForgottenReport,
	IsGatedReport = IsGatedReport,
	IsSentAgainReport = IsSentAgainReport,
	HasErredKey = HasErredKey,
	FirstWhere = FirstWhere,
	FirstMissingLeg = FirstMissingLeg,
	FirstRefusal = FirstRefusal,
	RefusalAnswer = RefusalAnswer,
	BehindLeg = BehindLeg,
	BlockedTents = BlockedTents,
}
