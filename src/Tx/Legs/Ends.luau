--!strict
--!optimize 2

--[=[
	Ends: a request's ends, applied at record step 3 before its ops (transaction sheet 11), and ProveGone (sheet 12).

	A Resolve ends only its own use's mark (a commit first writing the decider's value at its slot), else tests its
	name's held fate, any fingerprint. An end that cannot read what it settles gives Unreadable, which cancels the
	write.

	Return type: A plain table with ApplyEnds, EndsMark, EndsRequest, LoneEndReport and ProveGone.
	Example usage:
		local Reports = Ends.ApplyEnds(Run)
--]=]

local Balances = require("./Balances")
local Decider = require("./Decider")
local Events = require("../../Events")
local Fates = require("../../Stored/Items/Fates")
local Judge = require("../../Judging/Judge")
local JudgingRun = require("../../Judging/Run")
local JudgingShapes = require("../../Judging/Shapes")
local Lookup = require("../../Stored/Lookup")
local Losses = require("../../Stored/Items/Losses")
local Marks = require("./Marks")
local Names = require("../../Encoding/Names")
local Post = require("../../Stored/Post")
local PostDiff = require("./PostDiff")
local Seal = require("../../Stored/Items/Seal")
local Shapes = require("../../Shapes")
local Transaction = require("../../Constants/Transaction")
local TxShapes = require("../Shapes")
local Value = require("../../Stored/Value")
local Work = require("../../Stored/Items/Work")

type State = { [unknown]: unknown }
type Fate = Fates.Fate
type Name = Names.Name
type OpName = Names.OpName
type NamedReturn = Losses.NamedReturn
type Outcome = Events.Outcome
type Limits = Shapes.Limits
type Report = JudgingShapes.Report
type Run = JudgingRun.Run
type UpdateRequest = Shapes.UpdateRequest
type Seal = Seal.Seal
type Decoded = Value.Decoded
type DiffEntry = Post.DiffEntry
type DropEnd = TxShapes.DropEnd
type End = TxShapes.End
type ResolveEnd = TxShapes.ResolveEnd
type EscrowMark = Work.EscrowMark
type ExclusiveMark = Work.ExclusiveMark
type Mark = Work.Mark
type PinnedRecord = Work.PinnedRecord
type StandingMark = Work.StandingMark

local ProveSealName: Name = {
	Kind = "Drawn",
	Server = Transaction.ProveName.Server,
	Counter = Transaction.ProveName.Counter,
}

local DoneReport: Report = table.freeze({ Kind = "Done" :: "Done" })
local ExistsReport: Report = table.freeze({ Kind = "Exists" :: "Exists" })
local UnreadableReport: Report = table.freeze({ Kind = "Unreadable" :: "Unreadable", Cause = "Amounts" :: "Amounts" })

local function SlottedDiff(Diff: { DiffEntry }, Mark: ExclusiveMark, DeciderValue: number?): { DiffEntry }?
	if Mark.Slot == nil then
		return Diff
	end
	if DeciderValue == nil then
		return nil
	end
	return PostDiff.WriteSlot(Diff, Mark.Slot, DeciderValue)
end

local function SettledBy(Run: Run, Mark: StandingMark, DeciderValue: number?): State | "Unreadable"
	if Mark.Kind == "Exclusive" then
		if Run.Post == nil then
			return "Unreadable"
		end
		local Diff = SlottedDiff(Run.Post, Mark, DeciderValue)
		if Diff == nil or not PostDiff.Applies(Run.State, Diff) then
			return "Unreadable"
		end
		return PostDiff.ApplyDiff(Run.State, Diff)
	end
	local Arithmetic = Run.Setup.Build.Balances[Mark.Field]
	if Arithmetic == nil then
		return "Unreadable"
	end
	local Settled = if Mark.IsDebit
		then Balances.SettleDebit(Run.State, Mark.Field, Mark.Amount, Arithmetic)
		else Balances.SettleCredit(Run.State, Mark.Field, Mark.Amount, Arithmetic)
	if Settled == "Unreadable" or not Balances.IsValidBalance(Arithmetic, Settled[Mark.Field]) then
		return "Unreadable"
	end
	return Settled
end

