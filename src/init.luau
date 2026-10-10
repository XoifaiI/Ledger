--!strict
--!optimize 2

--[=[
	Ledger: the module surface. On the server it starts the Runner at load; on a client, read through Platform (not a
	test flag), it starts nothing: Reason works and every other function throws, naming itself. A store name opens
	once per server life. New's typed view is the one cast, which MethodsMatch guards.

	Return type: The Ledger table of functions (Now is the clock an IdAt counts in; BeforeClose gives the close, the
	platform's or a CloseAll call's, a function to run first) and Reason, and the public types.
	Example usage:
		local Ledger = require(ReplicatedStorage.Ledger)
		local Vault = Ledger.New({
			Name = "Vault", Keys = "String", MustExist = false, Erasable = false, Default = { Gold = 0 },
			Balances = { Gold = { Credit = "Deposit", Debit = "Withdraw", Max = 1000000 } },
		})
--]=]

local Answers = require("@self/Api/Answers")
local Args = require("@self/Api/Validate/Args")
local Calls = require("@self/Shell/Calls")
local Check = require("@self/Encoding/Check")
local Cross = require("@self/Api/Validate/Cross")
local Events = require("@self/Events")
local KeyPages = require("@self/Api/KeyPages")
local Limits = require("@self/Shell/Limits")
local Legs = require("@self/Api/Validate/Legs")
local Platform = require("@self/Shell/Platform")
local Quantity = require("@self/Api/Quantity")
local Reasons = require("@self/Constants/Reasons")
local Runner = require("@self/Shell/Runner")
local Services = require("@self/Shell/Services")
local Session = require("@self/Api/Session")
local Setup = require("@self/Api/Validate/Setup")
local ShellSetup = require("@self/Shell/Setup")
local Store = require("@self/Api/Store")
local TypeFunctions = require("@self/TypeFunctions")
local Types = require("@self/Types")

type Call = Events.Call
type KeyPagesObject = KeyPages.KeyPages
type QuantityObject = Quantity.Quantity
type SessionObject = Session.Session
type StoreObject = Store.Store

export type Reason = Types.Reason
export type KeyLike = Types.KeyLike
export type KeysMode = Types.KeysMode
export type OpMap = Types.OpMap
export type Frozen<S> = Types.Frozen<S>
export type Future<T...> = Types.Future<T...>
export type Observer<T> = Types.Observer<T>
export type Connection = Types.Connection
export type Record<D = unknown> = Types.Record<D>
export type Identity = Types.Identity
export type LoadFailedHandler = Types.LoadFailedHandler
export type Closed = Types.Closed
export type HoldHandle = Types.HoldHandle
export type QuantityTotal = Types.QuantityTotal
export type Took = Types.Took
export type ShortReason = Types.ShortReason
export type Amount = Types.Amount
export type Arithmetic<T = any> = Types.Arithmetic<T>
export type LossRecords = Types.LossRecords
export type PendingItems = Types.PendingItems
export type Name = Types.Name
export type Terms<O = any> = Types.Terms<O>
export type Op<O = any> = Types.Op<O>
export type OpOf<O, K> = Types.OpOf<O, K>
export type Overloads<O, Shape> = Types.Overloads<O, Shape>
export type Reducer<S, O = any> = Types.Reducer<S, O>
export type ResultSchema<D> = Types.ResultSchema<D>
export type Migration = Types.Migration
export type BalanceField<T = any> = Types.BalanceField<T>
export type BalanceKindLimits<T = any> = Types.BalanceKindLimits<T>
export type Windows = Types.Windows
export type TotalDeclaration = Types.TotalDeclaration
export type QuantityDeclaration = Types.QuantityDeclaration
export type TypedConfig<D, O> = Types.TypedConfig<D, O>
export type Config<D> = Types.Config<D>
export type OpId = Types.OpId
export type Applied = Types.Applied
export type Info<D = unknown> = Types.Info<D>
export type DidApplyInfo = Types.DidApplyInfo
export type Cut = Types.Cut
export type EditOptions = Types.EditOptions
export type CommitOptions = Types.CommitOptions
export type BumpOptions = Types.BumpOptions
export type PeekOptions = Types.PeekOptions
export type DidApplyOptions = Types.DidApplyOptions
export type ResetOptions<D> = Types.ResetOptions<D>
export type EraseOptions = Types.EraseOptions
export type TxOptions = Types.TxOptions
export type TakeOptions = Types.TakeOptions
export type GatherOptions = Types.GatherOptions
export type ConfirmOptions = Types.ConfirmOptions
export type DepositOptions = Types.DepositOptions
export type WithdrawOptions = Types.WithdrawOptions
export type KeyOfStore = Types.KeyOfStore
export type TxLeg = Types.TxLeg
export type LegOptions = Types.LegOptions
export type Leg<S> = Types.Leg<S>
export type TakeLeg = Types.TakeLeg
export type Fate<O = any> = Types.Fate<O>
export type InfoKey = Types.InfoKey
export type SessionCommon<D, O = any> = Types.SessionCommon<D, O>
export type TypedSession<D, O> = Types.TypedSession<D, O>
export type Session<D> = Types.Session<D>
export type Quantity = Types.Quantity
export type KeyPages<K = string | number> = Types.KeyPages<K>
export type StoreCommon<D> = Types.StoreCommon<D>
export type TypedStore<D, O> = Types.TypedStore<D, O>
export type Store<D> = Types.Store<D>

