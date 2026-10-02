--!strict
--!optimize 2
--!native

--[=[
	Canon: Plumbing. Prints a game value the same way on every server.

	Each value is a tag byte and its body, and table keys are sorted with numbers first. So two values
	print the same only when they hold the same things. Prints are hashed into stored fingerprints, so
	the tags and the layout must never change. It throws on a nan, on a key that is not a number or a
	string, and on a table nested past Limits.DEPTH_MAX.

	Return type: A function that gives back the print as a string.
	Example usage:
		local Print = Canon(Terms)
--]=]

local Limits = require("../Core/Constants/Limits")

local TAG_NUMBER = 1
local TAG_STRING = 2
local TAG_BUFFER = 3
local TAG_FALSE = 4
local TAG_TRUE = 5
local TAG_TABLE = 6
local TAG_BYTES = 1
local NUMBER_BYTES = 8
local LENGTH_BYTES = 4

local Out = buffer.create(512)
local Cursor = 0

local function Reserve(Count: number)
	local Size = buffer.len(Out)
	if Cursor + Count <= Size then
		return
	end
	while Size < Cursor + Count do
		Size *= 2
	end
	local Grown = buffer.create(Size)
	buffer.copy(Grown, 0, Out, 0, Cursor)
	Out = Grown
end

local function Before(Left: number | string, Right: number | string): boolean
	if type(Left) == type(Right) then
		return (Left :: any) < (Right :: any)
	end
	return type(Left) == "number"
end

local function Emit(Value: unknown, Depth: number)
	local Kind = type(Value)
	if Kind == "number" and Value == Value then
		Reserve(TAG_BYTES + NUMBER_BYTES)
		buffer.writeu8(Out, Cursor, TAG_NUMBER)
		buffer.writef64(Out, Cursor + TAG_BYTES, if Value == 0 then 0 else Value :: number)
		Cursor += TAG_BYTES + NUMBER_BYTES
	elseif Kind == "string" or Kind == "buffer" then
		local Text = if Kind == "buffer" then buffer.tostring(Value :: buffer) else Value :: string
		local Head = TAG_BYTES + LENGTH_BYTES
		Reserve(Head + #Text)
		buffer.writeu8(Out, Cursor, if Kind == "string" then TAG_STRING else TAG_BUFFER)
		buffer.writeu32(Out, Cursor + TAG_BYTES, #Text)
		buffer.writestring(Out, Cursor + Head, Text)
		Cursor += Head + #Text
	elseif Kind == "boolean" then
		Reserve(TAG_BYTES)
		buffer.writeu8(Out, Cursor, if Value then TAG_TRUE else TAG_FALSE)
		Cursor += TAG_BYTES
	elseif Kind == "table" and Depth < Limits.DEPTH_MAX then
		local Table = Value :: { [unknown]: unknown }
		local Keys: { number | string } = {}
		for Key in Table do
			if type(Key) ~= "number" and type(Key) ~= "string" then
				error(`Canon: a table key is a {typeof(Key)}`, 0)
			end
			table.insert(Keys, Key :: number | string)
		end
		table.sort(Keys, Before)
		Reserve(TAG_BYTES + LENGTH_BYTES)
		buffer.writeu8(Out, Cursor, TAG_TABLE)
		buffer.writeu32(Out, Cursor + TAG_BYTES, #Keys)
		Cursor += TAG_BYTES + LENGTH_BYTES
		for _, Key in Keys do
			Emit(Key, Depth + 1)
			Emit(Table[Key], Depth + 1)
		end
	else
		error(`Canon: cannot print a {typeof(Value)}, a nan, or a table nested past {Limits.DEPTH_MAX}`, 0)
	end
end

local function Canon(Value: unknown): string
	Cursor = 0
	Emit(Value, 0)
	return buffer.readstring(Out, 0, Cursor)
end

return Canon
