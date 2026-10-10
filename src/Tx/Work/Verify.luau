--!strict
--!optimize 2

--[=[
	Verify: pinned records' verification and the drops it earns (transaction sheet 17; 18.4's ProveGone of a missing
	leg). A record drops once every other leg of its use is resolved. Drops ride the waiter's own writes; a help's or
	read's ride any. Verify itself picks records from the server-number offset. Unreachable legs go unread; nothing goes
	past the close deadline.

	Return type: A plain table with FromOffset, Start, StartOwed, OnRead, OnResolve, VerifiedDrops, ProveCommands,
	OnProve, AfterProves and ProveDrop.
	Example usage:
		local VerifyId = Verify.Start(State, Waiter, Decider, Records, Clock, Commands)
--]=]

local Book = require("../../Stored/Book")
local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Ends = require("../Legs/Ends")
local Events = require("../../Events")
local Marks = require("../Legs/Marks")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Removal = require("../../Cuts/Seals/Removal")
local Rides = require("../Rides")
local Shapes = require("../../Shapes")
local TxShapes = require("../Shapes")
local TxState = require("../State")
local Work = require("../../Stored/Items/Work")

type Book = Book.Book
type Carrier = TxShapes.Carrier
type Command = Events.Command
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type KeyReference = Names.KeyReference
type StoreKey = Names.StoreKey
type Request = Shapes.Request
type DropEnd = TxShapes.DropEnd
type DroppedName = TxShapes.DroppedName
type ResolveEnd = TxShapes.ResolveEnd
type MarkOpening = Work.MarkOpening
type PinnedRecord = Work.PinnedRecord
type State = Composed.State
type Purpose = TxState.Purpose
type Verify = TxState.Verify
type Waiter = TxState.Waiter

local ProveGoneRequest: Request = table.freeze({ Kind = "ProveGone" :: "ProveGone" })

local function FromOffset<Item>(Items: { Item }, ServerNumber: number): { Item }
	local Count = #Items
	local Rotated: { Item } = {}
	if Count == 0 then
		return Rotated
	end
	local Offset = ServerNumber % Count
	for Step = 0, Count - 1 do
		table.insert(Rotated, Items[(Offset + Step) % Count + 1])
	end
	return Rotated
end

local function LegKey(Verification: Verify, Reference: KeyReference): StoreKey
	return Names.KeyOfReference(Verification.Decider, Reference)
end

local function AskLeg(
	State: State,
	Verification: Verify,
	Record: number,
	Leg: StoreKey,
	Clock: number,
	Commands: { Command }
)
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Purpose: Purpose = { Kind = "VerifyRead", VerifyId = Verification.Id, Record = Record, Key = Leg }
	local Get: Command = { Kind = "Get", RequestId = TxState.NewRequest(State.Server, State.Tx, Purpose), Target = Leg }
	table.insert(Commands, Get)
end

local function Begin(
	State: State,
	For: Waiter,
	Decider: StoreKey,
	FromTheOffset: { PinnedRecord },
	Clock: number,
	Commands: { Command }
): number?
	local Server = State.Server
	local Verification: Verify = {
		Id = TxState.NextId(State.Tx),
		Decider = Decider,
		Records = FromTheOffset,
		Resolved = {},
		Missing = {},
		Cancelled = false,
		IsProving = false,
		Left = 0,
		Seals = {},
		For = For,
	}
	for Index, Record in Verification.Records do
		Verification.Resolved[Index] = {}
		Verification.Missing[Index] = {}
		for _, Reference in Record.OtherLegs do
			local Leg = LegKey(Verification, Reference)
			if Cache.IsReachable(Server, Leg) then
				AskLeg(State, Verification, Index, Leg, Clock, Commands)
				Verification.Left += 1
			end
		end
	end
	if Verification.Left == 0 then
		return nil
	end
	State.Tx.Verifies[Verification.Id] = Verification
	return Verification.Id
end

local function Start(
	State: State,
	For: Waiter,
	Decider: StoreKey,
	Records: { PinnedRecord },
	Clock: number,
	Commands: { Command }
): number?
	local FromTheOffset = FromOffset(Records, Numbers.ServerNumberOf(State.Server))
	return Begin(State, For, Decider, FromTheOffset, Clock, Commands)
end

local function StartOwed(
	State: State,
	For: Waiter,
	Decider: StoreKey,
	Listed: { PinnedRecord },
	Clock: number,
	Commands: { Command }
): number?
	local Server = State.Server
	local Most = Cache.StoreOf(Server, Decider).Setup.Limits.OwedRecordsVerified
	local Chosen: { PinnedRecord } = {}
	for _, Record in FromOffset(Listed, Numbers.ServerNumberOf(Server)) do
		if #Chosen < Most then
			table.insert(Chosen, Record)
		end
	end
	return Begin(State, For, Decider, Chosen, Clock, Commands)
