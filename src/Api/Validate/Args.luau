--!strict
--!optimize 2

--[=[
	Args: shared method arguments, judged from the call, the store's options (A11) and the clock. No call may come from
	game code Ledger runs or wait in a listener. A name is its options' Id and IdAt; an Edit's or Commit's is never a
	handed-back one and, untimed, needs its kind's untimed window; an Erase's or Reset's is an OpId only. Terms and
	reset states are frozen copies.

	Return type: A plain table of the checks, the InOptions labels, and the Labels type.
	Example usage:
		local OpKind, Terms = Args.Op(Settings, Op, "Store:Edit")
		local MustExist, Name = Args.EditOptions(Settings, Options, "Store:Edit")
--]=]

local Balance = require("./Balance")
local Balances = require("../../Tx/Legs/Balances")
local Check = require("../../Encoding/Check")
local Cuts = require("../../Constants/Cuts")
local Guards = require("../../Judging/Guards")
local Handles = require("../Handles")
local Json = require("../../Encoding/Json")
local Names = require("../../Encoding/Names")
local NoYield = require("../../Util/NoYield")
local Platform = require("../../Shell/Platform")
local PublicTypes = require("../../Types")
local Record = require("../../Constants/Record")
local Rules = require("./Rules")
local Runner = require("../../Shell/Runner")
local Shapes = require("../../Shapes")
local ShellSetup = require("../../Shell/Setup")
local StoredValue = require("../../Stored/Value")

type AskedName = Shapes.AskedName
type GivenName = Names.GivenName
type OpId = PublicTypes.OpId
type Rule = Check.Rule
type Settings = ShellSetup.Settings
type StoreKey = Names.StoreKey
type Fields = StoredValue.Fields
type Terms = StoredValue.Fields

export type Labels = {
	read Name: string,
	read At: string,
}

type PeekGiven = { Fresh: boolean? }
type NameGiven = { Id: unknown, IdAt: unknown }
type EditGiven = { MustExist: boolean?, Id: unknown, IdAt: unknown }
type DidApplyGiven = { IdAt: unknown, Probe: boolean? }
type ResetGiven = { Id: unknown, IdAt: unknown, State: unknown }

type NameRules = {
	read Name: Rule,
	read At: Rule,
}

local AnyValue = Check.AnyValue
local LeftOut = Rules.LeftOut
local NoFields = Rules.NoFields
local OpWhere = Rules.OpWhere
local OrDefault = Rules.OrDefault
local Validated = Rules.Validated

local ResetBytesMost = math.min(Record.StateCap, Cuts.ResetMax)
local StateKey = "State"
local StampAheadMost = Record.SecondsPerDay

local InOptions: Labels = table.freeze({ Name = "Id", At = "IdAt" })
local ForDidApply: Labels = table.freeze({ Name = "Name", At = "IdAt" })

local CheckAccepted = "Args: a Check rule accepted a value of another type. The rule must reject it"
local GameText = `a game name: a string of valid UTF-8 that stores in at most {Record.NameMax} characters`
local GameOrOpIdWanted = `{GameText}, or an OpId from Ledger.Id`
local NotHandedBackWanted = `{GameOrOpIdWanted}, not a name Ledger handed back, since that names another write`
local OpIdOnlyWanted = "an OpId from Ledger.Id, since a game name resent from another server could %s a key made later"
local GameOrHandleWanted = `{GameText}, or a handle from Ledger.Id or Session:Apply`
local NoTimeWithoutName = "nil when no name is given"
local NoTimeBesideOpId = "nil beside an OpId, which carries its own time"
local NoTimeBesideHandle = "nil beside a handle, which carries its own name"
local UntimedProbeWanted = "false or nil for a name with no IdAt, since an untimed name has no probe"
local DeclaredFieldWanted = "a field the store declares, in its Default or an additive migration's Fields"
local ResetTooBig = `a state of at most {ResetBytesMost} bytes as canonical JSON`
local OptionsWithNameWanted = "a table whose Id is the name and whose IdAt is its time, "
	.. "since a name is no longer an argument of its own"
