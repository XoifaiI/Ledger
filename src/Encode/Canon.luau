--!strict
--!optimize 2
--!native

--[=[

	Canon: Prints a game value the same way on every server, for its fingerprint.

	Each value is a tag byte and its body: a number as its 8 bytes, a string or a buffer as its length
	and bytes, a table as its entry count and its entries with the keys sorted, numbers first. Two
	values print the same only when they hold the same things.

	Return type: A function that gives back the print as a string.
	Example usage:
		local Canon = require("./Canon")
		local Print = Canon(Op)
--]=]

local MAX_DEPTH = 64

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
		Reserve(9)
		buffer.writeu8(Out, Cursor, 1)
		buffer.writef64(Out, Cursor + 1, if Value == 0 then 0 else Value :: number)
		Cursor += 9
	elseif Kind == "string" or Kind == "buffer" then
		local Text = if Kind == "buffer" then buffer.tostring(Value :: buffer) else Value :: string
		Reserve(5 + #Text)
		buffer.writeu8(Out, Cursor, if Kind == "string" then 2 else 3)
		buffer.writeu32(Out, Cursor + 1, #Text)
		buffer.writestring(Out, Cursor + 5, Text)
		Cursor += 5 + #Text
	elseif Kind == "boolean" then
		Reserve(1)
		buffer.writeu8(Out, Cursor, if Value then 5 else 4)
		Cursor += 1
	elseif Kind == "table" and Depth < MAX_DEPTH then
		local Table = Value :: { [unknown]: unknown }
		local Keys: { number | string } = {}
		for Key in Table do
			if type(Key) ~= "number" and type(Key) ~= "string" then
				error(`Canon: a table key is a {typeof(Key)}`, 0)
			end
			table.insert(Keys, Key :: number | string)
		end
		table.sort(Keys, Before)
		Reserve(5)
		buffer.writeu8(Out, Cursor, 6)
		buffer.writeu32(Out, Cursor + 1, #Keys)
		Cursor += 5
		for _, Key in Keys do
			Emit(Key, Depth + 1)
			Emit(Table[Key], Depth + 1)
		end
	else
		error(`Canon: cannot print a {typeof(Value)}, a nan, or a table nested past {MAX_DEPTH}`, 0)
	end
end

local function Canon(Value: unknown): string
	Cursor = 0
	Emit(Value, 0)
	return buffer.readstring(Out, 0, Cursor)
end

return Canon
