--!strict
--!optimize 2

--[=[
	SealedKey: a request on a sealed key (cuts sheet 5.2 case 1, 5.3): the report of each op of a request that
	names the seal, and the seal stamp that renews it.

	A stamp drops the namings once the seal is a cut window old. Whether a seal is left over is
	Stored/Items/Seal's IsLeftOver.

	Return type: A plain table with OwnSealReports, MissingWithSeal and OpenStamp.
	Example usage:
		local Stamped, Report = SealedKey.OpenStamp(Held, Stamp, Clock, Limits)
--]=]

local CutShapes = require("../Shapes")
local Entries = require("../../Stored/Entries")
local Judge = require("../../Judging/Judge")
local JudgingShapes = require("../../Judging/Shapes")
local Lookup = require("../../Stored/Lookup")
local Seal = require("../../Stored/Items/Seal")
local Shapes = require("../../Shapes")
local Value = require("../../Stored/Value")

type Seal = Seal.Seal
type Decoded = Value.Decoded
type CutForm = CutShapes.CutForm
type SealStampRequest = CutShapes.SealStampRequest
type Limits = Shapes.Limits
type Report = JudgingShapes.Report
type UpdateRequest = Shapes.UpdateRequest

local FingerprintOf = Entries.FingerprintOf
local IsSameName = Lookup.IsSameName
local IsLeftOver = Seal.IsLeftOver
local IsClockUsable = Judge.IsClockUsable

local function MissingWithSeal(Sealed: Seal, IsSealLeftOver: boolean): Report
	return { Kind = "Missing", Identity = nil, Seal = Sealed, IsLeftOver = IsSealLeftOver, IsLegacy = false }
end

local function SealedOrSpent(Sealed: Seal, Form: CutForm): Report
	if Form.CutKind == "Erase" and FingerprintOf(Form.Name) == Sealed.Fingerprint then
		return { Kind = "Sealed", Seal = Sealed }
	end
	return { Kind = "Spent" }
end

local function OwnSealReports(Sealed: Seal, Request: UpdateRequest, IsSealLeftOver: boolean): { Report }?
	local Missing = MissingWithSeal(Sealed, IsSealLeftOver)
	local IsNamed = false
	local Reports: { Report } = {}
	for _, Op in Request.Ops do
		local Form = Op.Form
		if Form.Kind == "Cut" and IsSameName(Sealed.Name, Form.Name) then
			IsNamed = true
			table.insert(Reports, SealedOrSpent(Sealed, Form))
		else
			table.insert(Reports, Missing)
		end
	end
	if not IsNamed then
		return nil
	end
	return Reports
end

local function MayStamp(Sealed: Seal, Stamp: SealStampRequest, Clock: number, Limits: Limits): boolean
	if IsLeftOver(Sealed, Clock, Limits.SealAge) then
		return true
	end
	return Stamp.RemovalStamp == Sealed.RemovalStamp and Stamp.Server == Sealed.Sealer
end

local function StampSeal(Sealed: Seal, Sealer: number, Clock: number, Limits: Limits): Seal
	local IsWindowOver = Clock - Sealed.RemovalStamp >= Limits.CutWindow
	local Records = if IsWindowOver then { Events = {}, Returns = {}, Slots = {} } else Sealed.Records
	return {
		Name = Sealed.Name,
		Stamp = Sealed.Stamp,
		Sealer = Sealer,
		RemovalStamp = Clock,
		Fingerprint = Sealed.Fingerprint,
		Records = Records,
	}
end

local function OpenStamp(Held: Decoded?, Stamp: SealStampRequest, Clock: number, Limits: Limits): (Seal?, Report)
	if Held ~= nil and Held.Kind == "Unreadable" then
		return nil, { Kind = "Unreadable", Cause = Held.Cause }
	end
	if Held == nil then
		return nil, { Kind = "Missing", Identity = nil, Seal = nil, IsLeftOver = false, IsLegacy = false }
	end
	if Held.Kind == "Kept" then
		local Identity = Held.Book.Identity
		return nil,
			{ Kind = "Missing", Identity = Identity, Seal = nil, IsLeftOver = false, IsLegacy = Identity == nil }
	end
	if not IsClockUsable(Clock, Limits) then
		return nil, { Kind = "Undecided" }
	end
	if not MayStamp(Held.Seal, Stamp, Clock, Limits) then
		return nil, MissingWithSeal(Held.Seal, false)
	end
	return StampSeal(Held.Seal, Stamp.Server, Clock, Limits),
		{ Kind = "Stamped", RemovalStamp = Clock, Sealer = Stamp.Server }
end

return {
	OwnSealReports = OwnSealReports,
	MissingWithSeal = MissingWithSeal,
	OpenStamp = OpenStamp,
}
