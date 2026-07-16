--!strict
--!optimize 2
--!native

type BasicCases = {
	ToBe: (Expected: any) -> (),
	ToEqual: (Expected: any) -> (),
	ToBeDefined: () -> (),
	ToBeCloseTo: (Expected: number, Precision: number) -> (),
	ToBeGreaterThan: (Expected: number) -> (),
	ToBeGreaterThanOrEqual: (Expected: number) -> (),
	ToBeLessThan: (Expected: number) -> (),
	ToBeLessThanOrEqual: (Expected: number) -> (),
	ToBeNil: () -> (),
	ToBeNan: () -> (),
	ToHaveLength: (Expected: number) -> (),
	ToBeFalsy: () -> (),
	ToBeTruthy: () -> (),
}

type FunctionalCases = BasicCases & {
	ToThrow: (Expected: string?) -> (),
	Never: BasicCases & { ToThrow: (Expected: string?) -> () },
}

type ExpectHandler = {
	Nothing: any,
	Any: (Type: string) -> any,
	Type: (
		Type: "nil"
			| "boolean"
			| "number"
			| "string"
			| "function"
			| "table"
			| "userdata"
			| "thread"
			| "buffer"
			| "vector"
	) -> any,
	Similar: (Expected: { [any]: any }) -> any,
}

export type TestingLib = {
	Failed: number,
	Count: number,
	Verbose: boolean,
	Entry: (Callback: () -> ()) -> (),
	Complete: () -> (),
	Test: (Name: string, Callback: () -> ()) -> (),
	Describe: (Name: string, Callback: () -> ()) -> (),
	Defer: (Function: () -> ()) -> (),
	Expect: ((Value: any) -> FunctionalCases) & ExpectHandler,
	Expected: (Value: any) -> (),
	ExpectEqual: (Expected: any, Value: any) -> (),
}

type TestInfo = {
	Name: string?,
}

type StackTraceInfo = {
	Source: string,
	Name: string,
	Line: number,
	Address: string,
}

local Testing = {}

Testing.Verbose = false
Testing.Failed = 0
Testing.Count = 0
Testing.Start = nil :: number?

local DeferQueue = {} :: { () -> () }
local ScopeStack = {} :: { string }

local function NonEmptyString(Value: any?): boolean
	return type(Value) == "string" and #Value > 1
end

local function FormatTime(Microseconds: number): string
	if Microseconds >= 1000000 then
		return string.format("%.2fs", Microseconds / 1000000)
	elseif Microseconds >= 1000 then
		return string.format("%.2fms", Microseconds / 1000)
	end
	return string.format("%.0fus", Microseconds)
end

local ThisSource = debug.info(function() end, "s")
local SharedStackTrace: { StackTraceInfo } = {}

local SharedError: string? = nil
local SharedShortSource: string? = nil
local SharedSourceScript: Instance? = nil

local function RunTestErrorHandler(ErrorMessage: any)
	table.clear(SharedStackTrace)
	SharedShortSource = nil
	SharedSourceScript = nil

	local LastName = debug.info(1, "n")
	local WasIntentional = debug.info(2, "n") == "error"

	for Index = 1, 30 do
		local DebugFunction, Name, Line, Source = debug.info(Index + 1, "fnls")
		if not DebugFunction then
			break
		end

		local FrameName = LastName
		if #SharedStackTrace > 0 or NonEmptyString(Name) then
			LastName = Name
		end
		if Line < 0 then
			continue
		end

		if Source == ThisSource and WasIntentional then
			continue
		end

		local ShortenedSource: string = (SharedShortSource or Source) :: string

		if not SharedShortSource then
			local SourceEnv = getfenv(DebugFunction)
			if SourceEnv and SourceEnv.script then
				local Script = SourceEnv.script :: Instance
				SharedSourceScript = Script
				ShortenedSource = `{Script.Parent}.{Script}`
				SharedShortSource = ShortenedSource
			end
		end

		table.insert(SharedStackTrace, {
			Source = ShortenedSource,
			Name = FrameName :: string,
			Line = Line,
			Address = tostring(DebugFunction),
		})
	end

	SharedError = ErrorMessage
	if SharedShortSource and SharedSourceScript then
		SharedError = (SharedError :: string):gsub((SharedSourceScript :: Instance):GetFullName(), SharedShortSource :: string)
	end
end

