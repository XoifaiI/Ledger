--!strict
--!optimize 2

--[=[
	Measure: the bytes a Tx call's marks and pinned record would take, for the API's check before it sends and a
	gather's legs (transaction sheet 7 step 1). It assumes the widest values: an absolute stamp of StampMax, attempt
	MaxAttempts, a drawn name's numbers below 2^40 (Format 13), also for no name, and a part decider's 2^53 - 1.

	Return type: A plain table with PinnedRecordBytes, MarkBytes, OpBytes, MeasuredName and WidestDrawnName.
	Example usage:
		local Bytes = Measure.MarkBytes(Leg, Setup, Decider, Measure.WidestDrawnName)
--]=]

local Book = require("../../Stored/Book")
local Json = require("../../Encoding/Json")
local Marks = require("../Legs/Marks")
local Names = require("../../Encoding/Names")
local Record = require("../../Constants/Record")
local Requests = require("./Requests")
local Shapes = require("../../Shapes")
local Transaction = require("../../Constants/Transaction")
local TxShapes = require("../Shapes")
local Work = require("../../Stored/Items/Work")

type GivenName = Names.GivenName
type KeyReference = Names.KeyReference
type OpName = Names.OpName
type StoreKey = Names.StoreKey
type TxLeg = TxShapes.TxLeg
type Setup = Shapes.Setup
type Mark = Work.Mark
type MarkOpening = Work.MarkOpening

local NoEpoch = 0
local AnyFingerprint = 0

local ModuleName = "Measure"
local DeltaNotDeclared = `{ModuleName}: a delta leg's op kind is a balance op the setup declares. This one is not`

local WidestDrawnName: OpName = table.freeze({
	Kind = "Drawn" :: "Drawn",
	Server = Record.DrawnNumberLimit - 1,
	Counter = Record.DrawnNumberLimit - 1,
	Part = nil,
})

local function MeasuredName(Given: GivenName?): OpName
	if Given == nil then
		return WidestDrawnName
	end
	if Given.Kind == "Game" then
		return { Kind = "Game", Text = Given.Text, Fingerprint = AnyFingerprint, Part = nil }
	end
	return { Kind = "Drawn", Server = Given.Server, Counter = Given.Counter, Part = nil }
end

local function OpeningOf(Name: OpName): MarkOpening
	return Marks.NewOpening(Name, Record.StampMax, Transaction.MaxAttempts)
end

local function BytesOf(Item: Mark, Setup: Setup): number
	return Book.ItemSize(Book.Rooms.Work, Item, NoEpoch, Setup.Limits.WindowUnit)
end

local function PinnedRecordBytes(Legs: { TxLeg }, DeciderIndex: number, DeciderSetup: Setup, Name: OpName): number
	local Decider = Legs[DeciderIndex].Key
	local OtherLegs: { KeyReference } = {}
	for Index, Leg in Legs do
		if Index ~= DeciderIndex then
			table.insert(OtherLegs, Names.ReferenceTo(Decider, Leg.Key))
		end
	end
	local DeciderValue: number? = nil
	if DeciderSetup.Build.KeyKind == Record.KeyKind.Part then
		DeciderValue = Record.VarintLimit - 1
	end
	return BytesOf(Marks.NewPinnedRecord(OpeningOf(Name), OtherLegs, DeciderValue), DeciderSetup)
end

local function MarkBytes(Leg: TxLeg, Setup: Setup, Decider: StoreKey, Name: OpName): number
	local Opening = OpeningOf(Name)
	local Reference = Names.ReferenceTo(Leg.Key, Decider)
	local Form = Requests.ClassifyLeg(Leg, Setup)
	if Form.Kind == "Game" then
		return BytesOf(Marks.NewExclusiveMark(Opening, Reference, Form.Slot), Setup)
	end
	local Declaration = Setup.Build.BalanceOps[Leg.OpKind]
	if Declaration == nil then
		error(DeltaNotDeclared)
	end
	return BytesOf(Marks.NewEscrowMark(Opening, Reference, Declaration, Form.Amount), Setup)
end

local function OpBytes(Terms: unknown): number
	return Json.Size(Terms)
end

return {
	WidestDrawnName = WidestDrawnName,
	MeasuredName = MeasuredName,
	PinnedRecordBytes = PinnedRecordBytes,
	MarkBytes = MarkBytes,
	OpBytes = OpBytes,
}
