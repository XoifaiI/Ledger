--!strict
--!optimize 2

--[=[
	Quantity: the object Store:Quantity gives for a declared quantity (hot keys 2.1 to 2.6), one per name. Each method
	refuses a destroyed store, checks its arguments, throws inside a Ledger stream's listener, sends one call and maps
	its answer through Answers. AskTotal is the store's (a declared total) and the quantity's (its parts) one Total
	call. An unopened or closed quantity's Missing warns once.

	Return type: The Quantity class.
	Example usage:
		local Tickets = Store:Quantity("Tickets")
		local Ok, Took, Info = Tickets:Take(1, { Price = 50 })
--]=]

local Answers = require("./Answers")
local Args = require("./Validate/Args")
local Cache = require("../Reading/Cache")
local Calls = require("../Shell/Calls")
local Events = require("../Events")
local GetOrMake = require("../GetOrMake")
local HotShapes = require("../Hot/Shapes")
local Moves = require("./Validate/Moves")
local Platform = require("../Shell/Platform")
local QuantityArgs = require("./Validate/Quantity")
local Reasons = require("../Constants/Reasons")
local Record = require("../Constants/Record")
local Runner = require("../Shell/Runner")
local ShellSetup = require("../Shell/Setup")
local Stores = require("./Validate/Stores")
local Types = require("../Types")

type Answer = Events.Answer
type Call = Events.Call
type Closed = Types.Closed
type ConfirmOptions = Types.ConfirmOptions
type Deposit = Moves.Deposit
type DepositOptions = Types.DepositOptions
type GatherOptions = Types.GatherOptions
type HoldHandle = HotShapes.HoldHandle
type Info = Types.Info
type KeyOfStore = Types.KeyOfStore
type QuantityDeclaration = HotShapes.QuantityDeclaration
type Reason = Types.Reason
type Settings = ShellSetup.Settings
type TakeOptions = Types.TakeOptions
type Took = HotShapes.Took
type WithdrawOptions = Types.WithdrawOptions

type QuantityData = {
	read Store: unknown,
	read Settings: Settings,
	read Declaration: QuantityDeclaration,
}

local NoStockUntilOpen = "A quantity has no stock until Quantity:Open() is called once (a repeat Open changes "
	.. "nothing), or it was closed and its parts removed"

local NoPartsWarned: { [string]: { [string]: boolean } } = {}

local function NoParts(Store: string, Quantity: string, Where: string): string
	return `Ledger: store {Store}, quantity {Quantity}: {Where} answered Missing, since the quantity's parts do not `
		.. `exist. {NoStockUntilOpen}`
end

local function NewWarnedSet(): { [string]: boolean }
	return {}
end

local function IsNoParts(Answered: Answer): boolean
	if Answered.Kind ~= "Failed" or Answered.Reason ~= Reasons.Missing then
		return false
	end
	local Key = Answered.Key
	return Key == nil or Cache.KindOfKey(Key) == Record.KeyKind.Part
end

local function WarnIfNoParts(Store: string, Quantity: string, Answered: Answer, Where: string): ()
	if not IsNoParts(Answered) then
		return
	end
	local Warned = GetOrMake.GetOrMake(NoPartsWarned, Store, NewWarnedSet)
	if Warned[Quantity] then
		return
	end
	Warned[Quantity] = true
	warn(NoParts(Store, Quantity, Where))
end

local function GatherCallOf(
	Settings: Settings,
	Declaration: QuantityDeclaration,
	Units: number,
	Gathering: Moves.Gathering
): Call
	return {
		Kind = "Call",
		Method = "Take" :: "Take",
		IsGather = true,
		CallId = Calls.NewCallId(),
		Store = Settings.Name,
		Scope = ShellSetup.StoreScope,
		Quantity = Declaration,
		Count = Units,
		Receiver = Gathering.Receiver,
		PartLegsMost = Gathering.PartLegsMost,
		Name = Gathering.Name,
		Fraction = Platform.Fraction(),
	}
end

