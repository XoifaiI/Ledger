--!strict
--!optimize 2

--[=[
	Parts: Logic. A split quantity's parts, the ops a part takes, and the one reducer every part runs.

	A quantity of m parts keeps part i under the key $P:<name>:<m>:<i>. Each part is a record whose
	state is Ledger's own: the print of its declaration, the clock it was opened, its free and sold
	units, its holds, the Sealed and Closed flags, and one field for each proceeds field the
	declaration names. A quantity with serials gives each part its own range, and a part draws from
	its returned serials first, smallest first. The key holds the default, an empty table, until an
	Open lands.

	Open does nothing on a part that exists, and every other op is refused Invalid on a part opened
	under another declaration. A credit on a part with serials is refused Invalid too, since only
	another declaration sends one. A confirm with no hold standing takes as Take does, and is refused
	Gone when that refuses. Release always writes. A refusal by Guard, for a money field or the state
	cap, has no reason here. A delta leg may move units out of any part, and into a part that is open
	and not shut.

	Upkeep runs on every write. It expires each hold whose end the clock passed by HOLD_SLACK, or
	whose end is more than HOLD_MAX and the slack ahead. In final mode it then seals a part with no
	free unit, no hold, no returned serial and no escrow mark. Nothing clears Sealed or Closed. The
	field names of the state and the Kind strings of the ops are stored, so none may change. KIND
	measures a part's free, held and sold units, and 1 when it is shut, for the summary path of
	Shards.

	Return type: The Parts module, and the Mode, Declared, Hold, Part, Reason, Price, Portion and op
	types.
	Example usage:
		local Using = Parts.Build(Base, Declared)
--]=]

local Key = require("./Key")
local Types = require("./Types")
local Windows = require("../Core/Constants/Windows")

local PREFIX = "$P:"

local MODE = {
	Final = "Final" :: "Final",
	Open = "Open" :: "Open",
}

export type Mode = keyof<typeof(MODE)>

local OP = {
	Open = "Open" :: "Open",
	Take = "Take" :: "Take",
	Hold = "Hold" :: "Hold",
	Confirm = "Confirm" :: "Confirm",
	Release = "Release" :: "Release",
	Credit = "Credit" :: "Credit",
	Close = "Close" :: "Close",
}

local REASON = {
	Invalid = "Invalid" :: "Invalid",
	Closed = "Closed" :: "Closed",
	Sealed = "Sealed" :: "Sealed",
	Holds = "Holds" :: "Holds",
	Held = "Held" :: "Held",
	Free = "Free" :: "Free",
	Gone = "Gone" :: "Gone",
}

export type Reason = keyof<typeof(REASON)>

export type Declared = {
	read Name: string,
	read Parts: number,
	read Mode: Mode,
	read Stock: number,
	read First: number?,
	read Proceeds: { string },
	read Print: number,
	read Place: string,
}

export type Hold = {
	read Id: string,
	read Count: number,
	read End: number,
	read Serials: { number }?,
}

export type Part = {
	read Print: number,
	read Opened: number,
	read Free: number,
	read Sold: number,
	read Sealed: boolean?,
	read Closed: boolean?,
	read Holds: { Hold },
	read Next: number?,
	read Last: number?,
	read Returned: { number }?,
	read Issued: number?,
	read [string]: number,
}

type Making = {
	Print: number,
	Opened: number,
	Free: number,
	Sold: number,
	Sealed: boolean?,
	Closed: boolean?,
	Holds: { Hold },
	Next: number?,
	Last: number?,
	Returned: { number }?,
	Issued: number?,
	[string]: number,
}

export type Price = { [string]: number }