local function ReturnedAmount(Run: Run, Mark: EscrowMark): Losses.FieldAmount | "Unreadable"
	local Arithmetic = Run.Setup.Build.Balances[Mark.Field]
	if Arithmetic == nil then
		return "Unreadable"
	end
	local Amount = Balances.FromStored(Mark.Amount, Arithmetic)
	if Amount == nil then
		return "Unreadable"
	end
	local Returned = Balances.ToSignedStored(Amount, not Mark.IsDebit, Arithmetic)
	if not Balances.IsStorableAmount(Returned) then
		return "Unreadable"
	end
	return { Field = Mark.Field, Amount = Returned }
end

local function EndWithFate(Run: Run, Mark: StandingMark, End: ResolveEnd, Fate: Fate)
	Marks.RemoveWorkItem(Run, Mark)
	Marks.WriteEndFate(Run, End.Name, Mark.Opening.Stamp, Fate)
	Run.Acted = true
end

local function ApplyCommittedMark(Run: Run, Mark: StandingMark, End: ResolveEnd): Report
	local Settled = SettledBy(Run, Mark, End.DeciderValue)
	if Settled == "Unreadable" then
		return UnreadableReport
	end
	Run.State = Settled
	EndWithFate(Run, Mark, End, { Kind = "Took" })
	return DoneReport
end

local function ReturnOrphan(Run: Run, Mark: StandingMark, End: ResolveEnd): Report
	local Escrow: Losses.FieldAmount? = nil
	if Mark.Kind == "Escrow" then
		local Returned = ReturnedAmount(Run, Mark)
		if Returned == "Unreadable" then
			return UnreadableReport
		end
		Escrow = Returned
	end
	local Return: NamedReturn = {
		Cause = "Returned",
		Name = Mark.Opening.Name,
		Stamp = Mark.Opening.Stamp,
		OtherKey = table.clone(Mark.Decider),
		Escrow = Escrow,
		Fingerprint = Mark.Opening.Fingerprint,
	}
	table.insert(Run.Book.Losses.Returns, Return)
	EndWithFate(Run, Mark, End, { Kind = "Aborted", Attempt = Mark.Opening.Attempt })
	return DoneReport
end

local function ResolveWithMark(Run: Run, Mark: StandingMark, End: ResolveEnd): Report
	local Attempt = Mark.Opening.Attempt
	if End.Outcome == "Orphan" then
		return ReturnOrphan(Run, Mark, End)
	end
	if End.Outcome == "Commit" and Attempt == End.Attempt then
		return ApplyCommittedMark(Run, Mark, End)
	end
	local IsEarlier = Attempt < End.Attempt
	local IsAbortedHere = End.Outcome == "Abort" and Attempt == End.Attempt
	if IsEarlier or IsAbortedHere then
		EndWithFate(Run, Mark, End, { Kind = "Aborted", Attempt = Attempt })
	end
	return DoneReport
end

local function StopsAbort(Fate: Fate, Attempt: number): boolean
	if Fate.Kind ~= "Aborted" then
		return true
	end
	return Fate.Attempt >= Attempt
end

local function WriteLegFate(Run: Run, End: ResolveEnd, Fate: Fate)
	Marks.WriteEndFate(Run, End.Name, End.Stamp, Fate)
	Run.Acted = true
end

local function HoldsFateThat(Run: Run, Name: OpName, Stops: (Fate: Fate) -> boolean): boolean
	for _, Item in Run.Book.Timed do
		if Item.Kind == "Named" and Lookup.EntryHolds(Item, Name) and Stops(Item.Fate) then
			return true
		end
	end
	return false
end

local function IsTook(Fate: Fate): boolean
	return Fate.Kind == "Took"
end

local function ResolveWithoutMark(Run: Run, End: ResolveEnd): Report
	if Marks.IsForgotten(Run.Book, End.Name, End.Stamp) then
		return DoneReport
	end
	if End.Outcome == "Commit" then
		if not HoldsFateThat(Run, End.Name, IsTook) then
			WriteLegFate(Run, End, { Kind = "Took" })
		end
		return DoneReport
	end
	local function StopsThisAbort(Fate: Fate): boolean
		return StopsAbort(Fate, End.Attempt)
	end
	if not HoldsFateThat(Run, End.Name, StopsThisAbort) then
		WriteLegFate(Run, End, { Kind = "Aborted", Attempt = End.Attempt })
	end
	return DoneReport