local function DepositCallOf(Settings: Settings, Declaration: QuantityDeclaration, Units: number, Given: Deposit): Call
	local From = Given.From
	if From.Kind == "Key" then
		return {
			Kind = "Call",
			Method = "Deposit" :: "Deposit",
			IsMinted = false,
			CallId = Calls.NewCallId(),
			Store = Settings.Name,
			Scope = ShellSetup.StoreScope,
			Quantity = Declaration,
			Count = Units,
			To = Given.To,
			From = From.Leg,
		}
	end
	return {
		Kind = "Call",
		Method = "Deposit" :: "Deposit",
		IsMinted = true,
		CallId = Calls.NewCallId(),
		Store = Settings.Name,
		Scope = ShellSetup.StoreScope,
		Quantity = Declaration,
		Count = Units,
		To = Given.To,
		Fraction = Platform.Fraction(),
	}
end

local Quantity = {}
Quantity.__index = Quantity

export type Quantity = setmetatable<QuantityData, typeof(Quantity)>

function Quantity.AskTotal(
	Store: unknown,
	Settings: Settings,
	Name: unknown,
	Of: QuantityDeclaration?,
	MaxAge: unknown,
	Where: string
): (unknown, Reason?)
	Args.OutsideStep(Where)
	Stores.CheckLive(Store, Settings.Name)
	local Declared = if Of ~= nil then QuantityArgs.PartsOf(Of) else QuantityArgs.StoreTotalOf(Settings, Name, Where)
	local Age = QuantityArgs.TotalMaxAge(MaxAge, Where)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Total" :: "Total",
		CallId = Calls.NewCallId(),
		Store = Settings.Name,
		Scope = ShellSetup.StoreScope,
		Total = Declared,
		MaxAge = Age,
		Fraction = Platform.Fraction(),
	}
	return Answers.ReadAnswer(Runner.Call(Made):Wait())
end

function Quantity.New(Store: unknown, Settings: Settings, Declaration: QuantityDeclaration): Quantity
	local Data: QuantityData = { Store = Store, Settings = Settings, Declaration = Declaration }
	return setmetatable(Data, Quantity)
end

function Quantity.Total(self: Quantity, MaxAge: number?): (unknown, Reason?)
	return Quantity.AskTotal(
		self.Store,
		self.Settings,
		self.Declaration.Name,
		self.Declaration,
		MaxAge,
		"Quantity:Total"
	)
end

function Quantity.Take(self: Quantity, Count: number, Options: TakeOptions?): (boolean, Took | Reason, Info?)
	local Where = "Quantity:Take"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self.Store, Settings.Name)
	local Units = QuantityArgs.Count(Count, Where)
	local Price, Name, Checked = QuantityArgs.TakeOptions(Settings, self.Declaration, Units, Options, Where)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Take" :: "Take",
		IsGather = false,
		CallId = Calls.NewCallId(),
		Store = Settings.Name,
		Scope = ShellSetup.StoreScope,
		Quantity = self.Declaration,
		Count = Units,
		Price = Price,
		Name = Name,
		Legs = Checked.Legs,
		Fraction = Platform.Fraction(),
	}
	local Answered, Outcome = Runner.CallWithOutcome(Made):Wait()
	WarnIfNoParts(Settings.Name, self.Declaration.Name, Answered, Where)
	local Ok, Result, Info = Answers.TakeAnswer(Answered, Checked.KeysByStore)
	return Ok, Result, Answers.WithOutcome(Info, Outcome)
end

function Quantity.Hold(self: Quantity, Count: number, Duration: number): (boolean, HoldHandle | Reason, Info?)
	local Where = "Quantity:Hold"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self.Store, Settings.Name)
	local Units = QuantityArgs.Count(Count, Where)
	local Lasting = QuantityArgs.Duration(Settings, Duration, Where)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Hold" :: "Hold",
		CallId = Calls.NewCallId(),
		Store = Settings.Name,
		Scope = ShellSetup.StoreScope,
		Quantity = self.Declaration,
		Count = Units,
		Duration = Lasting,
		Fraction = Platform.Fraction(),
	}
	local Answered = Runner.Call(Made):Wait()
	WarnIfNoParts(Settings.Name, self.Declaration.Name, Answered, Where)
	return Answers.HoldAnswer(Answered, self.Declaration)
end

function Quantity.Gather(
	self: Quantity,
	Count: number,
	To: KeyOfStore,
	Field: string,
	Options: GatherOptions?
): (boolean, Reason?, Info?)
	local Where = "Quantity:Gather"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self.Store, Settings.Name)
	local Units = QuantityArgs.Count(Count, Where)
	local Gathering = Moves.Gathering(Settings, self.Declaration, Units, To, Field, Options, Where)
	Args.OutsideListener(Where)
	local Made = GatherCallOf(Settings, self.Declaration, Units, Gathering)
	return Answers.GatherAnswer(Runner.Call(Made):Wait(), Gathering.KeysByStore)