local NameInOptionsWhy = "a name goes in the options as Id and IdAt"
local NoOptionsWhy = "Resettle takes no options"
local SameKeyWanted = "a handle made on this key"
local OtherKeyGot = "a handle of another key"
local ErasableWanted = "true, since only an erasable store's keys carry the incarnation id an erase ends"
local StampEpochText = "2026-01-01 UTC"
local AheadOfClockWanted = `a time at most {StampAheadMost} seconds past Ledger.Now() (an IdAt counts seconds `
	.. `from {StampEpochText}; os.time() and DateTime values count from 1970)`
local UntimedWindowDays = Record.Ceiling // Record.SecondsPerDay
local UntimedWindowRange = `from {Record.UntimedWindowLeast} seconds to {UntimedWindowDays} days`
local ReceiptPattern = "A receipt (a ProcessReceipt PurchaseId) is kept once for all time only by recording the id "
	.. "in the buyer's state and refusing it in the reducer when it is already there; the window guards only inside it"

local WholeStamp = Check.Whole(1, Record.StampMax)
local MaxAgeRule = Check.Whole(0, Record.Ceiling)
local OpTable = Rules.Plain(Check.Map(AnyValue, AnyValue))
local IsErasable = Rules.Equals(true, ErasableWanted)

local PeekRules: { [string]: Rule } = {
	Fresh = Check.Optional(Check.Boolean),
}

local NameRules: { [string]: Rule } = {
	Id = AnyValue,
	IdAt = AnyValue,
}

local EditRules: { [string]: Rule } = {
	MustExist = Check.Optional(Check.Boolean),
	Id = AnyValue,
	IdAt = AnyValue,
}

local DidApplyRules: { [string]: Rule } = {
	IdAt = AnyValue,
	Probe = Check.Optional(Check.Boolean),
}

local ResetRules: { [string]: Rule } = {
	Id = AnyValue,
	IdAt = AnyValue,
	State = AnyValue,
}

local function Present(Wanted: string): Rule
	return function(Value: unknown): string?
		if Value ~= nil then
			return nil
		end
		return Wanted
	end
end

local function NoProbe(Value: unknown): string?
	if Value == true then
		return UntimedProbeWanted
	end
	return nil
end

local function Stamp(Value: unknown): string?
	if type(Value) == "number" and Value % 1 == 0 and Value > Platform.Now() + StampAheadMost then
		return AheadOfClockWanted
	end
	return WholeStamp(Value)
end

local OptionalStamp = Check.Optional(Stamp)

local function NilOrNonHandleTable(Value: unknown): string?
	if Value == nil then
		return nil
	end
	if type(Value) == "table" and not Handles.IsHandle(Value) then
		return nil
	end
	return OptionsWithNameWanted
end

local function CheckOne(Option: string, Value: unknown, Item: Rule, Where: string)
	Check.Table({ [Option] = Value }, { [Option] = Item }, Where)
end

local function MoreArguments(Where: string, After: string, Why: string, Count: number): string
	return `{Where}: arguments after {After} must be left out, since {Why}, got {Count} more`
end

local function UntimedWindowUnset(Store: string, OpKind: string): string
	return `the name's first send time from Ledger.Now(), since store {Store} sets no untimed window for op kind `
		.. `{OpKind}. A name with no IdAt is remembered only for its kind's untimed window, which the game sets per `
		.. `kind in Windows.{OpKind}.Untimed, {UntimedWindowRange}. {ReceiptPattern}`
end

local function NotInListener(Where: string): string
	return `{Where}: the call must not wait inside a listener of a Ledger stream, got a call made while one runs. `
		.. "Make it after the listener returns"
end

local function InsideStep(Where: string): string
	return `{Where}: the call must not be made inside a reducer, migration, Schema or arithmetic, got a call made `
		.. "while Ledger runs one. Make it from the game's own code"
