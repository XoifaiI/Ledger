--!strict
--!optimize 2

--[=[
	Guards: the pure checks of a value, the runs of a reducer and of a migration, and the carry of
	undeclared fields.

	A value past Record.StorableDepthMax is not storable. RunReducer freezes the state and op only when
	Limits.FreezeInputs is true. The caller warns and measures StateCap. DeepCopy takes only what Storable passed.
	RunWithoutYield is the yield stop Api shares.

	Return type: A table with Storable, DeepFreeze, DeepCopy, RunWithoutYield, RunReducer, RunMigration,
	CompareRuns, ProbeUnknownKind, SplitUndeclared, PutBack and AddsUndeclared.
	Example usage:
		local Outcome = Guards.RunReducer(Reducer, State, Op, Limits)
		local Difference = Guards.CompareRuns(Outcome, Guards.RunReducer(Reducer, State, Op, Limits))
--]=]

local Record = require("../Constants/Record")

export type Reducer<GameState, GameOp, Made = GameState> = (State: GameState, Op: GameOp) -> Made?

export type MigrationRun = (State: unknown) -> unknown?

type KindOp = { Kind: string }

export type FreezeLimits = {
	read FreezeInputs: boolean,
}

export type Outcome<Made> =
	{ read Kind: "State", read State: Made }
	| { read Kind: "NoState" }
	| { read Kind: "Yielded", read Trace: string }
	| { read Kind: "Threw", read Message: string }
	| { read Kind: "Unstorable", read Problem: string }

export type Ran<Value> =
	{ read Kind: "Returned", read Value: Value? }
	| { read Kind: "Yielded", read Trace: string }
	| { read Kind: "Threw", read Problem: unknown, read Trace: string }

type Tree = { [unknown]: unknown }

type Search = {
	Keys: { unknown },
	Seen: { [unknown]: boolean },
}

type Failure = {
	Problem: string,
	Level: number,
}

local StorableNotFinite = "is NaN or infinity, which cannot be stored"
local StorableBadUtf8 = "is a string that is not valid UTF-8"
local StorableKeyBadUtf8 = "has a key that is not valid UTF-8"
local StorableMetatable = "has a metatable, and a stored table has none"
local StorableCycle = "contains itself, and a stored value is a tree"
local StorableMixedKeys = "has array keys and string keys together, and it must have only one kind"
local StorableGap = "has number keys that are not 1 up to its length, so it is not an array without gaps"
local StorableTooDeep = `is nested deeper than {Record.StorableDepthMax} levels`

local ReducerStateWhere = "the state the reducer returned"
local ReducerYielded = "the reducer must complete without yielding"
local MigrationStateWhere = "the state the migration returned"
local MigrationYielded = "the migration must complete without yielding"

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

local function StorableType(TypeName: string): string
	return `is a {TypeName}, and only booleans, numbers, strings and tables can be stored`
end

local function StorableKeyType(TypeName: string): string
	return `has a key that is a {TypeName}, and a key must be a string or a place in an array`
end

local function Unstorable(Where: string, Path: string, Problem: string): string
	return `{Where}{Path} {Problem}`
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

local function PathText(Keys: { unknown }, Level: number): string
	local Parts: { string } = {}
	for Index = 2, Level do
		local Key = Keys[Index]
		if type(Key) == "number" then
			table.insert(Parts, `[{Key}]`)
		else
			table.insert(Parts, `.{Key}`)
		end
	end
	return table.concat(Parts)
end

local function Fail(Problem: string, Level: number): Failure
	return { Problem = Problem, Level = Level }
end

local Visit: (Search: Search, Value: unknown, Level: number) -> Failure?

local function VisitKeys(Held: Tree, Level: number): Failure?
	local Numbers = 0
	local Strings = 0
	for Key in Held do
		if type(Key) == "number" then
			Numbers += 1
		elseif type(Key) == "string" then
			if utf8.len(Key) == nil then
				return Fail(StorableKeyBadUtf8, Level)
			end
			Strings += 1
		else
			return Fail(StorableKeyType(typeof(Key)), Level)
		end
	end

	if Numbers > 0 and Strings > 0 then
		return Fail(StorableMixedKeys, Level)
	end
	for Index = 1, Numbers do
		if Held[Index] == nil then
			return Fail(StorableGap, Level)
		end
	end
	return nil
end

