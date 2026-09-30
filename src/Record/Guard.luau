--!strict
--!optimize 2

--[=[

	Guard: Logic. Runs the game's reducer on only the fields its build declares.

	Spec: record 4, step 9.

	Undeclared top level fields are set aside and put back. A result that adds one, or leaves a money
	field anything but a whole number below 2^53, is refused. Capped also gives Fate.Full past
	StateCap. Admits is the same check for a migration.

	Return type: A table with Plain, Capped and Admits.
	Example usage:
		local Reducer = Guard.Plain(Build)
--]=]

local Book = require("./Book")
local Reduce = require("../Core/Reduce")
local Types = require("./Types")
local Value = require("../Encode/Value")

type Build = Types.Build
type Reducer = Reduce.Reducer<any, any>
type State = { [string]: any }

local Fate = Book.Fate

local Plains: { [Build]: Reducer } = setmetatable({}, { __mode = "k" }) :: any
local Cappeds: { [Build]: Reducer } = setmetatable({}, { __mode = "k" }) :: any

local Guard = {}

function Guard.Admits(Build: Build, Before: State, After: State): boolean
	for Field in After do
		if not Build.Fields[Field] and Before[Field] == nil then
			return false
		end
	end
	for _, Field in Build.Money do
		local Amount = After[Field]
		if not (type(Amount) == "number" and Amount % 1 == 0 and math.abs(Amount) < 2 ^ 53) then
			return false
		end
	end
	return true
end

local function SetAside(Build: Build, State: State): (State, State)
	local Aside: State = {}
	local Given = State
	for Field, Held in State do
		if Build.Fields[Field] then
			continue
		end
		if Given == State then
			Given = table.clone(State)
		end
		Aside[Field] = Held
		Given[Field] = nil
	end
	return Given, Aside
end

local function MakePlain(Build: Build): Reducer
	return function(State: State, Op: unknown): unknown
		local Given, Aside = SetAside(Build, State)
		local Next = Build.Reducer(Given, Op)
		if type(Next) ~= "table" or not Guard.Admits(Build, Given, Next :: State) then
			return nil
		end
		local Result = Next :: State
		for Field, Held in Aside do
			Result[Field] = Held
		end
		return Result
	end
end

function Guard.Plain(Build: Build): Reducer
	local Guarded = Plains[Build]
	if Guarded == nil then
		Guarded = MakePlain(Build)
		Plains[Build] = Guarded
	end
	return Guarded
end

local function MakeCapped(Build: Build): Reducer
	local Guarded = Guard.Plain(Build)
	return function(State: State, Op: unknown): unknown
		local Result = Guarded(State, Op)
		if type(Result) ~= "table" then
			return nil
		end
		local Bytes = Value.Check(Result)
		if Bytes == nil then
			return nil
		end
		return if Bytes > Build.StateCap then Fate.Full else Result
	end
end

function Guard.Capped(Build: Build): Reducer
	local Guarded = Cappeds[Build]
	if Guarded == nil then
		Guarded = MakeCapped(Build)
		Cappeds[Build] = Guarded
	end
	return Guarded
end

return Guard