end

local function SameKey(Where: string): string
	return `{Where}: Name must be {SameKeyWanted}, got {OtherKeyGot}`
end

local function StateWhere(Where: string): string
	return `{Where} State`
end

local function IsGameText(Value: string): boolean
	return utf8.len(Value) ~= nil and Names.FitsName(Value)
end

local function IsOpId(Value: unknown): boolean
	if type(Value) ~= "table" or not Handles.IsHandle(Value) then
		return false
	end
	return Handles.AskedOf(Value :: OpId).Kind == "Drawn"
end

local function GameOnly(Value: unknown): string?
	if type(Value) == "string" and IsGameText(Value) then
		return nil
	end
	return GameText
end

local function GameOr(Wanted: string, IsOther: (Value: unknown) -> boolean): Rule
	return function(Value: unknown): string?
		if GameOnly(Value) == nil or IsOther(Value) then
			return nil
		end
		return Wanted
	end
end

local function OpIdOnly(Verb: string): Rule
	local Wanted = string.format(OpIdOnlyWanted, Verb)
	return function(Value: unknown): string?
		if IsOpId(Value) then
			return nil
		end
		return Wanted
	end
end

local GameOrHandle = GameOr(GameOrHandleWanted, Handles.IsHandle)
local GameOrOpId = GameOr(GameOrOpIdWanted, IsOpId)

local function GameOrOpIdNotHandedBack(Value: unknown): string?
	if Handles.IsHandedBack(Value) then
		return NotHandedBackWanted
	end
	return GameOrOpId(Value)
end

local TimedGame: NameRules = { Name = GameOnly, At = Stamp }
local MaybeTimedGameOrOpId: NameRules = { Name = GameOrOpIdNotHandedBack, At = OptionalStamp }
local EraseOpIdName: NameRules = { Name = OpIdOnly("erase"), At = OptionalStamp }
local ResetOpIdName: NameRules = { Name = OpIdOnly("reset"), At = OptionalStamp }

local function DeclaredField(Declared: { [string]: boolean }): Rule
	return function(Value: unknown): string?
		if type(Value) == "string" and Declared[Value] then
			return nil
		end
		return DeclaredFieldWanted
	end
end

local StorableOp = Rules.StorableAs("Op")
local StorableState = Rules.StorableAs(StateKey)

local function FitsReset(Value: unknown): string?
	if Json.Size(Value) > ResetBytesMost then
		return ResetTooBig
	end
	return nil
end

local function GameOf(Labels: Labels, Name: unknown, At: unknown, Time: Rule, Where: string): GivenName
	CheckOne(Labels.At, At, Time, Where)
	assert(type(Name) == "string", CheckAccepted)
	assert(At == nil or type(At) == "number", CheckAccepted)
	return { Kind = "Game", Text = Name, Stamp = At }
end

local function DrawnOf(Value: unknown): GivenName
	assert(type(Value) == "table", CheckAccepted)
	local Asked = Handles.AskedOf(Value :: OpId)
	assert(Asked.Kind == "Drawn", CheckAccepted)
	return { Kind = "Drawn", Server = Asked.Server, Counter = Asked.Counter, Stamp = Asked.Stamp }
end

local function GivenNameOf(Labels: Labels, Allowed: NameRules, Name: unknown, At: unknown, Where: string): GivenName?
	if Name == nil then
		CheckOne(Labels.At, At, LeftOut(NoTimeWithoutName), Where)
		return nil
	end
	CheckOne(Labels.Name, Name, Allowed.Name, Where)
	if type(Name) ~= "string" then
		CheckOne(Labels.At, At, LeftOut(NoTimeBesideOpId), Where)
		return DrawnOf(Name)
	end
	return GameOf(Labels, Name, At, Allowed.At, Where)
end

