--!strict
--!optimize 2

--[=[
	TentReports: what the reports of a Tx call's Tents say, read over its other keys in leg order: the first refusal,
	with its leg and state, missing leg, fence, behind, forgotten or gated report, the keys that hold the call up, and a
	key whose Tent erred past RetryRounds (transaction sheet 15.1). A Behind names its leg, else the decider.

	Return type: A plain table of functions, and the MissingLeg and Refusal types.
	Example usage:
		local Missing = TentReports.FirstMissingLeg(Call)
--]=]

local Book = require("../../Stored/Book")
local Fates = require("../../Stored/Items/Fates")
local JudgingShapes = require("../../Judging/Shapes")
local Names = require("../../Encoding/Names")
local NextSteps = require("./NextSteps")
local TxState = require("../State")

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

local function EndsInFence(Report: Report): boolean
	if Report.Kind == "Other" or Report.Kind == "Superseded" or Report.Kind == "Large" then
		return true
	end
	if Report.Kind ~= "Decided" then
		return false
	end
	return Report.Fate.Kind == "Took" or Report.Fate.Kind == "TookWith" or Report.Fate.Kind == "Aborted"
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
	EndsInFence = EndsInFence,
	IsBehindReport = IsBehindReport,
	IsForgottenReport = IsForgottenReport,
	IsGatedReport = IsGatedReport,
	IsSentAgainReport = IsSentAgainReport,
	HasErredKey = HasErredKey,
	FirstWhere = FirstWhere,
	FirstMissingLeg = FirstMissingLeg,
	FirstRefusal = FirstRefusal,
	BehindLeg = BehindLeg,
	BlockedTents = BlockedTents,
}
