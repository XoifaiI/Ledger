--!strict
--!optimize 2

--[=[
	SlotPath: an exclusive mark's slot path in bytes (spec/protocols/record/Format.md 7.5): V(#steps - 1), then per
	step SS(key) for a table key, or V(0) and V(index) for an array index. It sits beside Post, which owns the path.

	IsSlotPath is the one rule of what a slot path may be: one or more steps, each a nonempty string of valid UTF-8
	or an index from 1 below 2^53. The writer throws on anything else; a reader throws through Format.Malformed, and
	refuses an index below 1.

	Return type: A plain table with IsSlotPath, WriteSlotPath and ReadSlotPath.
	Example usage:
		local Out = Format.NewWriter(64)
		SlotPath.WriteSlotPath(Out, { "Bag", 3 })
		Format.ToString(Out) --> "BFBagAD"
--]=]

local Format = require("../../Encoding/Format")
local Messages = require("../../Constants/Messages")
local Names = require("../../Encoding/Names")
local Post = require("../Post")
local Record = require("../../Constants/Record")

type Writer = Format.Writer
type Reader = Format.Reader
type PathStep = Post.PathStep

local Malformed = Format.Malformed
local WriteVarint = Format.WriteVarint
local ReadVarint = Format.ReadVarint

local WriteStored = Names.WriteStored
local ReadStored = Names.ReadStored

local CheckPath = Post.CheckPath
local FirstIndex = Post.FirstIndex

local IndexStepHeader = 0

local ModuleName = "SlotPath"
local IndexBelowFirst = `a slot path's array index is below {FirstIndex}`
local NotASlotPath = `{ModuleName}: a slot path is one or more steps, each a nonempty string of valid UTF-8 or a `
	.. `whole number from {FirstIndex} below {Record.VarintLimit}. {Messages.KeepInRange}`

local function IsSlotStep(Step: unknown): boolean
	if type(Step) == "string" then
		return Step ~= "" and utf8.len(Step) ~= nil
	end
	return type(Step) == "number" and Step % 1 == 0 and Step >= FirstIndex and Step < Record.VarintLimit
end

local function IsSlotPath(Value: unknown): boolean
	if type(Value) ~= "table" then
		return false
	end
	local Steps = Value :: { unknown }
	local Count = 0
	for _ in Steps do
		Count += 1
	end
	if Count == 0 or Count ~= #Steps then
		return false
	end
	for Index = 1, Count do
		if not IsSlotStep(Steps[Index]) then
			return false
		end
	end
	return true
end

local function WriteSlotPath(Out: Writer, Slot: { PathStep })
	if not IsSlotPath(Slot) then
		error(NotASlotPath)
	end
	local Steps = CheckPath(Slot)
	WriteVarint(Out, #Steps - 1)
	for _, Step in Steps do
		if type(Step) == "number" then
			WriteVarint(Out, IndexStepHeader)
			WriteVarint(Out, Step)
		else
			WriteStored(Out, Step)
		end
	end
end

local function ReadStep(In: Reader): PathStep
	local Start = In.At
	if ReadVarint(In) ~= IndexStepHeader then
		In.At = Start
		return ReadStored(In)
	end
	local Index = ReadVarint(In)
	if Index < FirstIndex then
		Malformed(IndexBelowFirst)
	end
	return Index
end

local function ReadSlotPath(In: Reader): { PathStep }
	local StepsAfterFirst = ReadVarint(In)
	local Slot: { PathStep } = {}
	for _ = 0, StepsAfterFirst do
		table.insert(Slot, ReadStep(In))
	end
	return Slot
end

return {
	IsSlotPath = IsSlotPath,
	WriteSlotPath = WriteSlotPath,
	ReadSlotPath = ReadSlotPath,
}