local function GameName(Labels: Labels, Name: unknown, At: unknown, Where: string): GivenName?
	return GivenNameOf(Labels, TimedGame, Name, At, Where)
end

local function AskedName(Value: unknown, At: unknown, Where: string): AskedName
	CheckOne(ForDidApply.Name, Value, GameOrHandle, Where)
	if type(Value) == "table" then
		CheckOne(ForDidApply.At, At, LeftOut(NoTimeBesideHandle), Where)
		return Handles.AskedOf(Value :: OpId)
	end
	return GameOf(ForDidApply, Value, At, OptionalStamp, Where)
end

local function OpFields(Given: unknown, Where: string): Fields
	Check.Table({ Op = Given }, { Op = OpTable }, Where)
	assert(type(Given) == "table", CheckAccepted)
	return table.clone(Given :: Fields)
end

local function Op(Settings: Settings, Value: unknown, Where: string): (string, Terms)
	local Given = OpFields(Value, Where)
	local OpKind = Given.Kind
	Check.Table({ Kind = OpKind }, { Kind = Rules.OpKindName }, OpWhere(Where))
	assert(type(OpKind) == "string", CheckAccepted)

	Check.Table({ Op = Given }, { Op = StorableOp }, Where)
	local Terms = Guards.DeepCopy(Given)

	local Kind = Settings.Ops[OpKind]
	if Kind ~= nil then
		Guards.DeepFreeze(Terms)
		local Arithmetic = Balances.ArithmeticOf(Kind)
		Check.Table({ Amount = Terms.Amount }, { Amount = Balance.IsCallAmountOf(Arithmetic) }, OpWhere(Where))
	end
	return OpKind, Terms
end

local function UntimedWindow(Settings: Settings, OpKind: string, Name: GivenName?, Where: string): ()
	if Name == nil or Name.Kind ~= "Game" then
		return
	end
	local Window = Settings.Windows[OpKind]
	if Window ~= nil and Window.IsUntimedSet then
		return
	end
	CheckOne(InOptions.At, Name.Stamp, Present(UntimedWindowUnset(Settings.Name, OpKind)), Where)
end

local function MaxAge(Value: unknown, Where: string): number
	Check.Table({ MaxAge = Value }, { MaxAge = MaxAgeRule }, Where)
	assert(type(Value) == "number", CheckAccepted)
	return Value
end

local function PeekOptions(Options: unknown, Where: string): boolean
	local Given = Validated(Options, PeekRules, Where) :: PeekGiven
	return Given.Fresh == true
end

local function ProbeName(Name: unknown, Options: unknown, Where: string): (AskedName, boolean)
	local Given = Validated(OrDefault(Options, NoFields), DidApplyRules, Where) :: DidApplyGiven
	local Probe = Given.Probe
	local Asked = AskedName(Name, Given.IdAt, Where)
	if Asked.Kind == "Game" and Asked.Stamp == nil then
		Check.Table({ Probe = Probe }, { Probe = NoProbe }, Where)
	end
	return Asked, Probe == true
end

local function NamedOptions(Options: unknown, Rules: { [string]: Rule }, Where: string): { [unknown]: unknown }
	CheckOne("Options", Options, NilOrNonHandleTable, Where)
	return Validated(OrDefault(Options, NoFields), Rules, Where)
end

local function EditOptions(Settings: Settings, Options: unknown, Where: string): (boolean, GivenName?)
	local Given = NamedOptions(Options, EditRules, Where) :: EditGiven
	local Name = GivenNameOf(InOptions, MaybeTimedGameOrOpId, Given.Id, Given.IdAt, Where)
	return OrDefault(Given.MustExist, Settings.MustExist), Name
end

local function CommitName(Options: unknown, Where: string): GivenName?
	local Given = NamedOptions(Options, NameRules, Where) :: NameGiven
	return GivenNameOf(InOptions, MaybeTimedGameOrOpId, Given.Id, Given.IdAt, Where)
end