local function VisitTable(Search: Search, Held: Tree, Level: number): Failure?
	if getmetatable(Held) ~= nil then
		return Fail(StorableMetatable, Level)
	end
	if Search.Seen[Held] then
		return Fail(StorableCycle, Level)
	end

	local KeyFailure = VisitKeys(Held, Level)
	if KeyFailure ~= nil then
		return KeyFailure
	end

	Search.Seen[Held] = true
	for Key, Inner in Held do
		Search.Keys[Level + 1] = Key
		local InnerFailure = Visit(Search, Inner, Level + 1)
		if InnerFailure ~= nil then
			return InnerFailure
		end
	end
	Search.Seen[Held] = nil
	return nil
end

function Visit(Search: Search, Value: unknown, Level: number): Failure?
	if Level > Record.StorableDepthMax then
		return Fail(StorableTooDeep, Level)
	end

	if type(Value) == "boolean" then
		return nil
	end
	if type(Value) == "number" then
		if Value ~= Value or Value == math.huge or Value == -math.huge then
			return Fail(StorableNotFinite, Level)
		end
		return nil
	end
	if type(Value) == "string" then
		if utf8.len(Value) == nil then
			return Fail(StorableBadUtf8, Level)
		end
		return nil
	end
	if type(Value) ~= "table" then
		return Fail(StorableType(typeof(Value)), Level)
	end
	return VisitTable(Search, Value :: Tree, Level)
end

local function Freeze(Value: unknown, Seen: { [unknown]: boolean })
	if type(Value) ~= "table" or Seen[Value] then
		return
	end
	Seen[Value] = true

	local Held = Value :: Tree
	for _, Inner in Held do
		Freeze(Inner, Seen)
	end
	if not table.isfrozen(Held) then
		table.freeze(Held)
	end
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
	for Key, Inner in FirstHeld do
		Keys[Level + 1] = Key
		local At = FirstDifference(Keys, Inner, SecondHeld[Key], Level + 1)
		if At ~= nil then
			return At
		end
	end
	for Key in SecondHeld do
		if FirstHeld[Key] == nil then
			Keys[Level + 1] = Key
			return Level + 1
		end
	end
	return nil
end

local function Storable(Value: unknown, Where: string): string?
	local Search: Search = { Keys = {}, Seen = {} }
	local Failure = Visit(Search, Value, 1)
	if Failure == nil then
		return nil
	end
	return Unstorable(Where, PathText(Search.Keys, Failure.Level), Failure.Problem)
end

local function DeepFreeze(Value: unknown): ()
	Freeze(Value, {})
end

local function DeepCopy(Value: Tree): Tree
	local Copy: Tree = {}
	for Key, Inner in Value do
		if type(Inner) == "table" then
			Copy[Key] = DeepCopy(Inner :: Tree)
		else
			Copy[Key] = Inner
		end
	end
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

local function RunAndCheck<Made, Args...>(
	Function: (Args...) -> Made?,
	Where: string,
	YieldedText: string,
	...: Args...
): Outcome<Made & Tree>
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
	local Problem = Storable(Result, Where)
	if Problem ~= nil then
		return { Kind = "Unstorable", Problem = Problem }
	end
	return { Kind = "State", State = Result }
end

local function RunReducer<State, Op, Made>(
	Reducer: Reducer<State, Op, Made>,
	CurrentState: State,
	Given: Op,
	Limits: FreezeLimits
): Outcome<Made & Tree>
	if Limits.FreezeInputs then
		DeepFreeze(CurrentState)
		DeepFreeze(Given)
	end

	return RunAndCheck(Reducer, ReducerStateWhere, ReducerYielded, CurrentState, Given)
end

local function RunMigration(Migration: MigrationRun, CurrentState: unknown, Limits: FreezeLimits): Outcome<Tree>
	if Limits.FreezeInputs then
		DeepFreeze(CurrentState)
	end

	return RunAndCheck(Migration, MigrationStateWhere, MigrationYielded, CurrentState)
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
	Storable = Storable,
	DeepFreeze = DeepFreeze,
	DeepCopy = DeepCopy,
	RunWithoutYield = RunWithoutYield,
	RunReducer = RunReducer,
	CompareRuns = CompareRuns,
	ProbeUnknownKind = ProbeUnknownKind,
	SplitUndeclared = SplitUndeclared,
	PutBack = PutBack,
	AddsUndeclared = AddsUndeclared,
	RunMigration = RunMigration,
}
