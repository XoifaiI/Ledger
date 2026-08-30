--!strict
--!optimize 2

--[=[

	Applied: The set of applied names a key keeps in its own state.

	Each name is tagged by what it was, so a transfer, a transaction, a Once name and a grant cannot
	collide. An entry holds the time of the write and a mark of what the name meant. Names older than
	the prune window are dropped on the next write.

	Return type: A table with the five tags, the three recalls, Key, Entry, At, Meant, Find, Has, Recall, Tagged, Remember and Prune.
	Example usage:
		local Applied = require("./Applied")
		if Applied.Has(Names, Applied.ONCE, "gift") then return end
--]=]

local Windows = require("./Constants/Windows")

local TRANSFER = "t:"
local TX = "x:"
local ONCE = "o:"
local SENT = "s:"
local GRANT = "g:"

local MEANT = "#"

export type Recalled = "Unseen" | "Same" | "Other"

local UNSEEN: Recalled = "Unseen"
local SAME: Recalled = "Same"
local OTHER: Recalled = "Other"

local TAGS: { [string]: boolean } = { [TRANSFER] = true, [TX] = true, [ONCE] = true, [SENT] = true, [GRANT] = true }

local function Key(Tag: string, Id: string): string
	assert(TAGS[Tag], "an applied name has to be tagged transfer, transaction, once, sent or grant")
	assert(type(Id) == "string" and #Id > 0, "an applied name cannot be empty, or two of them would share an entry")
	return `{Tag}{Id}`
end

local function Entry(At: number, Meant: string?): any
	if Meant == nil then
		return At
	end
	return `{At}{MEANT}{Meant}`
end

local function Cut(Value: any): number?
	if type(Value) ~= "string" then
		return nil
	end
	return (string.find(Value, MEANT, 1, true))
end

local function At(Value: any): number?
	if type(Value) == "number" then
		return Value
	end

	local Split = Cut(Value)
	return if Split == nil then nil else tonumber(string.sub(Value :: string, 1, Split - 1))
end

local function Meant(Value: any): string?
	local Split = Cut(Value)
	return if Split == nil then nil else string.sub(Value :: string, Split + 1)
end

local function Find(Received: any, Tag: string, Id: string): any
	if type(Received) ~= "table" then
		return nil
	end

	return Received[Key(Tag, Id)]
end

local function Has(Received: any, Tag: string, Id: string): boolean
	return Find(Received, Tag, Id) ~= nil
end

local function Recall(Received: any, Tag: string, Id: string, Print: string?): Recalled
	local Value = Find(Received, Tag, Id)
	if Value == nil then
		return UNSEEN
	end

	local Held = Meant(Value)
	if Held == nil or Print == nil then
		return SAME
	end
	return if Held == Print then SAME else OTHER
end

local function Tagged(Id: any, Tag: string): boolean
	return type(Id) == "string" and string.sub(Id, 1, #Tag) == Tag
end

local function Fresh(Stamp: any, Floor: number): boolean
	local When = At(Stamp)
	return When ~= nil and When >= Floor
end

local function AnyOlderThan(Received: { [string]: any }, Floor: number): boolean
	for _, Stamp in Received do
		if not Fresh(Stamp, Floor) then
			return true
		end
	end
	return false
end

local function Survivors(Received: { [string]: any }, Floor: number): ({ [string]: any }, boolean)
	local Kept: { [string]: any } = {}
	local Dropped = false
	for Name, Stamp in Received do
		if Fresh(Stamp, Floor) then
			Kept[Name] = Stamp
		else
			Dropped = true
		end
	end
	return Kept, Dropped
end

local function Remember(Received: any, Id: string, Stamped: number, Print: string?): { [string]: any }
	local Mark = Entry(Stamped, Print)
	if type(Received) ~= "table" then
		return { [Id] = Mark }
	end

	local Floor = Stamped - Windows.PRUNE

	if not AnyOlderThan(Received, Floor) then
		local Kept: { [string]: any } = table.clone(Received)
		Kept[Id] = Mark
		return Kept
	end

	local Next = Survivors(Received, Floor)
	Next[Id] = Mark
	return Next
end

local function Prune(Received: any, Stamped: any): { [string]: any }?
	if type(Received) ~= "table" or type(Stamped) ~= "number" then
		return nil
	end

	local Kept, Dropped = Survivors(Received, Stamped - Windows.PRUNE)
	return if Dropped then Kept else nil
end

return table.freeze({
	TRANSFER = TRANSFER,
	TX = TX,
	ONCE = ONCE,
	SENT = SENT,
	GRANT = GRANT,

	UNSEEN = UNSEEN,
	SAME = SAME,
	OTHER = OTHER,

	Key = Key,
	Entry = Entry,
	At = At,
	Meant = Meant,
	Find = Find,
	Has = Has,
	Recall = Recall,
	Tagged = Tagged,

	Remember = Remember,
	Prune = Prune,
})
