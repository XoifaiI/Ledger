--!strict
--!optimize 2

-- small grab bag of table helpers, add to it only when something actually needs it

local function Occupied(Value: any): boolean
	return type(Value) == "table" and next(Value) ~= nil
end

local function DeepCopy<T>(Value: T, Seen: {[any]: any}?): T
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

local function DeepFreeze<T>(Value: T): T
	if type(Value) ~= "table" then
		return Value
	end

	for _, Inner in Value :: any do
		DeepFreeze(Inner)
	end

	if not table.isfrozen(Value :: any) then
		table.freeze(Value :: any)
	end
	return Value
end

local function FreezeDelta<T>(Value: T): T
	if type(Value) ~= "table" or table.isfrozen(Value :: any) then
		return Value
	end

	table.freeze(Value :: any)
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
