--!strict
--!optimize 2

--[=[
	Rides: the ends a server's next write to a key carries (transaction 3.4, 3.5, 3.7).

	TakeFor takes none out: a write may fail. Heard takes out an end its report ends, Unreadable too, and one filed
	under a call (a help's too) reporting Missing, Behind or NoRoom. Add's and HoldFor's ends expire after OrphanAge;
	HoldFor's ride only their carrier's writes.

	Return type: A plain table with Add, AddForCall, Hold, HoldFor, HeldOn, TakeFor, CarriesDrop, TakeBack, Heard and
	Expire, and the Finished type.
	Example usage:
		Rides.AddForCall(Server, Key, Resolve, CallId)
		local Ends = Rides.TakeFor(Server, Key, Clock, { Kind = "Writer", Key = Key })
--]=]

local Cache = require("../Reading/Cache")
local JudgingShapes = require("../Judging/Shapes")
local Lookup = require("../Stored/Lookup")
local Names = require("../Encoding/Names")
local Shapes = require("../Shapes")
local TxShapes = require("./Shapes")

type StoreKey = Names.StoreKey
type Carrier = TxShapes.Carrier
type DropEnd = TxShapes.DropEnd
type End = TxShapes.End
type FenceEnd = TxShapes.FenceEnd
type HeldEnd = TxShapes.HeldEnd
type OpName = Names.OpName
type ResolveEnd = TxShapes.ResolveEnd
type Note = JudgingShapes.Note
type Report = JudgingShapes.Report
type ServerState = Shapes.ServerState

export type Finished = {
	read CallId: number,
	read Key: StoreKey,
	read End: End,
	read Report: Report,
}

local AppliedReports: { [string]: boolean } = {
	Done = true,
	Committed = true,
	Refused = true,
	Fenced = true,
	Forgotten = true,
}

local RefusedReports: { [string]: boolean } = {
	Missing = true,
	Behind = true,
	NoRoom = true,
}

local function IsEnded(Report: Report): boolean
	return AppliedReports[Report.Kind] == true or Report.Kind == "Unreadable"
end

local function IsTakenOut(Report: Report, CallId: number?): boolean
	return IsEnded(Report) or (CallId ~= nil and RefusedReports[Report.Kind] == true)
end

local function IsSameUse(Held: End, Added: End): boolean
	if Held.Kind == "Drop" or Added.Kind == "Drop" then
		return false
	end
	return Held.Kind == Added.Kind and Lookup.IsSameOp(Held.Name, Added.Name)
end

local function IsFreeToReplace(Older: HeldEnd, Added: HeldEnd): boolean
	return Older.CallId == nil or Older.CallId == Added.CallId
end

local function IsPastTime(Held: HeldEnd, Clock: number): boolean
	return Held.Until ~= nil and Clock >= Held.Until
end

local function CarrierText(For: Carrier): string
	if For.Kind == "Writer" or For.Kind == "Touch" then
		return For.Kind .. Names.KeyText(For.Key)
	end
	return For.Kind .. tostring(For.CallId)
end

local function IsCarriedBy(Held: HeldEnd, Taker: Carrier): boolean
	local For = Held.For
	return For == nil or CarrierText(For) == CarrierText(Taker)
end

local function Put(Server: ServerState, Key: StoreKey, Added: HeldEnd)
	local Text = Names.KeyText(Key)
	local Held = Server.Rides[Text]
	if Held == nil then
		Server.Rides[Text] = { Added }
		return
	end
	for Index, Older in Held do
		if IsSameUse(Older.End, Added.End) and IsFreeToReplace(Older, Added) then
			Held[Index] = Added
			return
		end
	end
	table.insert(Held, Added)
end

local function ForgetIfNoneHeld(Server: ServerState, Text: string)
	local Held = Server.Rides[Text]
	if Held ~= nil and #Held == 0 then
		Server.Rides[Text] = nil
	end
end

local function ForgetPastTime(Server: ServerState, Text: string, Clock: number)
	local Held = Server.Rides[Text]
	if Held == nil then
		return
	end
	for Index = #Held, 1, -1 do
		if IsPastTime(Held[Index], Clock) then
			table.remove(Held, Index)
		end
	end
	ForgetIfNoneHeld(Server, Text)
end

local function IndexOfEnd(Held: { HeldEnd }, End: End): number?
	for Index, Each in Held do
		if Each.End == End then
			return Index
		end
	end
	return nil
end

local function OrphanAgeOf(Server: ServerState, Key: StoreKey): number
	return Cache.StoreOf(Server, Key).Setup.Limits.OrphanAge
end

local function Add(Server: ServerState, Key: StoreKey, End: End, Clock: number)
	Put(Server, Key, { End = End, CallId = nil, Until = Clock + OrphanAgeOf(Server, Key), For = nil })
end

local function AddForCall(Server: ServerState, Key: StoreKey, End: ResolveEnd | FenceEnd, CallId: number)
	Put(Server, Key, { End = End, CallId = CallId, Until = nil, For = nil })
end

local function Hold(Server: ServerState, Key: StoreKey, End: DropEnd, Until: number)
	Put(Server, Key, { End = End, CallId = nil, Until = Until, For = nil })
end

local function HoldFor(Server: ServerState, Key: StoreKey, End: DropEnd, For: Carrier, Clock: number)
	Put(Server, Key, { End = End, CallId = nil, Until = Clock + OrphanAgeOf(Server, Key), For = For })
end

local function HeldOn(Server: ServerState, Key: StoreKey): { HeldEnd }
	return Server.Rides[Names.KeyText(Key)] or {}
end

local function TakeFor(Server: ServerState, Key: StoreKey, Clock: number, Taker: Carrier): { End }
	ForgetPastTime(Server, Names.KeyText(Key), Clock)
	local Carried: { End } = {}
	for _, Held in HeldOn(Server, Key) do
		if IsCarriedBy(Held, Taker) then
			table.insert(Carried, Held.End)
		end
	end
	return Carried
end

local function CarriesDrop(Server: ServerState, Key: StoreKey, Clock: number, Taker: Carrier): boolean
	for _, End in TakeFor(Server, Key, Clock, Taker) do
		if End.Kind == "Drop" then
			return true
		end
	end
	return false
end

local function TakeBack(Server: ServerState, Key: StoreKey, CallId: number, Name: OpName): boolean
	local Text = Names.KeyText(Key)
	local Held = Server.Rides[Text]
	if Held == nil then
		return false
	end
	for Index, Each in Held do
		local End = Each.End
		if Each.CallId == CallId and End.Kind == "Resolve" and Lookup.IsSameOp(End.Name, Name) then
			table.remove(Held, Index)
			ForgetIfNoneHeld(Server, Text)
			return true
		end
	end
	return false
end

local function Heard(Server: ServerState, Key: StoreKey, Carried: { End }, Note: Note): { Finished }
	local Text = Names.KeyText(Key)
	local Held = Server.Rides[Text]
	local Finished: { Finished } = {}
	if Held == nil then
		return Finished
	end
	for Position, End in Carried do
		local Report = Note.EndReports[Position]
		local At = IndexOfEnd(Held, End)
		if Report == nil or At == nil then
			continue
		end
		local CallId = Held[At].CallId
		if not IsTakenOut(Report, CallId) then
			continue
		end
		table.remove(Held, At)
		if CallId ~= nil then
			table.insert(Finished, { CallId = CallId, Key = Key, End = End, Report = Report })
		end
	end
	ForgetIfNoneHeld(Server, Text)
	return Finished
end

local function Expire(Server: ServerState, Clock: number)
	for Text in Server.Rides do
		ForgetPastTime(Server, Text, Clock)
	end
end

return {
	Add = Add,
	AddForCall = AddForCall,
	Hold = Hold,
	HoldFor = HoldFor,
	HeldOn = HeldOn,
	TakeFor = TakeFor,
	CarriesDrop = CarriesDrop,
	TakeBack = TakeBack,
	Heard = Heard,
	Expire = Expire,
}
