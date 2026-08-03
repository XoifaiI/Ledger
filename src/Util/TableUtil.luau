--!strict
--!optimize 2

-- small grab bag of table helpers, add to it only when something actually needs it

local function Occupied(Value: any): boolean
	return type(Value) == "table" and next(Value) ~= nil
end

local function DeepCopy<T>(Value: T, Seen: {[any]: any}?): T
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
	DeepCopy = DeepCopy,
	DeepFreeze = DeepFreeze,
	FreezeDelta = FreezeDelta
})
