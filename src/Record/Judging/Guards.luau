--!strict
--!optimize 2
--!native

--[=[
	Guards: the runs of a reducer and of a migration, the check of what they return, and the carry of undeclared
	fields.

	RunReducer freezes its input only when Limits.FreezeInputs is true. A returned state is checked by Storable, or
	by StorableChange against the vetted state its input came from, and is frozen and vetted once storable. The
	caller warns and measures StateCap. DeepCopy takes only what Storable passed, since table.clone keeps a
	metatable. DeepFrozenCopy's copy is never a table Ledger holds. CompareRuns skips the second state's keys when
	its vetted count equals the first's, since every key of the first held an equal value there.

	Return type: A table of the runs and checks, with Storable's CheckStorable and DeepFreeze.
	Example usage:
		local Outcome = Guards.RunReducer(Reducer, State, Op, Limits)
--]=]

local Json = require("../Encoding/Json")
local Record = require("../Constants/Record")
local Storable = require("./Storable")
local StorableChange = require("./StorableChange")
local Vetted = require("../Encoding/Vetted")

type Tree = Storable.Tree

export type Reducer<GameState, GameOp, Made = GameState> = (State: GameState, Op: GameOp) -> Made?

export type MigrationRun = (State: unknown) -> unknown?

type KindOp = { Kind: string }

export type FreezeLimits = {
	read FreezeInputs: boolean,
}

type Ended =
	{ read Kind: "NoState" }
	| { read Kind: "Yielded", read Trace: string }
	| { read Kind: "Threw", read Message: string }
	| { read Kind: "Unstorable", read Problem: string }

type Returned<Made> = { read Kind: "Table", read State: Made } | Ended

export type Outcome<Made> = { read Kind: "State", read State: Made } | Ended

export type Ran<Value> =
	{ read Kind: "Returned", read Value: Value? }
	| { read Kind: "Yielded", read Trace: string }
	| { read Kind: "Threw", read Problem: unknown, read Trace: string }

local DeepFreeze = Storable.DeepFreeze
local PathText = Storable.PathText

local ReducerStateWhere = "the state the reducer returned"
local ReducerYielded = "the reducer must complete without yielding"
local MigrationStateWhere = "the state the migration returned"
local MigrationYielded = "the migration must complete without yielding"
local UnvettedInside = "Guards: a vetted table holds a table that is not vetted. "
	.. "A table is vetted only when every table inside it is"

local OutcomeKinds: { [string]: string } = {
	State = "a state",
	NoState = "no state",
	Yielded = "a yield",
	Threw = "a throw",
	Unstorable = "a state that cannot be stored",
}

local SameEveryRun =
	"A reducer must give the same from the same state and op, or two servers would compute different states"

local function NotTable(Where: string): string
	return `{Where} is not a table, and a state is a table`
end

local function RunsGave(First: string, Second: string): string
	return `the first run gave {First} and the second gave {Second}. {SameEveryRun}`
end

local function StatesDiffer(Path: string): string
	return `the two states differ at state{Path}. {SameEveryRun}`
end

local function ProbeNotIgnored(Gave: string): string
	return `the reducer gave {Gave} for an op of a kind it does not know. `
		.. "It must give no state for such an op, so that an op from a newer build is refused"
end

local function FirstDifference(Keys: { unknown }, First: unknown, Second: unknown, Level: number): number?
	if First == Second then
		return nil
	end
	if type(First) ~= "table" or type(Second) ~= "table" then
		return Level
	end

	local FirstHeld = First :: Tree
	local SecondHeld = Second :: Tree
	local Count = 0
	for Key, Inner in FirstHeld do
		Count += 1
		local Other = SecondHeld[Key]
		if Inner ~= Other then
			Keys[Level + 1] = Key
			local At = FirstDifference(Keys, Inner, Other, Level + 1)
			if At ~= nil then
				return At
			end
		end
	end
	if Vetted.CountOf(SecondHeld) == Count then
		return nil
	end
	for Key in SecondHeld do
		if FirstHeld[Key] == nil then
			Keys[Level + 1] = Key
			return Level + 1
		end
	end
	return nil
end

local function DeepCopy(Value: Tree): Tree
	local Copy = table.clone(Value)
	for Key, Inner in Value do
		if type(Inner) == "table" then
			Copy[Key] = DeepCopy(Inner :: Tree)
		end
	end
	return Copy
end

local function VettedCopy(Held: Tree): Tree
	local Height = Vetted.HeightOf(Held)
	local Count = Vetted.CountOf(Held)
	if Height == nil or Count == nil then
		error(UnvettedInside, 0)
	end

	local Copy = table.clone(Held)
	for Key, Inner in Held do
		if type(Inner) == "table" then
			Copy[Key] = VettedCopy(Inner :: Tree)
		end
	end
	table.freeze(Copy)
	Vetted.Add(Copy, Height, Count)
	local Bytes = Json.KnownSize(Held)
	if Bytes ~= nil then
		Json.KeepSize(Copy, Bytes)
	end
	return Copy
end

local function DeepFrozenCopy(Value: Tree): Tree
	if Vetted.IsVetted(Value) then
		return VettedCopy(Value)
	end
	local Copy = DeepCopy(Value)
	DeepFreeze(Copy)
	return Copy
end

local function RunWithoutYield<Value, Args...>(Body: (Args...) -> Value?, YieldedText: string, ...: Args...): Ran<Value>
	local Thread = coroutine.create(Body)
	local Resumed, Result = coroutine.resume(Thread, ...)
	if not Resumed then
		return { Kind = "Threw", Problem = Result, Trace = debug.traceback(Thread, tostring(Result)) }
	end
	if coroutine.status(Thread) == "suspended" then
		local Trace = debug.traceback(Thread, YieldedText)
		coroutine.close(Thread)
		return { Kind = "Yielded", Trace = Trace }
	end
	return { Kind = "Returned", Value = Result }
