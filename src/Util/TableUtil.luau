--!strict
--!optimize 2

--[=[

	TableUtil: Small helpers for tables.

	Copying, comparing and freezing, deeply. FreezeDelta remembers what it has already frozen, so it
	only walks the part of a state that changed.

	Return type: A table with Occupied, Count, Some, DeepEqual, DeepCopy, DeepFreeze and FreezeDelta.
	Example usage:
		local TableUtil = require("./TableUtil")
		local Copy = TableUtil.DeepCopy(State)
--]=]

local function Occupied(Value: any): boolean
	return type(Value) == "table" and next(Value) ~= nil
end

local function Count(Value: any): number
	if type(Value) ~= "table" then
		return 0
	end

	local Total = 0
	for _ in Value do
		Total += 1
	end
	return Total
end

local function Some<T>(Entries: T): T?
	if type(Entries) ~= "table" then
		return nil
	end
	return if next(Entries :: any) == nil then nil else Entries
end

local function DeepEqual(Left: any, Right: any): boolean
	if Left == Right then
		return true
	end
	if type(Left) ~= "table" or type(Right) ~= "table" then
		return type(Left) == "buffer" and type(Right) == "buffer" and buffer.tostring(Left) == buffer.tostring(Right)
	end

	local Held = 0
	for Key, Value in Left do
		if not DeepEqual(Value, Right[Key]) then
			return false
		end
		Held += 1
	end
	return Held == Count(Right)
end

local function DeepCopy<T>(Value: T, Seen: { [any]: any }?): T
	if type(Value) == "buffer" then
		local Fresh = buffer.create(buffer.len(Value :: any))
		buffer.copy(Fresh, 0, Value :: any)
		return Fresh :: any
	end
	if type(Value) ~= "table" then
		return Value
	end

	local Tracked = Seen or {}
	if Tracked[Value] then
		return Tracked[Value]
	end

	local Result = {}
	Tracked[Value] = Result

	for Key, Inner in Value :: any do
		Result[Key] = DeepCopy(Inner, Tracked)
	end

	return Result :: any
end

local function DeepFreeze<T>(Value: T, Seen: { [any]: boolean }?): T
	if type(Value) ~= "table" then
		return Value
	end

	local Tracked = Seen or {}
	if Tracked[Value] then
		return Value
	end
	Tracked[Value] = true

	for _, Inner in Value :: any do
		DeepFreeze(Inner, Tracked)
	end

	if not table.isfrozen(Value :: any) then
		table.freeze(Value :: any)
	end
	return Value
end

local Ours: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function FreezeDelta<T>(Value: T): T
	if type(Value) ~= "table" or Ours[Value :: any] then
		return Value
	end

	if not table.isfrozen(Value :: any) then
		table.freeze(Value :: any)
	end
	Ours[Value :: any] = true

	for _, Inner in Value :: any do
		FreezeDelta(Inner)
	end
	return Value
end

return table.freeze({
	Occupied = Occupied,
	Count = Count,
	Some = Some,
	DeepEqual = DeepEqual,
	DeepCopy = DeepCopy,
	DeepFreeze = DeepFreeze,
	FreezeDelta = FreezeDelta,
})
