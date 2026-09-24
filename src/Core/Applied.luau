--!strict
--!optimize 2

--[=[

	Applied: The set of applied names a key keeps in its own state.

	Each name is tagged by what it was, so a transfer, a sent hold, a transaction and a Once name
	cannot collide. Names sit in one bucket per day, taken from the time the op carries, and an
	entry holds the mark of what the name meant or true. A write drops each whole day that is past
	the prune window, so a name is kept for that window and at most one day more. A write copies
	only its own day, so the cost of a write does not grow with the names on the key.

	Records before 6.0 hold one flat entry per name, with the time in the entry. The next write of a
	name puts those into day buckets, and until then a lookup reads a flat entry as it is.

	Return type: A table with Key, Has, Recall, Remember, Prune and Upgraded. The type is Recalled.
	Example usage:
		local Applied = require("./Applied")
		if Applied.Has(Names, Tags.ONCE, "gift") then return end
--]=]

local Tags = require("./Constants/Tags")
local Windows = require("./Constants/Windows")

export type Recalled = Tags.Recalled

type Bucket = { [string]: string | true }
type Days = { [string]: Bucket }

local TAGS: { [string]: boolean } = { [Tags.TRANSFER] = true, [Tags.TX] = true, [Tags.ONCE] = true, [Tags.SENT] = true }

local DAY = "d"
local DAY_PATTERN = "^d(%-?%d+)$"

local function Key(Tag: string, Id: string): string
	assert(TAGS[Tag], "an applied name has to be tagged transfer, transaction, once or sent")
	assert(type(Id) == "string" and #Id > 0, "an applied name cannot be empty, or two of them would share an entry")
	return `{Tag}{Id}`
end

local function DayOf(At: number): string
	return `{DAY}{At // Windows.DAY}`
end

local function Keeps(Name: string, Floor: number): boolean
	local Digits = string.match(Name, DAY_PATTERN)
	local Day = if Digits ~= nil then tonumber(Digits) else nil
	return Day ~= nil and (Day + 1) * Windows.DAY > Floor
end

local function Split(Value: any): (number?, string?)
	if type(Value) == "number" then
		return Value, nil
	end
	if type(Value) ~= "string" then
		return nil, nil
	end

	local At = string.find(Value, Tags.MEANT, 1, true)
	if At == nil then
		return nil, nil
	end
	return tonumber(string.sub(Value, 1, At - 1)), string.sub(Value, At + 1)
end

local function Printed(Value: any): string?
	if type(Value) ~= "string" then
		return nil
	end
	local At = string.find(Value, Tags.MEANT, 1, true)
	return if At == nil then Value else string.sub(Value, At + 1)
end

local function Upgraded(Received: any): Days
	if type(Received) ~= "table" then
		return {}
	end

	local Flat = false
	for _, Value in Received do
		if type(Value) ~= "table" then
			Flat = true
			break
		end
	end
	if not Flat then
		return Received
	end

	local Out: Days = {}
	local Copied: { [string]: boolean } = {}
	local function Into(Slot: string): Bucket
		if not Copied[Slot] then
			Out[Slot] = table.clone(Out[Slot] or {})
			Copied[Slot] = true
		end
		return Out[Slot]
	end

	for Name, Value in Received do
		if type(Value) == "table" then
			if Out[Name] == nil then
				Out[Name] = Value
				continue
			end
			local Held = Into(Name)
			for Entry, Meant in Value do
				Held[Entry] = Meant
			end
			continue
		end

		local At, Meant = Split(Value)
		if At == nil then
			continue
		end
		Into(DayOf(At))[Name] = if Meant ~= nil then Meant else true
	end
	return Out
end

local function Find(Received: any, Tag: string, Id: string): any
	if type(Received) ~= "table" then
		return nil
	end

	local Name = Key(Tag, Id)
	local Flat = Received[Name]
	if Flat ~= nil then
		return Flat
	end

	for _, Bucket in Received do
		if type(Bucket) == "table" then
			local Held = Bucket[Name]
			if Held ~= nil then
				return Held
			end
		end
	end
	return nil
end

local function Has(Received: any, Tag: string, Id: string): boolean
	return Find(Received, Tag, Id) ~= nil
end

local function Recall(Received: any, Tag: string, Id: string, Print: string?): Recalled
	local Value = Find(Received, Tag, Id)
	if Value == nil then
		return Tags.UNSEEN
	end

	local Held = Printed(Value)
	if Held == nil or Print == nil then
		return Tags.SAME
	end
	return if Held == Print then Tags.SAME else Tags.OTHER
end

local function Remember(Received: any, Id: string, Stamped: number, Print: string?): Days
	local Floor = Stamped - Windows.PRUNE
	local Next: Days = {}
	for Name, Bucket in Upgraded(Received) do
		if Keeps(Name, Floor) then
			Next[Name] = Bucket
		end
	end

	local Slot = DayOf(Stamped)
	local Bucket: Bucket = table.clone(Next[Slot] or {})
	Bucket[Id] = if Print ~= nil then Print else true
	Next[Slot] = Bucket
	return Next
end

local function Prune(Received: any, Stamped: any): Days?
	if type(Received) ~= "table" or type(Stamped) ~= "number" then
		return nil
	end

	local Days = Upgraded(Received)
	local Floor = Stamped - Windows.PRUNE
	local Kept: Days = {}
	local Changed = Days ~= Received
	for Name, Bucket in Days do
		if Keeps(Name, Floor) then
			Kept[Name] = Bucket
		else
			Changed = true
		end
	end
	return if Changed then Kept else nil
end

return table.freeze({
	Key = Key,
	Has = Has,
	Recall = Recall,

	Remember = Remember,
	Prune = Prune,
	Upgraded = Upgraded,
})