end

local function RunToTable<Made, Args...>(
	Function: (Args...) -> Made?,
	Where: string,
	YieldedText: string,
	...: Args...
): Returned<Made & Tree>
	local Ran = RunWithoutYield(Function, YieldedText, ...)
	if Ran.Kind == "Threw" then
		return { Kind = "Threw", Message = Ran.Trace }
	end
	if Ran.Kind == "Yielded" then
		return { Kind = "Yielded", Trace = Ran.Trace }
	end

	local Result = Ran.Value
	if Result == nil then
		return { Kind = "NoState" }
	end
	if type(Result) ~= "table" then
		return { Kind = "Unstorable", Problem = NotTable(Where) }
	end
	return { Kind = "Table", State = Result }
end

local function CheckAndFreezeWhole<Made>(Run: Returned<Made & Tree>, Where: string): Outcome<Made & Tree>
	if Run.Kind ~= "Table" then
		return Run
	end
	local Problem = Storable.Check(Run.State, Where)
	if Problem ~= nil then
		return { Kind = "Unstorable", Problem = Problem }
	end
	DeepFreeze(Run.State)
	return { Kind = "State", State = Run.State }
end

local function CheckAndFreezeAgainst<Made>(Run: Returned<Made & Tree>, Old: Tree, Where: string): Outcome<Made & Tree>
	if Run.Kind ~= "Table" then
		return Run
	end
	local NewTables: StorableChange.NewTables = {}
	local Problem = StorableChange.Check(Run.State, Old, Where, NewTables)
	if Problem ~= nil then
		return { Kind = "Unstorable", Problem = Problem }
	end
	StorableChange.VetMade(NewTables)
	DeepFreeze(Run.State)
	return { Kind = "State", State = Run.State }
end

local function RunReducer<State, Op, Made>(
	Reducer: Reducer<State, Op, Made>,
	CurrentState: State,
	Given: Op,
	Limits: FreezeLimits,
	Basis: Tree?
): Outcome<Made & Tree>
	if Limits.FreezeInputs then
		StorableChange.VetSubsetOf(CurrentState, Basis)
		DeepFreeze(CurrentState)
		DeepFreeze(Given)
	end

	local Old = StorableChange.TrustedOld(Basis, CurrentState)
	local Run = RunToTable(Reducer, ReducerStateWhere, ReducerYielded, CurrentState, Given)
	if Old == nil then
		return CheckAndFreezeWhole(Run, ReducerStateWhere)
	end
	return CheckAndFreezeAgainst(Run, Old, ReducerStateWhere)
end

local function RunMigration(Migration: MigrationRun, CurrentState: unknown, Limits: FreezeLimits): Outcome<Tree>
	if Limits.FreezeInputs then
		DeepFreeze(CurrentState)
	end

	local Run = RunToTable(Migration, MigrationStateWhere, MigrationYielded, CurrentState)
	return CheckAndFreezeWhole(Run, MigrationStateWhere)
end

local function CompareRuns<Made>(First: Outcome<Made>, Second: Outcome<Made>): string?
	if First.Kind ~= Second.Kind then
		return RunsGave(OutcomeKinds[First.Kind], OutcomeKinds[Second.Kind])
	end
	if First.Kind ~= "State" or Second.Kind ~= "State" then
		return nil
	end

	local Keys = {}
	local Level = FirstDifference(Keys, First.State, Second.State, 1)
	if Level == nil then
		return nil
	end
	return StatesDiffer(PathText(Keys, Level))
end

local function ProbeUnknownKind<State, Made>(
	Reducer: Reducer<State, KindOp, Made>,
	CurrentState: State,
	Limits: FreezeLimits
): string?
	local Outcome = RunReducer(Reducer, CurrentState, { Kind = Record.UnknownKindProbe }, Limits)
	if Outcome.Kind == "NoState" then
		return nil
	end
	return ProbeNotIgnored(OutcomeKinds[Outcome.Kind])
end

local function SplitUndeclared(State: Tree, Declared: { [string]: boolean }): (Tree, Tree)
	local DeclaredFields: Tree = {}
	local UndeclaredFields: Tree = {}
	for Key, Value in State do
		if type(Key) == "string" and Declared[Key] then
			DeclaredFields[Key] = Value
		else
			UndeclaredFields[Key] = Value
		end
	end
	return DeclaredFields, UndeclaredFields
end

local function PutBack(State: Tree, Undeclared: Tree): Tree
	if next(Undeclared) == nil then
		return State
	end
	local Whole: Tree = table.clone(State)
	for Key, Value in Undeclared do
		Whole[Key] = Value
	end
	return Whole
end

local function AddsUndeclared(State: Tree, Declared: { [string]: boolean }): boolean
	for Key in State do
		if type(Key) ~= "string" or not Declared[Key] then
			return true
		end
	end
	return false
end

return {
	CheckStorable = Storable.Check,
	DeepFreeze = DeepFreeze,
	DeepCopy = DeepCopy,
	DeepFrozenCopy = DeepFrozenCopy,
	RunWithoutYield = RunWithoutYield,
	RunReducer = RunReducer,
	CompareRuns = CompareRuns,
	ProbeUnknownKind = ProbeUnknownKind,
	SplitUndeclared = SplitUndeclared,
	PutBack = PutBack,
	AddsUndeclared = AddsUndeclared,
	RunMigration = RunMigration,
}