local function RunTest(Function: () -> (), Info: TestInfo)
	Testing.Count += 1
	if Testing.Count % 90 == 0 then
		task.wait()
	end

	if not Testing.Start then
		Testing.Start = os.clock()
	end

	local TimeStart = os.clock()
	local Ok = xpcall(Function, RunTestErrorHandler)
	local TimeLength = math.floor((os.clock() - TimeStart) * 1000000)

	if #DeferQueue > 0 then
		for Index = #DeferQueue, 1, -1 do
			local Success = pcall(DeferQueue[Index])
			if not Success then
				print("Deferred function failed")
			end
		end
		table.clear(DeferQueue)
	end

	if Ok then
		if Testing.Verbose then
			if #ScopeStack > 0 then
				print(`PASS {table.concat(ScopeStack, "/")} ({Info.Name}) [{FormatTime(TimeLength)}]`)
			else
				print(`PASS ({Info.Name}) [{FormatTime(TimeLength)}]`)
			end
		end
		return
	end

	Testing.Failed += 1
	local ScopePadded = if #ScopeStack > 0 then " " else ""
	local Scope = `{ScopePadded}{table.concat(ScopeStack, "/")} ({Info.Name})`
	warn(`FAIL{Scope} [{FormatTime(TimeLength)}]`)
	warn(`@ error: {SharedError}`)

	local Size = #SharedStackTrace
	for StackIndex, StackValue in SharedStackTrace do
		local NameHasValue = NonEmptyString(StackValue.Name)
		local Branch = if StackIndex == Size then "L-" else "|-"
		warn(
			`{Branch} {StackValue.Source}:{StackValue.Line}: {StackValue.Address:sub(11)}{NameHasValue and ` called {StackValue.Name}` or ""}`
		)
	end
end

function Testing.Describe(Name: string, Function: (...any) -> ...any): ()
	table.insert(ScopeStack, Name)
	local Ok, Error = pcall(Function :: any)
	table.remove(ScopeStack)
	if not Ok then
		Testing.Failed += 1
		print(`{debug.info(2, "l")}: Describe("{Name}", ...):`)
		print(`{Error}`)
	end
end

function Testing.Test(Name: string, Function: (...any) -> ...any): ()
	RunTest(Function, { Name = Name })
end

function Testing.Entry(Function: (...any) -> ...any): ()
	Testing.Count = 0
	Testing.Failed = 0
	Testing.Start = nil

	Function()

	Testing.Complete()
end

function Testing.Complete(): ()
	local Time = os.clock() - (Testing.Start or os.clock())
	local Count = Testing.Count
	local Failed = Testing.Failed
	if Failed > 0 then
		print(` Tests: {Failed} failed, {Count} total`)
	else
		print(` Tests: {Count} total`)
	end

	print(` Time: {math.ceil(Time * 1000) / 1000} s`)
end

function Testing.Defer(Function: () -> ())
	table.insert(DeferQueue, Function)
end

local function AssertExpect(Flipped: boolean, Value: boolean, Format: string, ...: any)
	if Flipped then
		Value = not Value
	end

	if not Value then
		error(string.format(Format :: any, ...), 4)
	end
end

local Conditional = {}
Conditional.__index = Conditional

function Conditional.New(Name: string, Function: (Value: any) -> (boolean, any?, string?), Any: any?)
	return setmetatable({
		Test = Function,
		Name = Name,
		Value = Any,
	}, Conditional)
end

function Conditional.Is(Any: any): boolean
	return type(Any) == "table" and getmetatable(Any) == Conditional
end

type Conditional = typeof(Conditional.New("", function(_)
	return true, ""
end))

function Conditional.__call(self: Conditional, ...)
	return self.Test(...)
end

function Conditional.__tostring(self: Conditional)
	return self.Name
end

type ConditionState = {
	Received: any,
	Flipped: boolean,
}

local function FlipTag(Flipped: boolean): string
	return if Flipped then "not " else ""
end

local ReadableControl = {
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\v"] = "\\v",
	["\f"] = "\\f",
	["\b"] = "\\b",
	["\a"] = "\\a",
	["\\"] = "\\\\",
	['"'] = '\\"',
	["%"] = string.format("\\x%02X", 37),
}

local function Readable(Value: any): string
	if type(Value) ~= "string" then
		return tostring(Value)
	end

	local SafeValue = Value:gsub(".", function(Character: string)
		local Byte = Character:byte()
		if ReadableControl[Character] then
			return ReadableControl[Character]
		end
		if Byte < 32 or Byte > 126 then
			return string.format("\\x%02X", Byte)
		end
		return Character
	end)

	return `"{SafeValue}"`
end

