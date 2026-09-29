--!strict
--!optimize 2

--[=[

	Guard: Runs the game's reducer so that it sees and changes only what its build declares.

	The guard sets aside the top level fields the build does not declare and puts them back after the
	reducer runs. It refuses a state that adds a field the build does not declare, or that leaves a
	money field holding anything but a whole number below 2^53. A capped guard also measures the state
	after each op, and gives back Fate.Full past StateCap and nil when the state cannot be stored.
	Admits is the same check for any state a build makes, such as a migration's.

	Return type: A table with Plain, Capped and Admits.
	Example usage:
		local Guard = require("./Guard")
		local Reducer = Guard.Plain(Build)
		local Kept = Guard.Admits(Build, Before, After)
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

local function Admits(Build: Build, Before: State, After: State): boolean
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
		if type(Next) ~= "table" or not Admits(Build, Given, Next :: State) then
			return nil
		end
		local Result = Next :: State
		for Field, Held in Aside do
			Result[Field] = Held
		end
		return Result
	end
end

local function Plain(Build: Build): Reducer
	local Guarded = Plains[Build]
	if Guarded == nil then
		Guarded = MakePlain(Build)
		Plains[Build] = Guarded
	end
	return Guarded
end

local function MakeCapped(Build: Build): Reducer
	local Guarded = Plain(Build)
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

local function Capped(Build: Build): Reducer
	local Guarded = Cappeds[Build]
	if Guarded == nil then
		Guarded = MakeCapped(Build)
		Cappeds[Build] = Guarded
	end
	return Guarded
end

return table.freeze({
	Plain = Plain,
	Capped = Capped,
	Admits = Admits,
})