local function BumpName(Options: unknown, Where: string): GivenName?
	local Given = NamedOptions(Options, NameRules, Where) :: NameGiven
	return GameName(InOptions, Given.Id, Given.IdAt, Where)
end

local function EraseName(Options: unknown, Where: string): GivenName?
	local Given = NamedOptions(Options, NameRules, Where) :: NameGiven
	return GivenNameOf(InOptions, EraseOpIdName, Given.Id, Given.IdAt, Where)
end

local function CheckBalances(Settings: Settings, State: Fields, Where: string)
	for Field, Arithmetic in ShellSetup.FieldArithmeticsOf(Settings) do
		CheckOne(Field, State[Field], Balance.IsAmountOf(Arithmetic), Where)
	end
end

local function ResetState(Settings: Settings, State: unknown, Where: string): Fields?
	if State == nil then
		return nil
	end
	local Declared = Rules.Plain(Check.Map(DeclaredField(ShellSetup.DeclaredOf(Settings)), AnyValue))
	Check.Table({ State = State }, { State = Declared }, Where)
	Check.Table({ State = State }, { State = StorableState }, Where)
	assert(type(State) == "table", CheckAccepted)
	local Fields = Guards.DeepCopy(State :: Fields)
	Guards.DeepFreeze(Fields)
	Check.Table({ State = Fields }, { State = FitsReset }, Where)
	CheckBalances(Settings, Fields, StateWhere(Where))
	Rules.CheckSchema(Settings.Schema, StateKey, Fields, Where)
	return Fields
end

local function ResetOptions(Settings: Settings, Options: unknown, Where: string): (GivenName?, Fields?)
	local Given = NamedOptions(Options, ResetRules, Where) :: ResetGiven
	local Name = GivenNameOf(InOptions, ResetOpIdName, Given.Id, Given.IdAt, Where)
	return Name, ResetState(Settings, Given.State, Where)
end

local function ArgumentsGiven(...: unknown): number
	for Index = select("#", ...), 1, -1 do
		if (select(Index, ...)) ~= nil then
			return Index
		end
	end
	return 0
end

local function NoNameArguments(Where: string, ...: unknown): ()
	local Count = ArgumentsGiven(...)
	if Count > 0 then
		error(MoreArguments(Where, "Options", NameInOptionsWhy, Count), 0)
	end
end

local function NoOptions(Where: string, ...: unknown): ()
	local Count = ArgumentsGiven(...)
	if Count > 0 then
		error(MoreArguments(Where, "Key", NoOptionsWhy, Count), 0)
	end
end

local function OutsideListener(Where: string): ()
	if NoYield.IsListening() then
		error(NotInListener(Where), 0)
	end
end

local function OutsideStep(Where: string): ()
	if Runner.IsStepping() then
		error(InsideStep(Where), 0)
	end
end

local function HandleOfKey(Key: StoreKey, Name: unknown, Where: string): ()
	local Made = Handles.AppliedKeyOf(Name)
	if Made ~= nil and Names.KeyText(Made) ~= Names.KeyText(Key) then
		error(SameKey(Where), 0)
	end
end

local function Erasable(Settings: Settings, Where: string): ()
	Check.Table({ Erasable = Settings.IsErasable }, { Erasable = IsErasable }, Where)
end

return {
	InOptions = InOptions,
	GameName = GameName,
	AskedName = AskedName,
	Op = Op,
	UntimedWindow = UntimedWindow,
	MaxAge = MaxAge,
	PeekOptions = PeekOptions,
	ProbeName = ProbeName,
	HandleOfKey = HandleOfKey,
	OutsideListener = OutsideListener,
	OutsideStep = OutsideStep,
	EditOptions = EditOptions,
	CommitName = CommitName,
	BumpName = BumpName,
	EraseName = EraseName,
	ResetOptions = ResetOptions,
	NoNameArguments = NoNameArguments,
	NoOptions = NoOptions,
	Erasable = Erasable,
}