end

local function Resolve(Run: Run, End: ResolveEnd): Report
	local Mark = Marks.OwnMarkOf(Run.Book, End.Name)
	if Mark ~= nil then
		return ResolveWithMark(Run, Mark, End)
	end
	return ResolveWithoutMark(Run, End)
end

local function DecisionTook(Pinned: PinnedRecord): Fate
	if Pinned.DeciderValue ~= nil then
		return { Kind = "TookWith", Value = Pinned.DeciderValue }
	end
	return { Kind = "Took" }
end

local function Drop(Run: Run, End: DropEnd): Report
	for _, Dropped in End.Names do
		local Pinned = Marks.OwnPinnedOf(Run.Book, Dropped.Name)
		if Pinned == nil then
			continue
		end
		Marks.RemoveWorkItem(Run, Pinned)
		Marks.RemoveNamed(Run, Dropped.Name)
		Marks.WriteEndFate(Run, Dropped.Name, Pinned.Opening.Stamp, DecisionTook(Pinned))
		Run.Acted = true
		if Dropped.Proved ~= nil then
			local Return: NamedReturn = {
				Cause = "Orphan",
				Name = Pinned.Opening.Name,
				Stamp = Pinned.Opening.Stamp,
				OtherKey = table.clone(Dropped.Proved),
				Escrow = nil,
				Fingerprint = Pinned.Opening.Fingerprint,
			}
			table.insert(Run.Book.Losses.Returns, Return)
		end
	end
	return DoneReport
end

local function ApplyEnd(Run: Run, End: End): Report
	if End.Kind == "Resolve" then
		return Resolve(Run, End)
	end
	if End.Kind == "Drop" then
		return Drop(Run, End)
	end
	return Decider.Fence(Run, End)
end

local function ApplyEnds(Run: Run): { Report }
	local Reports: { Report } = {}
	for _, End in Run.Request.Ends do
		local Report = ApplyEnd(Run, End)
		table.insert(Reports, Report)
		if Report.Kind == "Unreadable" then
			break
		end
	end
	return Reports
end

local function IsResolved(End: ResolveEnd, Item: StandingMark): boolean
	return End.Outcome == "Orphan" or End.Attempt >= Item.Opening.Attempt
end

local function NamesItem(End: End, Item: Mark): boolean
	if End.Kind == "Resolve" then
		return Item.Kind ~= "Pinned" and Marks.IsOfUse(Item, End.Name) and IsResolved(End, Item)
	end
	if End.Kind == "Drop" and Item.Kind == "Pinned" then
		for _, Dropped in End.Names do
			if Marks.IsOfUse(Item, Dropped.Name) then
				return true
			end
		end
	end
	return false
end

local function EndsMark(Ends: { End }, Item: Mark): boolean
	for _, End in Ends do
		if NamesItem(End, Item) then
			return true
		end
	end
	return false
end

local function EndsRequest(Ends: { End }): UpdateRequest
	return { Kind = "Update", WriterId = nil, Acknowledged = 0, MustExist = false, Ops = {}, Ends = Ends }
end

local function LoneEndReport(Outcome: Outcome): Report?
	if Outcome.Kind == "Err" then
		return nil
	end
	return Outcome.Note.EndReports[1]
end

local function ProveGone(Held: Decoded?, Clock: number, Limits: Limits): (Seal?, Report)
	if not Judge.IsClockUsable(Clock, Limits) then
		return nil, ExistsReport
	end
	if Held ~= nil and (Held.Kind ~= "Sealed" or not Seal.IsLeftOver(Held.Seal, Clock, Limits.SealAge)) then
		return nil, ExistsReport
	end
	local Proof: Seal = {
		Name = ProveSealName,
		Stamp = Transaction.ProveStamp,
		Sealer = Transaction.ProveSealer,
		RemovalStamp = Clock,
		Fingerprint = nil,
		Records = { Events = {}, Returns = {}, Slots = {} },
	}
	return Proof, { Kind = "Proved", RemovalStamp = Clock, Sealer = Transaction.ProveSealer }
end

return {
	ApplyEnds = ApplyEnds,
	EndsMark = EndsMark,
	EndsRequest = EndsRequest,
	LoneEndReport = LoneEndReport,
	ProveGone = ProveGone,
}