local Conditionals = {
	ToBe = function(self: ConditionState, Expected: any)
		if Conditional.Is(Expected) then
			local Condition, Any, String = (Expected :: any)(self.Received)
			if String then
				AssertExpect(self.Flipped, Condition, String, FlipTag(self.Flipped))
			else
				AssertExpect(
					self.Flipped,
					Condition,
					"Expected %s to %sbe %s",
					Any or Readable(self.Received),
					FlipTag(self.Flipped),
					Readable(Expected)
				)
			end
		else
			AssertExpect(
				self.Flipped,
				self.Received == Expected,
				"Expected %s to %sbe %s",
				Readable(self.Received),
				FlipTag(self.Flipped),
				Readable(Expected)
			)
		end
	end,

	ToBeDefined = function(self: ConditionState)
		AssertExpect(
			self.Flipped,
			self.Received ~= nil,
			"Expected %s to %sbe defined",
			Readable(self.Received),
			FlipTag(self.Flipped)
		)
	end,

	ToBeCloseTo = function(self: ConditionState, Expected: number, Precision: number)
		AssertExpect(
			self.Flipped,
			Expected == math.huge and self.Received == math.huge
				or Expected == -math.huge and self.Received == -math.huge
				or math.abs(self.Received - Expected) < (10 ^ -Precision) / 2,
			"Expected %s to be close to %s",
			Readable(self.Received),
			Expected
		)
	end,

	ToBeGreaterThan = function(self: ConditionState, Expected: number)
		AssertExpect(
			self.Flipped,
			self.Received > Expected,
			"Expected %s to %sbe greater than %s",
			Readable(self.Received),
			FlipTag(self.Flipped),
			Readable(Expected)
		)
	end,

	ToBeGreaterThanOrEqual = function(self: ConditionState, Expected: number)
		AssertExpect(
			self.Flipped,
			self.Received >= Expected,
			"Expected %s to %sbe greater than or equal to %s",
			Readable(self.Received),
			FlipTag(self.Flipped),
			Readable(Expected)
		)
	end,

	ToBeLessThan = function(self: ConditionState, Expected: number)
		AssertExpect(
			self.Flipped,
			self.Received < Expected,
			"Expected %s to %sbe less than %s",
			Readable(self.Received),
			FlipTag(self.Flipped),
			Readable(Expected)
		)
	end,

	ToBeLessThanOrEqual = function(self: ConditionState, Expected: number)
		AssertExpect(
			self.Flipped,
			self.Received <= Expected,
			"Expected %s to %sbe less than or equal to %s",
			Readable(self.Received),
			FlipTag(self.Flipped),
			Readable(Expected)
		)
	end,

	ToBeNil = function(self: ConditionState)
		AssertExpect(
			self.Flipped,
			self.Received == nil,
			"Expected %s to %sbe nil",
			Readable(self.Received),
			FlipTag(self.Flipped)
		)
	end,

	ToBeNan = function(self: ConditionState)
		AssertExpect(
			self.Flipped,
			self.Received ~= self.Received and type(self.Received) == "number",
			"Expected %s to %sbe NaN",
			Readable(self.Received),
			FlipTag(self.Flipped)
		)
	end,

	ToHaveLength = function(self: ConditionState, Expected: number)
		AssertExpect(
			self.Flipped,
			#self.Received == Expected,
			"Expected %s to %shave length %s",
			Readable(self.Received),
			FlipTag(self.Flipped),
			Readable(Expected)
		)
	end,

	ToBeFalsy = function(self: ConditionState)
		AssertExpect(
			self.Flipped,
			not self.Received,
			"Expected %s to %sbe falsy",
			Readable(self.Received),
			FlipTag(self.Flipped)
		)
	end,

	ToBeTruthy = function(self: ConditionState)
		AssertExpect(
			self.Flipped,
			self.Received,
			"Expected %s to %sbe truthy",
			Readable(self.Received),
			FlipTag(self.Flipped)
		)
	end,

	ToThrow = function(self: ConditionState, Expected: string?)
		AssertExpect(
			false,
			type(self.Received) == "function",
			"Expected %s to %sbe a function",
			Readable(self.Received),
			FlipTag(self.Flipped)
		)
		local Success, Error = pcall(self.Received)
		if Expected == nil then
			AssertExpect(
				self.Flipped,
				not Success,
				"Expected %s to %sthrow an error",
				Readable(self.Received),
				FlipTag(self.Flipped)
			)
			return
		end

		AssertExpect(false, type(Error) == "string", "Expected error to be a string (got %s)", Readable(Error))
		AssertExpect(
			false,
			not Success,
			"Expected %s to %sthrow an error",
			Readable(self.Received),
			FlipTag(self.Flipped)
		)
		local Stripped = (Error :: string):match(`^.+:%d+: (.+)$`)
		if Stripped then
			AssertExpect(
				self.Flipped,
				Stripped == Expected,
				"Got error %s expected to %sthrow %s",
				Readable(Stripped),
				FlipTag(self.Flipped),
				Readable(Expected)
			)
		else
			AssertExpect(
				self.Flipped,
				Error == Expected,
				"Got error %s expected to %sthrow %s",
				Readable(Error),
				FlipTag(self.Flipped),
				Readable(Expected)
			)
		end
	end,
}