type StoreStatics = { read __index: unknown, read New: unknown }
type SessionStatics = { read __index: unknown }
type QuantityStatics = { read __index: unknown, read New: unknown, read AskTotal: unknown }
type KeyPagesStatics = { read __index: unknown, read New: unknown }

type MethodsMatch =
	TypeFunctions.SameKeys<keyof<getmetatable<StoreObject>>, keyof<Store<any> & StoreStatics>>
	| TypeFunctions.SameKeys<keyof<getmetatable<SessionObject>>, keyof<Session<any> & SessionStatics>>
	| TypeFunctions.SameKeys<keyof<getmetatable<QuantityObject>>, keyof<Quantity & QuantityStatics>>
	| TypeFunctions.SameKeys<keyof<getmetatable<KeyPagesObject>>, keyof<KeyPages<any> & KeyPagesStatics>>

local KeysModes = ShellSetup.KeysMode

local IsServer = Platform.IsServer()

local NewWhere = "Ledger.New"
local NowWhere = "Ledger.Now"
local TxWhere = "Ledger.Tx"
local IdWhere = "Ledger.Id"
local CloseAllWhere = "Ledger.CloseAll"
local BeforeCloseWhere = "Ledger.BeforeClose"
local OpenedBefore = "a store name not opened on this server before, a destroyed store's included"

local function ServerOnly(Name: string): string
	return `Ledger: {Name} runs on the server only.`
end

local function OnServer(Name: string)
	if not IsServer then
		error(ServerOnly(Name), 0)
	end
end

local function NotOpened(Value: unknown): string?
	if type(Value) == "string" and Runner.IsOpened(Value) then
		return OpenedBefore
	end
	return nil
end

local function New<D, O>(Config: TypedConfig<D, O>): TypedStore<D, O>
	OnServer("New")
	Args.OutsideStep(NewWhere)
	local Settings = Setup.Settle(Config, NewWhere)
	Cross.Check(Settings, NewWhere)
	Check.Table({ Name = Settings.Name }, { Name = NotOpened }, NewWhere)
	local IsStudio = Platform.IsStudio()
	if IsStudio then
		Cross.Probe(Settings)
	end

	local PartBuild = ShellSetup.PartBuildOf(Settings)
	local Built = Limits.Build(Settings, PartBuild, IsStudio)
	local StoreSetup = ShellSetup.SetupOf(Settings, PartBuild, Platform.Encoding, Built, IsStudio)
	if Settings.Mock ~= nil then
		Services.UseMock(Settings.Mock)
	end
	Runner.AddStore(StoreSetup, Settings.Keys == KeysModes.Player)
	local Made = Store.New(Settings)
	return (Made :: any) :: TypedStore<D, O>
end

local function Now(): number
	OnServer("Now")
	Args.OutsideStep(NowWhere)
	return Platform.Now()
end

local function Id(): (OpId?, Reason?)
	OnServer("Id")
	Args.OutsideStep(IdWhere)
	Args.OutsideListener(IdWhere)
	local IdCall: Call = { Kind = "Call", Method = "Id" :: "Id", CallId = Calls.NewCallId() }
	return Answers.IdAnswer(Runner.CallNowForId(IdCall))
end

local function Tx(TxLegs: { TxLeg }, Options: TxOptions?): (boolean, Reason?, Info?)
	OnServer("Tx")
	Args.OutsideStep(TxWhere)
	local Checked = Legs.Check(TxLegs, Options, TxWhere)
	Args.OutsideListener(TxWhere)
	local Made: Call = {
		Kind = "Call",
		Method = "Tx" :: "Tx",
		CallId = Calls.NewCallId(),
		Legs = Checked.Legs,
		Hot = nil,
		Name = Checked.Name,
	}
	local Answered, Outcome = Runner.CallWithOutcome(Made):Wait()
	local Ok, Why, Info = Answers.TxAnswer(Answered, Checked.KeysByStore)
	return Ok, Why, Answers.WithOutcome(Info, Outcome)
end

local function CloseAll(): ()
	OnServer("CloseAll")
	Args.OutsideStep(CloseAllWhere)
	Args.OutsideListener(CloseAllWhere)
	Runner.CloseAll()
end

local function BeforeClose(Fn: () -> ()): ()
	OnServer("BeforeClose")
	Args.OutsideStep(BeforeCloseWhere)
	Check.Table({ Fn = Fn }, { Fn = Check.Function }, BeforeCloseWhere)
	Runner.AddBeforeClose(Fn)
end

if IsServer then
	Runner.Start()
end

return {
	New = New,
	Now = Now,
	Id = Id,
	Tx = Tx,
	CloseAll = CloseAll,
	BeforeClose = BeforeClose,
	Reason = Reasons,
}
