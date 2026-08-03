--!strict
--!optimize 2

-- a store and a key flattened into one string, length prefixed so a delimiter byte in either cant bend the parse. older unprefixed marks still read

local FIELD = "\0"
local LIST = "\1"

local function ToCount(Prefix: string): number?
	if string.match(Prefix, "^%d+$") == nil then
		return nil
	end
	return tonumber(Prefix)
end

local function Of(Store: string, Key: string): string
	local Made = `{#Store}{FIELD}{Store}{Key}`
	assert(string.sub(Made, #tostring(#Store) + 2, #tostring(#Store) + 1 + #Store) == Store, "a mark cannot read back the store it was built from")
	return Made
end

local function Split(Mark: string): (string?, string?)
	local At = string.find(Mark, FIELD, 1, true)
	if At == nil then
		return nil, nil
	end

	local Count = ToCount(string.sub(Mark, 1, At - 1))
	if Count == nil or At + Count > #Mark then
		return string.sub(Mark, 1, At - 1), string.sub(Mark, At + 1)
	end
	return string.sub(Mark, At + 1, At + Count), string.sub(Mark, At + Count + 1)
end

local function Pack(Parts: { string }): string
	local Sized: { string } = table.create(#Parts) :: { string }
	local Total = 0
	for Index, Part in Parts do
		local Framed = `{#Part}{LIST}{Part}`
		Sized[Index] = Framed
		Total += #Framed
	end

	local Packed = table.concat(Sized)
	assert(#Packed == Total, "packing marks lost bytes, so one of them holds a byte the format cannot carry")
	return Packed
end

local function Unpack(Packed: string): { string }
	local Parts: { string } = {}
	local At = 1

	while At <= #Packed do
		local Stop = string.find(Packed, LIST, At, true)
		local Count = if Stop ~= nil then ToCount(string.sub(Packed, At, Stop - 1)) else nil
		if Stop == nil or Count == nil or Stop + Count > #Packed then
			return string.split(Packed, LIST)
		end

		local Part = string.sub(Packed, Stop + 1, Stop + Count)
		assert(#Part == Count, "unpacking a mark read fewer bytes than its own length said it had")
		table.insert(Parts, Part)
		At = Stop + Count + 1
	end

	return Parts
end

return table.freeze({
	FIELD = FIELD,
	LIST = LIST,
	Of = Of,
	Split = Split,
	Pack = Pack,
	Unpack = Unpack
})
