--!strict
--!optimize 2

--[=[
	Beside: what a read and an Apply do beside the marks of P that need no request (transaction sheet 19 rules 1
	and 2, record sheet 12's Apply).

	A held ride or an answered call here holds a use's abort. An exclusive mark makes an op Busy; OrderRule judges
	a game op. An unreadable escrow amount gives Unreadable.

	Rule 2's remembered state is of one incarnation: kept from a book, that book's identity. A copy carries no id:
	on a key that cannot be erased (KindSetup) it is of the one incarnation, which has none; on an erasable key it is
	of an unknown incarnation, even after a read, since an old incarnation's copy may arrive late. A state of an
	unknown incarnation is kept by count alone and never shown beside an unclean mark. A state of a known incarnation
	replaces one of another, whatever the counts. Reading/Showables decides where a kept state lives.

	Rule 2 shows the remembered state only when it is at least as new as the version read: an unclean mark means a
	write changed the state after the mark, so an older remembered state would hide a committed change (Answers.md
	5.4, 5.7); the read then reads the deciders (rule 3).

	Return type: A plain table with HoldsAbort, KeepCopyShowable, KeepShowable, Showing and ApplyBesideMarks, and the
	Showing type.
	Example usage:
		local Verdict = Beside.ApplyBesideMarks(Setup, View, Items, "Buy", Terms, Clock)
		if Verdict == Reasons.Busy then ... end
--]=]

local Book = require("../Stored/Book")
local Decide = require("../Judging/Decide")
local JudgingShapes = require("../Judging/Shapes")
local KindSetup = require("../Judging/KindSetup")
local Marks = require("./Legs/Marks")
local Names = require("../Encoding/Names")
local OrderRule = require("./Legs/OrderRule")
local Reasons = require("../Constants/Reasons")
local Rides = require("./Rides")
local Shapes = require("../Shapes")
local Showables = require("../Reading/Showables")
local TxShapes = require("./Shapes")
local Value = require("../Stored/Value")
local Verdicts = require("../Judging/Verdicts")
local Work = require("../Stored/Items/Work")

type Identity = Book.Identity
type Kept = Value.Kept
type AbortedUse = TxShapes.AbortedUse
type ResolveEnd = TxShapes.ResolveEnd
type Verdict = JudgingShapes.Verdict
type Mark = Work.Mark
type StandingMark = Work.StandingMark
type StoreKey = Names.StoreKey
type CacheEntry = Shapes.CacheEntry
type KnownIncarnation = Shapes.KnownIncarnation
type Showable = Shapes.Showable
type ShowableIncarnation = Shapes.ShowableIncarnation
type ShowableSource = Shapes.ShowableSource
type ServerState = Shapes.ServerState
type Setup = Shapes.Setup
type Served = Showables.Served

type Fields = { [unknown]: unknown }

local UnknownIncarnation: ShowableIncarnation = table.freeze({ Kind = "Unknown" :: "Unknown" })
local NoIdentity: KnownIncarnation = table.freeze({ Kind = "Known" :: "Known", Identity = nil })

export type Showing = { read Kind: "Show", read State: Fields } | { read Kind: "Unclean", read Marks: { StandingMark } }

local function EndsAsAbort(End: ResolveEnd, Attempt: number): boolean
	if End.Outcome == "Orphan" or End.Attempt > Attempt then
		return true
	end
	return End.Outcome == "Abort" and End.Attempt == Attempt
end

local function HoldsAbort(Server: ServerState, Key: StoreKey, Item: StandingMark): boolean
	for _, Held in Rides.HeldOn(Server, Key) do
		local End = Held.End
		if End.Kind == "Resolve" and EndsAsAbort(End, Item.Opening.Attempt) and Marks.IsOfUse(Item, End.Name) then
			return true
		end
	end
	return false
end

local function IsAbortedByCall(Aborted: { AbortedUse }, Item: StandingMark): boolean
	for _, Use in Aborted do
		if Use.Attempt >= Item.Opening.Attempt and Marks.IsOfUse(Item, Use.Name) then
			return true
		end
	end
	return false
end

local function IsUncleanMark(Server: ServerState, Key: StoreKey, Item: StandingMark, Aborted: { AbortedUse }): boolean
	if Item.IsClean or HoldsAbort(Server, Key, Item) then
		return false
	end
	return not IsAbortedByCall(Aborted, Item)
end

local function UncleanMarks(Server: ServerState, Key: StoreKey, Kept: Kept, Aborted: { AbortedUse }): { StandingMark }
	local Unclean: { StandingMark } = {}
	for _, Item in Kept.Book.Work do
		if Item.Kind ~= "Pinned" and IsUncleanMark(Server, Key, Item, Aborted) then
			table.insert(Unclean, Item)
		end
	end
	return Unclean
end

local function HasUncleanMark(Server: ServerState, Key: StoreKey, Kept: Kept, Aborted: { AbortedUse }): boolean
	return #UncleanMarks(Server, Key, Kept, Aborted) > 0
end

local function IsSameIdentity(Identity: Identity?, Other: Identity?): boolean
	if Identity == nil or Other == nil then
		return Identity == nil and Other == nil
	end
	return Identity.Server == Other.Server and Identity.Counter == Other.Counter
end

local function BelongsToIncarnation(Held: Showable, Identity: Identity?): boolean
	local Incarnation = Held.From.Incarnation
	if Incarnation.Kind ~= "Known" then
		return false
	end
	return IsSameIdentity(Incarnation.Identity, Identity)
end

local function KeepsHeld(Held: Showable?, Writes: number, From: ShowableSource): boolean
	if Held == nil or Held.Writes < Writes then
		return false
	end
	local Incarnation = From.Incarnation
	if Incarnation.Kind ~= "Known" then
		return true
	end
	return BelongsToIncarnation(Held, Incarnation.Identity)
end

local function Keep(Server: ServerState, Entry: CacheEntry, Key: StoreKey, Kept: Showable, Served: Served)
	if not KeepsHeld(Showables.Find(Server, Key), Kept.Writes, Kept.From) then
		Showables.Keep(Server, Entry, Key, Kept, Served)
	end
end

local function CopyIncarnation(Setup: Setup, Key: StoreKey): ShowableIncarnation
	if KindSetup.IsErasableKey(Setup, Key) then
		return UnknownIncarnation
	end
	return NoIdentity
end

local function KeepCopyShowable(
	Server: ServerState,
	Entry: CacheEntry,
	Setup: Setup,
	Key: StoreKey,
	Writes: number,
	Viewed: Fields,
	Served: Served
)
	local From: ShowableSource = { Kind = "Copy", Incarnation = CopyIncarnation(Setup, Key) }
	Keep(Server, Entry, Key, { Writes = Writes, State = Viewed, From = From }, Served)
end

local function KeepShowable(
	Entry: CacheEntry,
	Kept: Kept,
	Viewed: Fields,
	Server: ServerState,
	Key: StoreKey,
	Aborted: { AbortedUse },
	Served: Served
)
	local KeptBook = Kept.Book
	local From: ShowableSource = { Kind = "Book", Incarnation = { Kind = "Known", Identity = KeptBook.Identity } }
	if not HasUncleanMark(Server, Key, Kept, Aborted) then
		Keep(Server, Entry, Key, { Writes = KeptBook.Writes, State = Viewed, From = From }, Served)
	end
end

local function Showing(Server: ServerState, Key: StoreKey, Kept: Kept, Viewed: Fields, Aborted: { AbortedUse }): Showing
	local Unclean = UncleanMarks(Server, Key, Kept, Aborted)
	if #Unclean == 0 then
		return { Kind = "Show", State = Viewed }
	end
	local Held = Showables.Find(Server, Key)
	if Held ~= nil and Held.Writes >= Kept.Book.Writes and BelongsToIncarnation(Held, Kept.Book.Identity) then
		return { Kind = "Show", State = Held.State }
	end
	return { Kind = "Unclean", Marks = Unclean }
end

local function ApplyBesideMarks(
	Setup: Setup,
	View: Fields,
	Items: { Mark },
	OpKind: string,
	Terms: unknown,
	Clock: number
): Verdict | "Busy"
	for _, Item in Items do
		if Item.Kind == "Exclusive" then
			return Reasons.Busy
		end
	end
	local Escrows = Marks.EscrowMarksOf(Items)
	if #Escrows == 0 or Setup.Build.BalanceOps[OpKind] ~= nil or Decide.IsPartRule(Setup, OpKind) then
		return Decide.DecideOnState(Setup, View, OpKind, Terms, Escrows, Clock)
	end
	local Judgement = OrderRule.JudgeBesideEscrow(Setup, View, Escrows, OpKind, Terms, Clock)
	if Judgement.Kind == "AsOnState" then
		return Decide.DecideOnState(Setup, View, OpKind, Terms, Decide.NoMarks, Clock)
	end
	if Judgement.Kind == "RefusedByRules" then
		return Verdicts.Refused
	end
	if Judgement.Report.Kind == "Unreadable" then
		return Verdicts.Unreadable
	end
	return Reasons.Busy
end

return {
	HoldsAbort = HoldsAbort,
	KeepCopyShowable = KeepCopyShowable,
	KeepShowable = KeepShowable,
	Showing = Showing,
	ApplyBesideMarks = ApplyBesideMarks,
}