Conditionals.ToEqual = Conditionals.ToBe

local function DeepScan(Any: any, Second: any, State: { [any]: any }, Key: string?): { string }
	if Any == Second then
		return {}
	end

	if Conditional.Is(Any) then
		if Any.Name ~= "@similar" then
			local Result, _, Reason = (Any :: any)(Second)
			if not Result then
				return { `{Key or ""}{if Reason then string.format(Reason, "") else "failed condition"}` }
			end
			return {}
		end
		Any = Any.Value
	end

	if type(Any) ~= type(Second) then
		return { `{Key or ""}(type: {type(Any)}) ~= (type: {type(Second)})` }
	end

	if type(Any) ~= "table" then
		return { `{Key or ""}(value: {Readable(Any)}) ~= (value: {Readable(Second)})` }
	end

	if State[Any] == Second then
		return {}
	end

	State[Any] = Second
	local Chunk = {}
	local KeysHit = {}
	for EntryKey, Value in Any do
		local Result = DeepScan(Value, Second[EntryKey], State, `[{Readable(EntryKey)}]: `)
		if #Result > 0 then
			KeysHit[EntryKey] = true
		end
		for _, Difference in Result do
			table.insert(Chunk, `{Difference}`)
		end
	end

	for EntryKey, Value in Second do
		local Result = DeepScan(Any[EntryKey], Value, State, `[{Readable(EntryKey)}]: `)
		if KeysHit[EntryKey] then
			continue
		end
		for _, Difference in Result do
			table.insert(Chunk, `{Difference}`)
		end
	end

	if #Chunk > 0 then
		table.insert(Chunk, 1, `{Key or ""}\{`)
		table.insert(Chunk, `\}`)
		return Chunk
	end
	return {}
end

local NormalState: ConditionState = { Received = nil, Flipped = false }
local NeverState: ConditionState = { Received = nil, Flipped = true }

local NormalMethods: { [string]: (...any) -> () } = {}
local NeverMethods: { [string]: (...any) -> () } = {}
for Key, Function in Conditionals :: { [string]: (...any) -> () } do
	NormalMethods[Key] = function(...)
		return Function(NormalState, ...)
	end
	NeverMethods[Key] = function(...)
		return Function(NeverState, ...)
	end
end
(NormalMethods :: any).Never = NeverMethods

local Expect = setmetatable({
	Nothing = Conditional.New("nothing", function(Value)
		return Value == nil
	end),

	Any = function(TypeName: string)
		if type(TypeName) ~= "string" then
			error(`Expect.Any expected string, got {type(TypeName)}`, 2)
		end
		return Conditional.New(TypeName, function(Value)
			local Type = type(Value)
			return Type == TypeName, Type, `value is supposed to %sbe of type {TypeName}, got {Type}`
		end)
	end,

	Type = function(TypeName: string)
		if type(TypeName) ~= "string" then
			error(`Expect.Type expected string, got {type(TypeName)}`, 2)
		end
		return Conditional.New(TypeName, function(Value)
			local Type = type(Value)
			return Type == TypeName, Type, `value is supposed to %sbe of type {TypeName}, got {Type}`
		end)
	end,

	Similar = function(Table: { [any]: any })
		if type(Table) ~= "table" then
			error(`Expect.Similar expected table, got {type(Table)}`, 2)
		end
		return Conditional.New("@similar", function(Value)
			local Result = DeepScan(Table, Value, {})
			return #Result == 0, nil, `value is supposed to %sbe similar to value, got:\n{table.concat(Result, "\n")}`
		end, Table)
	end,
}, {
	__call = function(_self: any, Value: any)
		NormalState.Received = Value
		NeverState.Received = Value
		return NormalMethods
	end,
})

Testing.Expect = Expect

Testing.Expected = function(Any: any)
	if not Any then
		error("Truthy value expected", 2)
	end
end

Testing.ExpectEqual = function(Any: any, Second: any)
	if Any ~= Second then
		error(string.format("Expected %s to be equal to %s", Readable(Any), Readable(Second)), 2)
	end
end

return (Testing :: any) :: TestingLib