export type OpenOp = { read Kind: "Open", read Share: number, read At: number, read From: number? }
export type TakeOp = { read Kind: "Take", read Print: number, read Count: number, read Price: Price? }
export type HoldOp = { read Kind: "Hold", read Print: number, read Id: string, read Count: number, read End: number }
export type ConfirmOp = { read Kind: "Confirm", read Print: number, read Id: string, read Count: number, read Price: Price? }
export type ReleaseOp = { read Kind: "Release", read Print: number, read Id: string }
export type CreditOp = { read Kind: "Credit", read Print: number, read Count: number }
export type CloseOp = { read Kind: "Close", read Print: number }
export type Op = OpenOp | TakeOp | HoldOp | ConfirmOp | ReleaseOp | CreditOp | CloseOp

export type Portion = {
	read Index: number,
	read Count: number,
}

type Drawn = {
	read Next: number?,
	read Returned: { number }?,
	read Serials: { number }?,
}

local FIELDS: { [string]: true } = {
	Print = true,
	Opened = true,
	Free = true,
	Sold = true,
	Sealed = true,
	Closed = true,
	Holds = true,
	Next = true,
	Last = true,
	Returned = true,
	Issued = true,
}

local SPLIT_MAX = 64
local SPLIT_NAME = 37
local PROCEEDS_MAX = 4
local HOLDS_MAX = 256
local HOLD_MAX = 15 * 60
local HOLD_SLACK = 2 * Windows.SIGMA
local PROBES = 3
local VIEW_AGE = 30
local PACE_PART = 1

local MEASURES = 4

local SLOT = {
	Free = 1,
	Held = 2,
	Sold = 3,
	Shut = 4,
}

local Parts = {
	PREFIX = PREFIX,
	MODE = MODE,
	OP = OP,
	REASON = REASON,
	FIELDS = FIELDS,
	SPLIT_MAX = SPLIT_MAX,
	SPLIT_NAME = SPLIT_NAME,
	PROCEEDS_MAX = PROCEEDS_MAX,
	HOLDS_MAX = HOLDS_MAX,
	HOLD_MAX = HOLD_MAX,
	HOLD_SLACK = HOLD_SLACK,
	PROBES = PROBES,
	VIEW_AGE = VIEW_AGE,
	SLOT = SLOT,
}

local function AsOpened(State: any): Part?
	if type(State) ~= "table" or State.Opened == nil then
		return nil
	end
	return State
end

local function OpenedUnder(State: any, Print: number): Part?
	local Part = AsOpened(State)
	if Part == nil or Part.Print ~= Print then
		return nil
	end
	return Part
end

local function IsShut(Part: Part): boolean
	return Part.Closed == true or Part.Sealed == true
end

local function HasSerials(Part: Part): boolean
	return Part.Next ~= nil
end

local function HeldUnits(Holds: { Hold }): number
	local Total = 0
	for _, Each in Holds do
		Total += Each.Count
	end
	return Total
end

local function NothingLeft(Free: number, Holds: { Hold }, Returned: { number }?): boolean
	if Free ~= 0 or Holds[1] ~= nil then
		return false
	end
	return Returned == nil or Returned[1] == nil
end

local function WithoutHold(Holds: { Hold }, Id: string): ({ Hold }, Hold?)
	local Kept: { Hold } = {}
	local Found: Hold? = nil
	for _, Each in Holds do
		if Each.Id == Id then
			Found = Each
		else
			table.insert(Kept, Each)
		end
	end
	return Kept, Found
end