end

function Quantity.Open(self: Quantity): (boolean, Reason?, Info?)
	local Where = "Quantity:Open"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self.Store, Settings.Name)
	QuantityArgs.OpenAllowed(Settings, self.Declaration, Where)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Open" :: "Open",
		CallId = Calls.NewCallId(),
		Store = Settings.Name,
		Scope = ShellSetup.StoreScope,
		Quantity = self.Declaration,
	}
	return Answers.Plain(Runner.Call(Made):Wait())
end

function Quantity.Close(self: Quantity): (boolean, Closed | Reason, Info?)
	local Where = "Quantity:Close"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self.Store, Settings.Name)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Close" :: "Close",
		CallId = Calls.NewCallId(),
		Store = Settings.Name,
		Scope = ShellSetup.StoreScope,
		Quantity = self.Declaration,
		Fraction = Platform.Fraction(),
	}
	return Answers.CloseAnswer(Runner.Call(Made):Wait())
end

function Quantity.Confirm(
	self: Quantity,
	Hold: HoldHandle,
	Options: ConfirmOptions?
): (boolean, (number | Reason)?, Info?)
	local Where = "Quantity:Confirm"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self.Store, Settings.Name)
	local Handle = Moves.HoldHandle(self.Declaration, Hold, Where)
	local Price, Checked = Moves.ConfirmOptions(Settings, self.Declaration, Handle, Options, Where)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Confirm" :: "Confirm",
		CallId = Calls.NewCallId(),
		Store = Settings.Name,
		Scope = ShellSetup.StoreScope,
		Quantity = self.Declaration,
		Hold = Handle,
		Price = Price,
		Legs = Checked.Legs,
		Fraction = Platform.Fraction(),
	}
	return Answers.ConfirmAnswer(Runner.Call(Made):Wait(), Checked.KeysByStore)
end

function Quantity.Release(self: Quantity, Hold: HoldHandle): (boolean, Reason?, Info?)
	local Where = "Quantity:Release"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self.Store, Settings.Name)
	local Handle = Moves.HoldHandle(self.Declaration, Hold, Where)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "ReleaseHold" :: "ReleaseHold",
		CallId = Calls.NewCallId(),
		Store = Settings.Name,
		Scope = ShellSetup.StoreScope,
		Quantity = self.Declaration,
		Hold = Handle,
		Fraction = Platform.Fraction(),
	}
	return Answers.Plain(Runner.Call(Made):Wait())
end

function Quantity.Deposit(self: Quantity, Count: number, Options: DepositOptions?): (boolean, Reason?, Info?)
	local Where = "Quantity:Deposit"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self.Store, Settings.Name)
	local Units = QuantityArgs.Count(Count, Where)
	local Given = Moves.Deposit(Settings, self.Declaration, Units, Options, Where)
	Args.OutsideListener(Where)
	local Made = DepositCallOf(Settings, self.Declaration, Units, Given)
	local Answered = Runner.Call(Made):Wait()
	WarnIfNoParts(Settings.Name, self.Declaration.Name, Answered, Where)
	if Given.From.Kind == "Key" then
		return Answers.MoveAnswer(Answered, Given.KeysByStore)
	end
	return Answers.DepositAnswer(Answered, Given.KeysByStore)
end

function Quantity.Withdraw(
	self: Quantity,
	Count: unknown,
	Part: number,
	To: number | KeyOfStore,
	Field: string,
	Options: WithdrawOptions?
): (boolean, Reason?, Info?)
	local Where = "Quantity:Withdraw"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self.Store, Settings.Name)
	local Moved = Moves.Withdraw(Settings, self.Declaration, Count, Part, To, Field, Options, Where)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Withdraw" :: "Withdraw",
		CallId = Calls.NewCallId(),
		Store = Settings.Name,
		Scope = ShellSetup.StoreScope,
		Quantity = self.Declaration,
		Part = Moved.Part,
		Field = Moved.Field,
		Amount = Moved.Amount,
		To = Moved.To,
	}
	local Answered = Runner.Call(Made):Wait()
	WarnIfNoParts(Settings.Name, self.Declaration.Name, Answered, Where)
	return Answers.MoveAnswer(Answered, Moved.KeysByStore)
end

return Quantity
