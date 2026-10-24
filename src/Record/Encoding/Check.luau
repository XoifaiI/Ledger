--!strict
--!optimize 2

--[=[
	Check: pure validation rules. A rule is a function of one value that gives back nothing when the value
	is fine, or the text of what it must be.

	Table runs rules over a table of options and throws on a problem. Which of several wrong keys it names
	is not defined.

	Return type: The Check table, and the Rule type.
	Example usage:
		Check.Table(Options, { Name = Check.Text(1, 64), Rooms = Check.Optional(Check.Whole(1, 8)) }, "Ledger.New")
--]=]

export type Rule = (Value: unknown) -> string?

local FunctionWanted = "a function"
local BooleanWanted = "true or false"
local ArrayWithNoGaps = "an array with no gaps"
local TableWanted = "a table"

local function WholeNumberWanted(Least: number, Most: number): string
	return `a whole number from {Least} to {Most}`
end

local function WholeAtLeastWanted(Least: number): string
	return `a whole number of at least {Least}`
end

local function TextAtLeastWanted(MinLength: number): string
	return `a string of valid UTF-8 whose byte length is at least {MinLength}`
end

local function TextOfBytesWanted(LeastLength: number, MostLength: number): string
	return `a string of {LeastLength} to {MostLength} bytes of valid UTF-8`
end

local function ListAtMostWanted(Most: number): string
	return `an array of at most {Most} items`
end

local function OneOfWanted(Choices: string): string
	return `one of {Choices}`
end

local function OrNilWanted(What: string): string
	return `{What}, or nil`
end

local function ArrayWhoseItem(Index: number, What: string): string
	return `an array whose item {Index} is {What}`
end

local function TableWhoseKey(Key: string, What: string): string
	return `a table whose key {Key} is {What}`
end

local function TableWhoseItem(Key: string, What: string): string
	return `a table whose item {Key} is {What}`
end

local function OptionsNotTable(Where: string, Got: string): string
	return `{Where}: options must be a table, got {Got}`
end

local function MustBe(Where: string, Key: string, What: string, Got: string): string
	return `{Where}: {Key} must be {What}, got {Got}`
end

local function NotAnOption(Where: string, Key: string, Got: string): string
	return `{Where}: {Key} must be left out, it is not an option here, got {Got}`
end

local function Describe(Value: unknown): string
	if type(Value) == "string" then
		return `"{Value}"`
	end
	if type(Value) == "table" then
		return TableWanted
	end
	if type(Value) == "function" then
		return FunctionWanted
	end
	return tostring(Value)
end

local function Whole(Least: number, Most: number): Rule
	local Wanted = WholeNumberWanted(Least, Most)
	return function(Value: unknown): string?
		if type(Value) == "number" and Value % 1 == 0 and Value >= Least and Value <= Most then
			return nil
		end
		return Wanted
	end
end

local function Text(MinLength: number, MaxLength: number): Rule
	local Wanted = TextOfBytesWanted(MinLength, MaxLength)
	return function(Value: unknown): string?
		if type(Value) == "string" and #Value >= MinLength and #Value <= MaxLength and utf8.len(Value) ~= nil then
			return nil
		end
		return Wanted
	end
end

local function WholeAtLeast(Least: number): Rule
	local Wanted = WholeAtLeastWanted(Least)
	return function(Value: unknown): string?
		if type(Value) == "number" and Value % 1 == 0 and Value >= Least then
			return nil
		end
		return Wanted
	end
end

local function TextAtLeast(MinLength: number): Rule
	local Wanted = TextAtLeastWanted(MinLength)
	return function(Value: unknown): string?
		if type(Value) == "string" and #Value >= MinLength and utf8.len(Value) ~= nil then
			return nil
		end
		return Wanted
	end
end

local function OneOf(...: unknown): Rule
	local Allowed = table.pack(...)
	local Names = {}
	for Index = 1, Allowed.n do
		table.insert(Names, Describe(Allowed[Index]))
	end
	local Wanted = OneOfWanted(table.concat(Names, ", "))
	return function(Value: unknown): string?
		for Index = 1, Allowed.n do
			if Allowed[Index] == Value then
				return nil
			end
		end
		return Wanted
	end
end

local function Optional(Item: Rule): Rule
	return function(Value: unknown): string?
		if Value == nil then
			return nil
		end
		local Wanted = Item(Value)
		if Wanted == nil then
			return nil
		end
		return OrNilWanted(Wanted)
	end
end

local function List(Item: Rule): Rule
	return function(Value: unknown): string?
		if type(Value) ~= "table" then
			return ArrayWithNoGaps
		end
		local Held = Value :: { [unknown]: unknown }
		local Length = #Held
		local Count = 0
		for _ in Held do
			Count += 1
		end
		if Count ~= Length then
			return ArrayWithNoGaps
		end
		for Index = 1, Length do
			local Problem = Item(Held[Index])
			if Problem ~= nil then
				return ArrayWhoseItem(Index, Problem)
			end
		end
		return nil
	end
end

local function Map(KeyRule: Rule, ItemRule: Rule): Rule
	return function(Value: unknown): string?
		if type(Value) ~= "table" then
			return TableWanted
		end
		for Key, Item in Value :: { [unknown]: unknown } do
			local KeyProblem = KeyRule(Key)
			if KeyProblem ~= nil then
				return TableWhoseKey(Describe(Key), KeyProblem)
			end
			local ItemProblem = ItemRule(Item)
			if ItemProblem ~= nil then
				return TableWhoseItem(Describe(Key), ItemProblem)
			end
		end
		return nil
	end
end

local function ListAtMost(Item: Rule, Most: number): Rule
	local Items = List(Item)
	local TooLong = ListAtMostWanted(Most)
	return function(Value: unknown): string?
		local Problem = Items(Value)
		if Problem ~= nil then
			return Problem
		end
		if type(Value) == "table" and #Value > Most then
			return TooLong
		end
		return nil
	end
end

local function AnyValue(Value: unknown): string?
	return nil
end

local function Function(Value: unknown): string?
	if type(Value) == "function" then
		return nil
	end
	return FunctionWanted
end

local function Boolean(Value: unknown): string?
	if type(Value) == "boolean" then
		return nil
	end
	return BooleanWanted
end

local function Table(Value: unknown, Rules: { [string]: Rule }, Where: string): ()
	if type(Value) ~= "table" then
		error(OptionsNotTable(Where, Describe(Value)), 0)
	end
	local Held = Value :: { [unknown]: unknown }
	for Key, Rule in Rules do
		local Problem = Rule(Held[Key])
		if Problem ~= nil then
			error(MustBe(Where, Key, Problem, Describe(Held[Key])), 0)
		end
	end
	for Key, Item in Held do
		if type(Key) ~= "string" or Rules[Key] == nil then
			error(NotAnOption(Where, tostring(Key), Describe(Item)), 0)
		end
	end
end

return table.freeze({
	Whole = Whole,
	Text = Text,
	WholeAtLeast = WholeAtLeast,
	TextAtLeast = TextAtLeast,
	OneOf = OneOf,
	Optional = Optional,
	List = List,
	ListAtMost = ListAtMost,
	AnyValue = AnyValue,
	Map = Map,
	Function = Function,
	Boolean = Boolean,
	Table = Table,
})