local function GiveBack(Returned: { number }?, Serials: { number }?): { number }?
	if Serials == nil then
		return Returned
	end
	local Made = table.clone(Returned or {})
	table.move(Serials, 1, #Serials, #Made + 1, Made)
	table.sort(Made)
	return Made
end

local function Draw(Part: Part, Count: number): Drawn
	local Next = Part.Next
	if Next == nil then
		return { Returned = Part.Returned }
	end
	local Returned = table.clone(Part.Returned or {})
	local Serials: { number } = {}
	for _ = 1, Count do
		if Returned[1] then
			table.insert(Serials, table.remove(Returned, 1) :: number)
		else
			table.insert(Serials, Next)
			Next += 1
		end
	end
	return { Next = Next, Returned = Returned, Serials = Serials }
end

local function FirstSerial(Serials: { number }?): number?
	return if Serials then Serials[1] else nil
end

local function NextPart(Part: Part): Making
	local Made = table.clone(Part) :: Making
	-- Issued is the first serial the write that made this version issued, and Output reads it
	Made.Issued = nil
	return Made
end

local function Pay(Made: Making, Price: Price?)
	if Price == nil then
		return
	end
	for Field, Amount in Price do
		Made[Field] += Amount
	end
end

local function NewPart(Declared: Declared, Op: OpenOp): Part
	local From = Op.From
	local Made: Making = {
		Print = Declared.Print,
		Opened = Op.At,
		Free = Op.Share,
		Sold = 0,
		Holds = {},
		Next = From,
		Last = if From then From + Op.Share else nil,
	}
	for _, Field in Declared.Proceeds do
		Made[Field] = 0
	end
	return Made
end

local function ShutReason(Part: Part): Reason?
	if Part.Closed then
		return REASON.Closed
	elseif Part.Sealed then
		return REASON.Sealed
	end
	return nil
end

local function ShortReason(Part: Part, Count: number): Reason
	if Part.Free + HeldUnits(Part.Holds) >= Count then
		return REASON.Held
	end
	return REASON.Free
end

local function DecideTake(Part: Part, Count: number, Price: Price?): Part | Reason
	local Shut = ShutReason(Part)
	if Shut then
		return Shut
	elseif Part.Free < Count then
		return ShortReason(Part, Count)
	end
	local Drew = Draw(Part, Count)
	local Made = NextPart(Part)
	Made.Free = Part.Free - Count
	Made.Sold = Part.Sold + Count
	Made.Next = Drew.Next
	Made.Returned = Drew.Returned
	Made.Issued = FirstSerial(Drew.Serials)
	Pay(Made, Price)
	return Made
end

local function DecideHold(Part: Part, Op: HoldOp): Part | Reason
	local Shut = ShutReason(Part)
	if Shut then
		return Shut
	elseif Part.Free < Op.Count then
		return ShortReason(Part, Op.Count)
	elseif #Part.Holds >= HOLDS_MAX then
		return REASON.Holds
	end
	local Drew = Draw(Part, Op.Count)
	local Holds = table.clone(Part.Holds)
	table.insert(Holds, { Id = Op.Id, Count = Op.Count, End = Op.End, Serials = Drew.Serials })
	local Made = NextPart(Part)
	Made.Free = Part.Free - Op.Count
	Made.Holds = Holds
	Made.Next = Drew.Next
	Made.Returned = Drew.Returned
	return Made
end

local function DecideConfirm(Part: Part, Op: ConfirmOp): Part | Reason
	local Holds, Found = WithoutHold(Part.Holds, Op.Id)
	if Found == nil then
		local Taken = DecideTake(Part, Op.Count, Op.Price)
		return if type(Taken) == "string" then REASON.Gone else Taken
	end
	local Made = NextPart(Part)
	Made.Sold = Part.Sold + Found.Count
	Made.Holds = Holds
	Made.Issued = FirstSerial(Found.Serials)
	Pay(Made, Op.Price)
	return Made
end

local function DecideRelease(Part: Part, Op: ReleaseOp): Part
	local Holds, Found = WithoutHold(Part.Holds, Op.Id)
	if Found == nil then
		return Part
	end
	local Made = NextPart(Part)
	Made.Free = Part.Free + Found.Count
	Made.Holds = Holds
	Made.Returned = GiveBack(Part.Returned, Found.Serials)
	return Made
end

local function DecideCredit(Part: Part, Op: CreditOp): Part | Reason
	local Shut = ShutReason(Part)
	if Shut then
		return Shut
	elseif HasSerials(Part) then
		return REASON.Invalid
	end
	local Made = NextPart(Part)
	Made.Free = Part.Free + Op.Count
	return Made
end

local function DecideClose(Part: Part): Part
	local Made = NextPart(Part)
	Made.Closed = true
	return Made
end

local function Decide(Declared: Declared, State: any, Op: Op): Part | Reason
	if Op.Kind == OP.Open then
		local Existing = AsOpened(State)
		if Existing then
			return Existing
		end
		return NewPart(Declared, Op)
	end
	local Part = OpenedUnder(State, Op.Print)
	if Part == nil then
		return REASON.Invalid
	elseif Op.Kind == OP.Take then
		return DecideTake(Part, Op.Count, Op.Price)
	elseif Op.Kind == OP.Hold then
		return DecideHold(Part, Op)
	elseif Op.Kind == OP.Confirm then
		return DecideConfirm(Part, Op)
	elseif Op.Kind == OP.Release then
		return DecideRelease(Part, Op)
	elseif Op.Kind == OP.Credit then
		return DecideCredit(Part, Op)
	elseif Op.Kind == OP.Close then
		return DecideClose(Part)
	end
	-- a kind this build does not know, sent by a newer build during a deploy
	return REASON.Invalid
end

local function Lapsed(Each: Hold, Clock: number): boolean
	return Clock > Each.End + HOLD_SLACK or Each.End > Clock + HOLD_MAX + HOLD_SLACK
end

local function Upkeep(Declared: Declared, State: any, Clock: number, Marked: boolean): any
	local Part = AsOpened(State)
	if Part == nil then
		return State
	end
	local Kept: { Hold } = {}
	local Freed = 0
	local Returned = Part.Returned
	for _, Each in Part.Holds do
		if Lapsed(Each, Clock) then
			Freed += Each.Count
			Returned = GiveBack(Returned, Each.Serials)
		else
			table.insert(Kept, Each)
		end
	end
	local Free = Part.Free + Freed
	local Seals = Declared.Mode == MODE.Final and not Part.Sealed and not Marked and NothingLeft(Free, Kept, Returned)
	if Freed == 0 and not Seals then
		return State
	end
	local Made = NextPart(Part)
	Made.Free = Free
	Made.Holds = Kept
	Made.Returned = Returned
	if Seals then
		Made.Sealed = true
	end
	return Made
end

local function Accepts(State: any, Amount: number): boolean
	if Amount <= 0 then
		return true
	end
	local Part = AsOpened(State)
	if Part == nil then
		return false
	end
	return not IsShut(Part)
end

local function Measure(State: any): { number }?
	local Part = AsOpened(State)
	if Part == nil then
		return nil
	end
	local Values = table.create(MEASURES, 0)
	Values[SLOT.Free] = Part.Free
	Values[SLOT.Held] = HeldUnits(Part.Holds)
	Values[SLOT.Sold] = Part.Sold
	Values[SLOT.Shut] = if IsShut(Part) then 1 else 0
	return Values
end

local function SeenFree(Free: { [number]: number }, Index: number): number
	return Free[Index] or 0
end

Parts.KIND = { Prefix = PREFIX, Width = MEASURES, Measure = Measure }

function Parts.Key(Name: string, Count: number, Index: number): string
	return `{PREFIX}{Name}:{Count}:{Index}`
end

function Parts.Share(Stock: number, Count: number, Index: number): number
	return Stock * (Index + 1) // Count - Stock * Index // Count
end

function Parts.From(Declared: Declared, Index: number): number?
	local First = Declared.First
	return if First then First + Declared.Stock * Index // Declared.Parts else nil
end

function Parts.OpenOp(Share: number, At: number, From: number?): OpenOp
	return { Kind = OP.Open, Share = Share, At = At, From = From }
end

function Parts.TakeOp(Print: number, Count: number, Price: Price?): TakeOp
	return { Kind = OP.Take, Print = Print, Count = Count, Price = Price }
end

function Parts.HoldOp(Print: number, Id: string, Count: number, End: number): HoldOp
	return { Kind = OP.Hold, Print = Print, Id = Id, Count = Count, End = End }
end

function Parts.ConfirmOp(Print: number, Id: string, Count: number, Price: Price?): ConfirmOp
	return { Kind = OP.Confirm, Print = Print, Id = Id, Count = Count, Price = Price }
end

function Parts.ReleaseOp(Print: number, Id: string): ReleaseOp
	return { Kind = OP.Release, Print = Print, Id = Id }
end

function Parts.CreditOp(Print: number, Count: number): CreditOp
	return { Kind = OP.Credit, Print = Print, Count = Count }
end

function Parts.CloseOp(Print: number): CloseOp
	return { Kind = OP.Close, Print = Print }
end

function Parts.Units(Op: Op): number
	if Op.Kind == OP.Take or Op.Kind == OP.Hold or Op.Kind == OP.Confirm or Op.Kind == OP.Credit then
		return Op.Count
	end
	return 0
end

function Parts.Build(Base: Types.Build, Declared: Declared): Types.Build
	local Fields = table.clone(FIELDS)
	local Money = { "Free" }
	for _, Field in Declared.Proceeds do
		Fields[Field] = true
		table.insert(Money, Field)
	end
	local Made: Types.Build = {
		Reducer = function(State: any, Op: any): unknown
			local Decided = Decide(Declared, State, Op)
			if type(Decided) == "string" then
				return nil
			end
			return Decided
		end,
		Migrations = {},
		Default = {},
		Level = 0,
		Floor = 0,
		Money = Money,
		Fields = Fields,
		Erasable = false,
		Window = {},
		Minted = Base.Minted,
		CutWindow = Base.CutWindow,
		TimedRoom = Base.TimedRoom,
		UntimedRoom = 0,
		WorkRoom = Base.WorkRoom,
		CutNames = Base.CutNames,
		LossRoom = Base.LossRoom,
		KeepNamed = Base.KeepNamed,
		LegLimit = Base.LegLimit,
		StateCap = Base.StateCap,
		Ahead = Base.Ahead,
		Hold = Base.Hold,
		Paced = PACE_PART,
		Upkeep = function(State: any, Clock: number, Marked: boolean): any
			return Upkeep(Declared, State, Clock, Marked)
		end,
		Output = function(State: any): number?
			local Part = AsOpened(State)
			return if Part then Part.Issued else nil
		end,
		Accepts = function(State: any, _: number, Amount: number): boolean
			return Accepts(State, Amount)
		end,
	}
	return Made
end

function Parts.Opened(Declared: Declared, State: unknown): Part?
	return OpenedUnder(State, Declared.Print)
end

function Parts.IsShut(Part: Part): boolean
	return IsShut(Part)
end

function Parts.Refusal(Declared: Declared, State: unknown, Op: Op): Reason?
	local Decided = Decide(Declared, State, Op)
	if type(Decided) == "string" then
		return Decided
	end
	return nil
end

function Parts.Empty(Part: Part, Declared: Declared): boolean
	if not NothingLeft(Part.Free, Part.Holds, Part.Returned) then
		return false
	end
	for _, Field in Declared.Proceeds do
		if Part[Field] ~= 0 then
			return false
		end
	end
	return true
end

function Parts.Read(Value: unknown): Part?
	local Found = Key.Read(Value)
	if type(Found) ~= "table" then
		return nil
	end
	return AsOpened(Found.State)
end

function Parts.Plan(Free: { [number]: number }, Within: number, Need: number, Room: number): { Portion }?
	local Order: { number } = {}
	for Index = 0, Within - 1 do
		table.insert(Order, Index)
	end
	table.sort(Order, function(Left: number, Right: number): boolean
		return SeenFree(Free, Left) > SeenFree(Free, Right)
	end)
	local Plan: { Portion } = {}
	local Left = Need
	for _, Index in Order do
		local Taking = math.min(SeenFree(Free, Index), Left)
		if Left == 0 or #Plan == Room or Taking == 0 then
			break
		end
		table.insert(Plan, { Index = Index, Count = Taking })
		Left -= Taking
	end
	if Left > 0 then
		return nil
	end
	return Plan
end

return Parts
