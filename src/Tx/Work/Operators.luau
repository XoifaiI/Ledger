--!strict
--!optimize 2

--[=[
	Operators: Pending lists a key's marks and pinned records; Resettle ends them at once, as a touch does but with no
	level step (transaction sheet 21). A resettle answers true once a landing shows no item older than its start. Both
	answer Unresolved at OpBound and for a value naming a key its store cannot hold, and an unreadable one as
	Reading/Unreadable says.

	Return type: A plain table of functions, and the PendingItem, PendingMark and PendingRecord types.
	Example usage:
		Operators.StartPending(State, Call, Commands)
		Operators.StartResettle(State, Call, Arrived, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Ends = require("../Legs/Ends")
local Events = require("../../Events")
local Marks = require("../Legs/Marks")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Reads = require("../../Reading/Reads")
local Reasons = require("../../Constants/Reasons")
local Replies = require("../../Replies")
local Rides = require("../Rides")
local Shapes = require("../../Shapes")
local Touch = require("./Touch")
local TxShapes = require("../Shapes")
local TxState = require("../State")
local Unreadable = require("../../Reading/Unreadable")
local Value = require("../../Stored/Value")
local View = require("../../Reading/View")
local Work = require("../../Stored/Items/Work")

type Answer = Events.Answer
type Command = Events.Command
type Outcome = Events.Outcome
type PendingCall = Events.PendingCall
type ReadOutcome = Events.ReadOutcome
type ResettleCall = Events.ResettleCall
type Name = Names.Name
type StoreKey = Names.StoreKey
type End = TxShapes.End
type Finished = Rides.Finished
type Request = Shapes.Request
type ServerState = Shapes.ServerState
type Mark = Work.Mark
type ReadCall = Reads.ReadCall
type State = Composed.State
type Purpose = TxState.Purpose
type PendingRead = TxState.PendingRead
type Resettle = TxState.Resettle
type ResettleWritePurpose = TxState.ResettleWritePurpose
type ResettleWaiter = TxState.ResettleWaiter

export type PendingMark = {
	read Kind: "Escrow" | "Exclusive",
	read Name: Name,
	read Stamp: number,
	read Age: number,
	read Attempt: number,
	read IsDecided: boolean,
	read Decider: StoreKey,
}

export type PendingRecord = {
	read Kind: "Pinned",
	read Name: Name,
	read Stamp: number,
	read Age: number,
	read Attempt: number,
	read IsDecided: boolean,
	read Legs: { StoreKey },
}

export type PendingItem = PendingMark | PendingRecord

local ResettledAnswer: Answer = table.freeze({ Kind = "Succeeded" :: "Succeeded", Value = true })

local function IsDecisionHeld(Server: ServerState, Key: StoreKey, Item: Mark): boolean
	for _, Held in Rides.HeldOn(Server, Key) do
		local End = Held.End
		if End.Kind == "Resolve" and Marks.IsOfUse(Item, End.Name) then
			return true
		end
		if End.Kind == "Drop" then
			for _, Dropped in End.Names do
				if Marks.IsOfUse(Item, Dropped.Name) then
					return true
				end
			end
		end
	end
	return false
end

local function NamesUnholdableKey(Server: ServerState, Key: StoreKey, Items: { Mark }): boolean
	for _, Item in Items do
		if Item.Kind ~= "Pinned" then
			if Cache.CannotHold(Server, Names.KeyOfReference(Key, Item.Decider)) then
				return true
			end
			continue
		end
		for _, Reference in Item.OtherLegs do
			if Cache.CannotHold(Server, Names.KeyOfReference(Key, Reference)) then
				return true
			end
		end
	end
	return false
end

local function PendingOf(Server: ServerState, Key: StoreKey, Item: Mark, Clock: number): PendingItem
	if Item.Kind == "Pinned" then
		local Legs: { StoreKey } = {}
		for _, Reference in Item.OtherLegs do
			table.insert(Legs, Names.KeyOfReference(Key, Reference))
		end
		return {
			Kind = "Pinned",
			Name = Item.Opening.Name,
			Stamp = Item.Opening.Stamp,
			Age = Clock - Item.Opening.Stamp,
			Attempt = Item.Opening.Attempt,
			IsDecided = IsDecisionHeld(Server, Key, Item),
			Legs = Legs,
		}
	end
	return {
		Kind = Item.Kind,
		Name = Item.Opening.Name,
		Stamp = Item.Opening.Stamp,
		Age = Clock - Item.Opening.Stamp,
		Attempt = Item.Opening.Attempt,
		IsDecided = IsDecisionHeld(Server, Key, Item),
		Decider = Names.KeyOfReference(Key, Item.Decider),
	}
end

local function Pending(State: State, Call: ReadCall, Fetched: ReadOutcome, Clock: number, Commands: { Command })
	State.Tx.PendingReads[Call.CallId] = nil
	if Fetched.Kind == "Failed" then
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Unresolved)
	end
	local Server = State.Server
	local Read = Numbers.LearnStored(Server, Call.Key, Cache.StoreOf(Server, Call.Key).Setup, Fetched, Clock)
	if Read.Kind == "Unreadable" then
		Unreadable.Warn(Server, Call.Key, Read.Cause, Commands)
		return Replies.ReplyFailed(Commands, Call.CallId, Unreadable.ReasonOf(Read.Cause))
	end
	local Held = if Read.Kind == "Kept" then Read.Kept.Book.Work else {}
	if NamesUnholdableKey(Server, Call.Key, Held) then
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Unresolved)
	end
	local Listed: { PendingItem } = {}
	for _, Item in Held do
		table.insert(Listed, PendingOf(Server, Call.Key, Item, Clock))
	end
	Replies.Reply(Commands, Call.CallId, { Kind = "Succeeded", Value = Listed })
end

local function AskRead(State: State, Purpose: Purpose, Key: StoreKey, Commands: { Command })
	local Get: Command = { Kind = "Get", RequestId = TxState.NewRequest(State.Server, State.Tx, Purpose), Target = Key }
	table.insert(Commands, Get)
end

local function StartPending(State: State, Call: PendingCall, Arrived: number, Commands: { Command })
	local Purpose: Purpose = { Kind = "PendingRead", CallId = Call.CallId, Key = Call.Key }
	local RequestId = TxState.NewRequest(State.Server, State.Tx, Purpose)
	State.Tx.PendingReads[Call.CallId] =
		{ CallId = Call.CallId, Key = Call.Key, Started = Arrived, RequestId = RequestId }
	local Get: Command = { Kind = "Get", RequestId = RequestId, Target = Call.Key }
	table.insert(Commands, Get)
end

local function StartResettle(State: State, Call: ResettleCall, Arrived: number, Commands: { Command })
	local Resettling: Resettle = { CallId = Call.CallId, Key = Call.Key, Started = Arrived }
	State.Tx.Resettles[Call.CallId] = Resettling
	local Purpose: Purpose = { Kind = "ResettleRead", CallId = Call.CallId, Key = Call.Key }
	AskRead(State, Purpose, Call.Key, Commands)
end

local function Finish(State: State, Resettling: Resettle, Given: Answer, Commands: { Command })
	State.Tx.Resettles[Resettling.CallId] = nil
	Replies.Reply(Commands, Resettling.CallId, Given)
end

local function FinishFailed(State: State, Resettling: Resettle, Reason: Reasons.Reason, Commands: { Command })
	State.Tx.Resettles[Resettling.CallId] = nil
	Replies.ReplyFailed(Commands, Resettling.CallId, Reason)
end

local function ResettleDone(State: State, Resettling: Resettle, Landed: Value.Value, Commands: { Command })
	if Landed.Kind == "Kept" then
		for _, Item in Landed.Book.Work do
			if Item.Opening.Stamp < Resettling.Started then
				return FinishFailed(State, Resettling, Reasons.Unresolved, Commands)
			end
		end
	end
	Finish(State, Resettling, ResettledAnswer, Commands)
end

local function TimeOut(State: State, Resettling: Resettle, Commands: { Command })
	FinishFailed(State, Resettling, Reasons.Unresolved, Commands)
end

local function TimeOutPending(State: State, Listing: PendingRead, Commands: { Command })
	State.Tx.PendingReads[Listing.CallId] = nil
	State.Tx.Purposes[Listing.RequestId] = nil
	Replies.ReplyFailed(Commands, Listing.CallId, Reasons.Unresolved)
end

local function SendResettleWrite(
	State: State,
	Resettling: Resettle,
	Request: Request,
	Carried: { End },
	Commands: { Command }
)
	local Purpose: Purpose =
		{ Kind = "ResettleWrite", CallId = Resettling.CallId, Key = Resettling.Key, Carried = Carried }
	Touch.SendEnds(State, Resettling.Key, Request, Purpose, Commands)
end

local function LandFresh(State: State, Resettling: Resettle, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	SendResettleWrite(State, Resettling, Reads.FreshRequest, {}, Commands)
end

local function LandResettle(State: State, Resettling: Resettle, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Carried =
		Rides.TakeFor(State.Server, Resettling.Key, Clock, { Kind = "Resettle", CallId = Resettling.CallId })
	if #Carried == 0 then
		return LandFresh(State, Resettling, Clock, Commands)
	end
	SendResettleWrite(State, Resettling, Ends.EndsRequest(Carried), Carried, Commands)
end

local function AfterResettleRead(
	State: State,
	Resettling: Resettle,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
)
	if Fetched.Kind == "Failed" then
		return FinishFailed(State, Resettling, Reasons.Unresolved, Commands)
	end
	local Server = State.Server
	local Setup = Cache.StoreOf(Server, Resettling.Key).Setup
	local Read = Numbers.LearnStored(Server, Resettling.Key, Setup, Fetched, Clock)
	if Read.Kind == "Unreadable" then
		Unreadable.Warn(Server, Resettling.Key, Read.Cause, Commands)
		return FinishFailed(State, Resettling, Unreadable.ReasonOf(Read.Cause), Commands)
	end
	if Read.Kind == "Nothing" then
		return LandResettle(State, Resettling, Clock, Commands)
	end
	if NamesUnholdableKey(Server, Resettling.Key, Read.Kept.Book.Work) then
		return FinishFailed(State, Resettling, Reasons.Unresolved, Commands)
	end
	if View.IsBehind(Setup, Read.Kept) then
		return FinishFailed(State, Resettling, Reasons.Behind, Commands)
	end
	local For: ResettleWaiter = { Kind = "Resettle", CallId = Resettling.CallId }
	for _, Item in Read.Kept.Book.Work do
		Touch.TouchItem(State, For, Resettling.Key, Item, Clock, Commands)
	end
	if not Touch.IsWorking(State, For) then
		LandResettle(State, Resettling, Clock, Commands)
	end
end

local function AfterWork(State: State, CallId: number, Clock: number, Commands: { Command })
	local Resettling = State.Tx.Resettles[CallId]
	local For: ResettleWaiter = { Kind = "Resettle", CallId = CallId }
	if Resettling ~= nil and not Touch.IsWorking(State, For) then
		LandResettle(State, Resettling, Clock, Commands)
	end
end

local function AnswerResettle(
	State: State,
	Purpose: ResettleWritePurpose,
	Result: Outcome,
	Clock: number,
	Commands: { Command }
)
	local Resettling = State.Tx.Resettles[Purpose.CallId]
	if Resettling == nil then
		return
	end
	if Result.Kind == "Err" then
		return TimeOut(State, Resettling, Commands)
	end
	if Result.Kind == "Nil" then
		if #Purpose.Carried > 0 then
			return LandFresh(State, Resettling, Clock, Commands)
		end
		local Report = Result.Note.ProbeReport
		if Report ~= nil and Report.Kind == "Missing" then
			return FinishFailed(State, Resettling, Reasons.Missing, Commands)
		end
		return TimeOut(State, Resettling, Commands)
	end
	local Setup = Cache.StoreOf(State.Server, Resettling.Key).Setup
	local Landed = Value.DecodeValue(Result.Value, Setup.Build, Setup.Limits.WindowUnit)
	if Landed == nil then
		return TimeOut(State, Resettling, Commands)
	end
	ResettleDone(State, Resettling, Landed, Commands)
end

local function OnResettleWrite(
	State: State,
	Purpose: ResettleWritePurpose,
	Result: Outcome,
	Clock: number,
	Commands: { Command }
): { Finished }
	local Finished = Touch.HearEnds(State, Purpose.Key, Purpose.Carried, Result, Commands)
	AnswerResettle(State, Purpose, Result, Clock, Commands)
	return Finished
end

return {
	Pending = Pending,
	StartPending = StartPending,
	StartResettle = StartResettle,
	AfterResettleRead = AfterResettleRead,
	AfterWork = AfterWork,
	OnResettleWrite = OnResettleWrite,
	ResettleDone = ResettleDone,
	TimeOut = TimeOut,
	TimeOutPending = TimeOutPending,
}
