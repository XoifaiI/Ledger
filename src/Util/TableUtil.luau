--!strict
--!optimize 2

--[=[
    TableUtil: small grab bag of table helpers, add to it only when something actually needs it

    Return type: frozen table { DeepCopy, DeepEqual, Without, DeepFreeze }
    Example usage:
        local TableUtil = require("./TableUtil")
        local Copy = TableUtil.DeepCopy(Original)
        local Same = TableUtil.DeepEqual(Copy, Original)
--]=]

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

local function DeepEqual(A: any, B: any): boolean
	if A == B then
		return true
	end

	if type(A) ~= "table" or type(B) ~= "table" then
		return false
	end

	for Key, Value in A do
		if not DeepEqual(Value, B[Key]) then
			return false
		end
	end

	for Key in B do
		if A[Key] == nil then
			return false
		end
	end

	return true
end

local function Without<T>(Source: T, Keys: {string}): T
	if type(Source) ~= "table" then
		return Source
	end

	local Result = {}
	for Key, Value in Source :: any do
		Result[Key] = Value
	end

	for _, Key in Keys do
		Result[Key] = nil
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

return table.freeze({
	DeepCopy = DeepCopy,
	DeepEqual = DeepEqual,
	Without = Without,
	DeepFreeze = DeepFreeze,
})
