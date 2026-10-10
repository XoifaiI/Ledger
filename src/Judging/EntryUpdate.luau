--!strict
--!optimize 2

--[=[
	EntryUpdate: the writer's entry of a run (record sheet 9, S.5). The numbers a run decided go into the
	closure's Ran; a decided Tent or Commit, which has no number, goes in at LegOpRan. The writer's entry takes
	the run: its highest sequence, newest stamp and fates above Acknowledged. No writer id changes no entry.

	Return type: A plain table with MarkRan and UpdateEntry.
	Example usage:
		EntryUpdate.UpdateEntry(Run)
--]=]

local JudgingRun = require("./Run")
local Record = require("../Constants/Record")
local Lookup = require("../Stored/Lookup")
local OpForms = require("./OpForms")
local Timed = require("../Stored/Items/Timed")

type WriterEntry = Timed.WriterEntry
type WriterFate = Timed.WriterFate
type Run = JudgingRun.Run

local FindWriterEntry = Lookup.FindWriterEntry
local HasSequence = OpForms.HasSequence
local SequenceOf = OpForms.SequenceOf

local function MarkRan(Run: Run)
	for _, Op in Run.Decided do
		if HasSequence(Op.Form) then
			Run.Closure.Ran[SequenceOf(Op.Form)] = true
		elseif Op.Form.Kind ~= "Cut" then
			Run.Closure.Ran[Record.LegOpRan] = true
		end
	end
end

local function IsHigherSequence(Left: WriterFate, Right: WriterFate): boolean
	return Left.Sequence > Right.Sequence
end

local function KeptFates(Run: Run, Entry: WriterEntry?): { WriterFate }
	local Acknowledged = Run.Request.Acknowledged
	local Fates: { WriterFate } = {}
	if Entry ~= nil then
		for _, Fate in Entry.Fates do
			if Fate.Sequence > Acknowledged then
				table.insert(Fates, Fate)
			end
		end
	end
	for _, Fate in Run.NewFates do
		if Fate.Sequence > Acknowledged then
			table.insert(Fates, Fate)
		end
	end
	table.sort(Fates, IsHigherSequence)
	return Fates
end

local function HasDecidedWriterOp(Run: Run): boolean
	for _, Op in Run.Decided do
		if Op.Form.Kind == "Minted" or Op.Form.Kind == "Hopeful" then
			return true
		end
	end
	return false
end

local function LastDecided(Run: Run): number
	local Highest = SequenceOf(Run.Decided[1].Form)
	for _, Op in Run.Decided do
		Highest = math.max(Highest, SequenceOf(Op.Form))
	end
	return Highest
end

local function NewestStamp(Run: Run): number
	local Newest = Run.Decided[1].Stamp
	for _, Op in Run.Decided do
		Newest = math.max(Newest, Op.Stamp)
	end
	return Newest
end

local function UpdateEntry(Run: Run)
	local Owner = Run.Request.WriterId
	if Owner == nil then
		return
	end
	local Entry = FindWriterEntry(Run.Book, Owner)
	if Entry == nil and not HasDecidedWriterOp(Run) then
		return
	end
	if Entry == nil then
		local Made: WriterEntry = {
			Kind = "Writer",
			WriterId = Owner,
			Highest = LastDecided(Run),
			Newest = NewestStamp(Run),
			Fates = KeptFates(Run, nil),
		}
		table.insert(Run.Book.Timed, Made)
		Run.Written[Made] = true
		return
	end
	if #Run.Decided > 0 then
		Entry.Highest = LastDecided(Run)
		Entry.Newest = math.max(Entry.Newest, NewestStamp(Run))
	end
	Entry.Fates = KeptFates(Run, Entry)
	Run.Written[Entry] = true
end

return {
	MarkRan = MarkRan,
	UpdateEntry = UpdateEntry,
}
