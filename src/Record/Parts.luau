--!strict
--!optimize 2

--[=[
	Parts: Logic. A split quantity's parts, and the one reducer every part runs.

	Spec: hot keys 2.1 to 2.3, 2.6 and 2.7. Model: Hot.tla, Step, Expire and Draw.

	A quantity of m parts keeps part i under the key $P:<name>:<m>:<i>. Each part is a record whose
	state is Ledger's own: the print of its declaration, the clock it was opened, its free and sold
	units, its holds, and the Sealed and Closed flags. A quantity with serials gives each part its
	own range, and a part draws from its returned serials first, smallest first. Open does nothing on
	a part that exists, and every other op is refused on a part opened under another declaration.
	Take, Hold and Credit are refused on a sealed or closed part. Confirm sells a hold that stands,
	and takes as Take does when none stands. Release always writes. Upkeep runs on every write. It
	expires each hold whose end the clock passed by HOLD_SLACK, or whose end is more than HOLD_MAX and
	the slack ahead. In final mode it then seals a part with no free unit, no hold, no returned
	serial and no escrow mark. Nothing clears Sealed or Closed. The field names of the state and the
	Kind strings of the ops are stored, so none may change. KIND measures a part's free, held and
	sold units, and 1 when it is shut, for the summary path of Shards.

	Return type: The Parts module, and the Mode, Declared, Hold, Part and Reason types.
	Example usage:
		local Using = Parts.Build(Base, Declared)
--]=]

local Key = require("./Key")
local Limits = require("../Core/Constants/Limits")
local Types = require("./Types")
local Windows = require("../Core/Constants/Windows")

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
}

export type Reason = "Invalid" | "Closed" | "Sealed" | "Holds" | "Held" | "Free" | "Gone"

type Drawn = {
	Next: number?,
	Returned: { number }?,
	Serials: { number }?,
}

local PREFIX = "$P:"

local MODE = {
	Final = "Final" :: "Final",
	Open = "Open" :: "Open",
}

export type Mode = keyof<typeof(MODE)>

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

local function Held(Holds: { Hold }): number
	local Total = 0
	for _, Each in Holds do
		Total += Each.Count
	end
	return Total
end

local function Without(Holds: { Hold }, Id: string): ({ Hold }, Hold?)
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

local function Back(Returned: { number }?, Serials: { number }?): { number }?
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

local function Changed(Part: Part, Free: number, Sold: number, Holds: { Hold }, Drew: Drawn?): Part
	local Made = table.clone(Part) :: any
	Made.Free = Free
	Made.Sold = Sold
	Made.Holds = Holds
	Made.Issued = nil
	Made.Next = if Drew then Drew.Next else Part.Next
	Made.Returned = if Drew then Drew.Returned else Part.Returned
	return Made
end

local function Paid(Made: Part?, Price: { [string]: number }?): Part?
	if Made == nil or Price == nil then
		return Made
	end
	local Kept = Made :: any
	for Field, Amount in Price do
		Kept[Field] = (Kept[Field] or 0) + Amount
	end
	return Kept
end

local function Shut(Part: Part): boolean
	return Part.Closed == true or Part.Sealed == true
end

local function Issue(Made: Part, Serials: { number }?): Part
	local Issued = Made :: any
	Issued.Issued = if Serials then Serials[1] else nil
	return Issued
end

local function Take(Part: Part, Count: number): Part?
	if Shut(Part) or Part.Free < Count then
		return nil
	end
	local Drew = Draw(Part, Count)
	return Issue(Changed(Part, Part.Free - Count, Part.Sold + Count, Part.Holds, Drew), Drew.Serials)
end