end

local function IsResolvedOn(Held: Book, Opening: MarkOpening): boolean
	local Name = Marks.OpNameOf(Opening)
	if Marks.OwnMarkOf(Held, Name) ~= nil then
		return false
	end
	if Marks.OwnEntryOf(Held, Name) ~= nil then
		return true
	end
	return Marks.IsForgotten(Held, Name, Opening.Stamp)
end

local function DroppedName(Pinned: PinnedRecord): DroppedName
	local Opening = Pinned.Opening
	return { Name = Marks.OpNameOf(Opening), Stamp = Opening.Stamp, Proved = nil }
end

local function ProvedDroppedName(Pinned: PinnedRecord, Proved: KeyReference): DroppedName
	local Opening = Pinned.Opening
	return { Name = Marks.OpNameOf(Opening), Stamp = Opening.Stamp, Proved = Proved }
end

local function IsRecordResolved(Verification: Verify, Record: number): boolean
	local Resolved = Verification.Resolved[Record]
	for _, Reference in Verification.Records[Record].OtherLegs do
		if not Resolved[Names.KeyText(LegKey(Verification, Reference))] then
			return false
		end
	end
	return true
end

local function VerifiedDrops(Verification: Verify): { DroppedName }
	local Dropped: { DroppedName } = {}
	for Index, Pinned in Verification.Records do
		if IsRecordResolved(Verification, Index) then
			table.insert(Dropped, DroppedName(Pinned))
		end
	end
	return Dropped
end

local function CarrierOf(For: Waiter): Carrier?
	if For.Kind == "Help" or For.Kind == "Read" then
		return nil
	end
	return For
end

local function HoldDrops(State: State, Verification: Verify, Dropped: { DroppedName }, Clock: number)
	if #Dropped == 0 then
		return
	end
	local Server = State.Server
	local Drop: DropEnd = { Kind = "Drop", Names = Dropped }
	local Carrier = CarrierOf(Verification.For)
	if Carrier == nil then
		return Rides.Add(Server, Verification.Decider, Drop, Clock)
	end
	Rides.HoldFor(Server, Verification.Decider, Drop, Carrier, Clock)
end

local function SendProve(State: State, Verification: Verify, Leg: StoreKey, Clock: number, Commands: { Command })
	Verification.Left += 1
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Purpose: Purpose = { Kind = "Prove", VerifyId = Verification.Id, Key = Leg }
	local Update: Command = {
		Kind = "Update",
		RequestId = TxState.NewRequest(State.Server, State.Tx, Purpose),
		Target = Leg,
		Request = ProveGoneRequest,
	}
	table.insert(Commands, Update)
end

local function IsProvable(Verification: Verify, Record: number): boolean
	local Missing = Verification.Missing[Record]
	if next(Missing) == nil then
		return false
	end
	local Resolved = Verification.Resolved[Record]
	for _, Reference in Verification.Records[Record].OtherLegs do
		local Text = Names.KeyText(LegKey(Verification, Reference))
		if not Resolved[Text] and Missing[Text] == nil then
			return false
		end
	end
	return true
end

local function ProveCommands(State: State, Verification: Verify, Clock: number, Commands: { Command }): boolean
	local ToProve: { StoreKey } = {}
	local IsListed: { [string]: boolean } = {}
	for Index, Pinned in Verification.Records do
		if not IsProvable(Verification, Index) then
			continue
		end
		for _, Reference in Pinned.OtherLegs do
			local Leg = LegKey(Verification, Reference)
			local Text = Names.KeyText(Leg)
			if Verification.Missing[Index][Text] ~= nil and not IsListed[Text] then
				IsListed[Text] = true
				table.insert(ToProve, Leg)
			end
		end
	end
	for _, Leg in ToProve do
		SendProve(State, Verification, Leg, Clock, Commands)
	end
	Verification.IsProving = #ToProve > 0
	return Verification.IsProving
end

local function FirstProvedLeg(Verification: Verify, Pinned: PinnedRecord): KeyReference?
	for _, Reference in Pinned.OtherLegs do
		if Verification.Seals[Names.KeyText(LegKey(Verification, Reference))] ~= nil then
			return Reference
		end
	end
	return nil
end

local function ProveDrop(State: State, Verification: Verify, Clock: number, Commands: { Command })
	local Dropped: { DroppedName } = {}
	for Index, Pinned in Verification.Records do
		if IsProvable(Verification, Index) then
			local Proved = FirstProvedLeg(Verification, Pinned)
			if Proved == nil then
				table.insert(Dropped, DroppedName(Pinned))
			else
				table.insert(Dropped, ProvedDroppedName(Pinned, Proved))
			end
		end
	end
	HoldDrops(State, Verification, Dropped, Clock)
	Removal.RemoveProofSeals(State, Verification, Clock, Commands)