local function Opened(Declared: Declared, Op: any): Part
	local From = Op.From
	local Made: any = {
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

local function Reduce(Declared: Declared, State: any, Op: any): unknown
	local Part = State :: Part
	if Op.Kind == "Open" then
		return if Part.Opened then Part else Opened(Declared, Op)
	elseif Part.Opened == nil or Part.Print ~= Op.Print then
		return nil
	elseif Op.Kind == "Take" then
		return Paid(Take(Part, Op.Count), Op.Price)
	elseif Op.Kind == "Hold" then
		if Shut(Part) or Part.Free < Op.Count or #Part.Holds >= HOLDS_MAX then
			return nil
		end
		local Drew = Draw(Part, Op.Count)
		local Holds = table.clone(Part.Holds)
		table.insert(Holds, { Id = Op.Id, Count = Op.Count, End = Op.End, Serials = Drew.Serials })
		return Changed(Part, Part.Free - Op.Count, Part.Sold, Holds, Drew)
	elseif Op.Kind == "Confirm" then
		local Holds, Found = Without(Part.Holds, Op.Id)
		if Found then
			return Paid(Issue(Changed(Part, Part.Free, Part.Sold + Found.Count, Holds), Found.Serials), Op.Price)
		end
		return if Part.Closed then nil else Paid(Take(Part, Op.Count), Op.Price)
	elseif Op.Kind == "Release" then
		local Holds, Found = Without(Part.Holds, Op.Id)
		if Found == nil then
			return Part
		end
		local Drew: Drawn = { Next = Part.Next, Returned = Back(Part.Returned, Found.Serials) }
		return Changed(Part, Part.Free + Found.Count, Part.Sold, Holds, Drew)
	elseif Op.Kind == "Credit" then
		if Shut(Part) or Part.Next ~= nil or Part.Free + Op.Count >= Limits.MONEY_LIMIT then
			return nil
		end
		return Changed(Part, Part.Free + Op.Count, Part.Sold, Part.Holds)
	elseif Op.Kind == "Close" then
		local Made = Changed(Part, Part.Free, Part.Sold, Part.Holds) :: any
		Made.Closed = true
		return Made
	end
	return nil
end

local function Lapsed(Each: Hold, Clock: number): boolean
	return Clock > Each.End + HOLD_SLACK or Each.End > Clock + HOLD_MAX + HOLD_SLACK
end

local function Upkeep(Declared: Declared, State: any, Clock: number, Marked: boolean): any
	local Part = State :: Part
	if Part.Opened == nil then
		return State
	end
	local Holds: { Hold } = {}
	local Count = 0
	local Returned = Part.Returned
	for _, Each in Part.Holds do
		if Lapsed(Each, Clock) then
			Count += Each.Count
			Returned = Back(Returned, Each.Serials)
		else
			table.insert(Holds, Each)
		end
	end
	local Free = Part.Free + Count
	local Empty = Free == 0 and Holds[1] == nil and (Returned == nil or Returned[1] == nil)
	local Seals = Declared.Mode == MODE.Final and not Part.Sealed and Empty and not Marked
	if Count == 0 and not Seals then
		return State
	end
	local Made = Changed(Part, Free, Part.Sold, Holds, { Next = Part.Next, Returned = Returned }) :: any
	Made.Sealed = Part.Sealed or Seals or nil
	return Made
end

local function Accepts(State: any, Amount: number): boolean
	local Part = State :: Part
	return Amount <= 0 or (Part.Opened ~= nil and not Shut(Part))
end

local MEASURES = 4

local SLOT = {
	Free = 1,
	Held = 2,
	Sold = 3,
	Shut = 4,
}

local function Measure(State: any): { number }?
	local Part = State :: Part
	if Part.Opened == nil then
		return nil
	end
	local Values = table.create(MEASURES, 0)
	Values[SLOT.Free] = Part.Free
	Values[SLOT.Held] = Held(Part.Holds)
	Values[SLOT.Sold] = Part.Sold
	Values[SLOT.Shut] = if Shut(Part) then 1 else 0
	return Values
end

local KIND = { Prefix = PREFIX, Width = MEASURES, Measure = Measure }

local Parts = {
	PREFIX = PREFIX,
	MODE = MODE,
	FIELDS = FIELDS,
	SPLIT_MAX = SPLIT_MAX,
	SPLIT_NAME = SPLIT_NAME,
	PROCEEDS_MAX = PROCEEDS_MAX,
	HOLDS_MAX = HOLDS_MAX,
	HOLD_MAX = HOLD_MAX,
	HOLD_SLACK = HOLD_SLACK,
	PROBES = PROBES,
	VIEW_AGE = VIEW_AGE,
	KIND = KIND,
	SLOT = SLOT,
}

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

function Parts.Build(Base: Types.Build, Declared: Declared): Types.Build
	local Made = table.clone(Base) :: any
	local Fields = table.clone(FIELDS)
	local Money = { "Free" }
	for _, Field in Declared.Proceeds do
		Fields[Field] = true
		table.insert(Money, Field)
	end
	Made.Reducer = function(State: any, Op: any): unknown
		return Reduce(Declared, State, Op)
	end
	Made.Upkeep = function(State: any, Clock: number, Marked: boolean): any
		return Upkeep(Declared, State, Clock, Marked)
	end
	Made.Output = function(State: any): number?
		return (State :: Part).Issued
	end
	Made.Accepts = function(State: any, _: number, Amount: number): boolean
		return Accepts(State, Amount)
	end
	Made.Migrations = {}
	Made.Default = {}
	Made.Level = 0
	Made.Floor = 0
	Made.Money = Money
	Made.Fields = Fields
	Made.Window = {}
	Made.Erasable = false
	Made.UntimedRoom = 0
	Made.Paced = PACE_PART
	return Made :: Types.Build
end

function Parts.Reason(State: unknown, Kind: string, Count: number, Print: number): Reason
	local Part = State :: Part
	if type(State) ~= "table" or Part.Print ~= Print then
		return "Invalid"
	elseif Part.Closed then
		return "Closed"
	elseif Part.Sealed then
		return "Sealed"
	elseif Kind == "Hold" and #Part.Holds >= HOLDS_MAX then
		return "Holds"
	elseif Kind == "Confirm" then
		return "Gone"
	end
	return if Part.Free + Held(Part.Holds) >= Count then "Held" else "Free"
end

function Parts.Empty(State: unknown, Declared: Declared): boolean
	local Part = State :: Part
	if type(State) ~= "table" then
		return false
	elseif Part.Free ~= 0 or Part.Holds[1] ~= nil or (Part.Returned or {})[1] ~= nil then
		return false
	end
	for _, Field in Declared.Proceeds do
		if (Part :: any)[Field] ~= 0 then
			return false
		end
	end
	return true
end

function Parts.Read(Value: unknown): Part?
	local Found = Key.Read(Value)
	if type(Found) ~= "table" or Found.State.Opened == nil then
		return nil
	end
	return Found.State :: any
end

function Parts.Plan(Free: { [number]: number }, Within: number, Need: number, Room: number): { { Index: number, Count: number } }?
	local Order: { number } = {}
	for Index = 0, Within - 1 do
		table.insert(Order, Index)
	end
	table.sort(Order, function(Left: number, Right: number): boolean
		return (Free[Left] or 0) > (Free[Right] or 0)
	end)
	local Plan: { { Index: number, Count: number } } = {}
	local Left = Need
	for _, Index in Order do
		local Taking = math.min(Free[Index] or 0, Left)
		if Left > 0 and #Plan < Room and Taking > 0 then
			table.insert(Plan, { Index = Index, Count = Taking })
			Left -= Taking
		end
	end
	return if Left == 0 then Plan else nil
end

return Parts