end

local function AfterProves(State: State, Verification: Verify, Clock: number, Commands: { Command })
	if Verification.Cancelled then
		return Removal.RemoveProofSeals(State, Verification, Clock, Commands)
	end
	ProveDrop(State, Verification, Clock, Commands)
end

local function RequestHeard(State: State, Verification: Verify, Clock: number, Commands: { Command }): Waiter?
	Verification.Left -= 1
	if Verification.Left > 0 then
		return nil
	end
	if Verification.IsProving then
		AfterProves(State, Verification, Clock, Commands)
	else
		HoldDrops(State, Verification, VerifiedDrops(Verification), Clock)
		if ProveCommands(State, Verification, Clock, Commands) then
			return nil
		end
	end
	State.Tx.Verifies[Verification.Id] = nil
	return Verification.For
end

local function SendResolve(
	State: State,
	Verification: Verify,
	Record: number,
	Leg: StoreKey,
	Clock: number,
	Commands: { Command }
)
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Pinned = Verification.Records[Record]
	local Opening = Pinned.Opening
	local Resolve: ResolveEnd = {
		Kind = "Resolve",
		Name = Marks.OpNameOf(Opening),
		Stamp = Opening.Stamp,
		Attempt = Opening.Attempt,
		Outcome = "Commit",
		Decider = Names.ReferenceTo(Leg, Verification.Decider),
		DeciderValue = Pinned.DeciderValue,
	}
	local Purpose: Purpose = { Kind = "VerifyResolve", VerifyId = Verification.Id, Record = Record, Key = Leg }
	local Update: Command = {
		Kind = "Update",
		RequestId = TxState.NewRequest(State.Server, State.Tx, Purpose),
		Target = Leg,
		Request = Ends.EndsRequest({ Resolve }),
	}
	table.insert(Commands, Update)
end

local function OnRead(
	State: State,
	Verification: Verify,
	Record: number,
	Leg: StoreKey,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
): Waiter?
	if Fetched.Kind == "Failed" then
		return RequestHeard(State, Verification, Clock, Commands)
	end
	local Server = State.Server
	local Read = Numbers.LearnStored(Server, Leg, Cache.StoreOf(Server, Leg).Setup, Fetched, Clock)
	if Read.Kind == "Unreadable" then
		return RequestHeard(State, Verification, Clock, Commands)
	end
	local Opening = Verification.Records[Record].Opening
	if Read.Kind == "Kept" and IsResolvedOn(Read.Kept.Book, Opening) then
		Verification.Resolved[Record][Names.KeyText(Leg)] = true
		return RequestHeard(State, Verification, Clock, Commands)
	end
	SendResolve(State, Verification, Record, Leg, Clock, Commands)
	return nil
end

local function OnResolve(
	State: State,
	Verification: Verify,
	Record: number,
	Leg: StoreKey,
	Outcome: Outcome,
	Clock: number,
	Commands: { Command }
): Waiter?
	if Outcome.Kind ~= "Err" then
		Numbers.SeeLeftOver(State.Server, Leg, Outcome.Note)
	end
	local Report = Ends.LoneEndReport(Outcome)
	if Report ~= nil and Report.Kind == "Done" then
		Verification.Resolved[Record][Names.KeyText(Leg)] = true
	elseif Report ~= nil and Report.Kind == "Missing" then
		Verification.Missing[Record][Names.KeyText(Leg)] = Leg
	end
	return RequestHeard(State, Verification, Clock, Commands)
end

local function OnProve(
	State: State,
	Verification: Verify,
	Leg: StoreKey,
	Outcome: Outcome,
	Clock: number,
	Commands: { Command }
): Waiter?
	local Report = if Outcome.Kind == "Ok" then Outcome.Note.ProbeReport else nil
	if Report ~= nil and Report.Kind == "Proved" then
		Verification.Seals[Names.KeyText(Leg)] = { Key = Leg, RemovalStamp = Report.RemovalStamp }
	else
		Verification.Cancelled = true
	end
	return RequestHeard(State, Verification, Clock, Commands)
end

return {
	FromOffset = FromOffset,
	Start = Start,
	StartOwed = StartOwed,
	OnRead = OnRead,
	OnResolve = OnResolve,
	VerifiedDrops = VerifiedDrops,
	ProveCommands = ProveCommands,
	OnProve = OnProve,
	AfterProves = AfterProves,
	ProveDrop = ProveDrop,
}
