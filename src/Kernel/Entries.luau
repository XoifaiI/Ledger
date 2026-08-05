--!strict
--!optimize 2

--[=[
	Entries: The set of applied names that a key keeps in its own state.
	
	A tag goes in front of each name, so a transfer, a transaction, a Once name and a grant
	cannot collide. An entry holds the time of the write and a mark of what the name meant.
	A write drops each name that is older than the horizon. The set is therefore bounded by the
	window, and not by the age of the key.
	
	Return type: A table with the five tags, the three recalls, Key, Entry, At, Meant, Find, Has, Recall, Tagged, Remember, Prune and PRUNE_HORIZON.
	Example usage:
		local Entries = require("./Entries")
		if Entries.Has(Names, Entries.ONCE, "gift") then return end
--]=]

local Horizons = require("../Contract/Horizons")

local TRANSFER = "t:"
local TX = "x:"
local ONCE = "o:"
local SENT = "s:"
local GRANT = "g:"

local MEANT = "#"

local PRUNE_HORIZON = Horizons.PRUNE

export type Recalled = "Unseen" | "Same" | "Other"

local UNSEEN: Recalled = "Unseen"
local SAME: Recalled = "Same"
local OTHER: Recalled = "Other"

local function Key(Tag: string, Id: string): string
	assert(
		Tag == TRANSFER or Tag == TX or Tag == ONCE or Tag == SENT or Tag == GRANT,
		"an applied name has to be tagged transfer, transaction, once, sent or grant"
	)
	assert(type(Id) == "string" and #Id > 0, "an applied name cannot be empty, or two of them would share an entry")
	return `{Tag}{Id}`
end

local function Entry(At: any, Meant: string?): any
	if type(At) ~= "number" then
		return true
	end
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

	local Tagged = Received[Key(Tag, Id)]
	return if Tagged ~= nil then Tagged else Received[Id]
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

local function AnyOlderThan(Received: { [string]: any }, Floor: number): boolean
	for _, Stamp in Received do
		local When = At(Stamp)
		if When ~= nil and When < Floor then
			return true
		end
	end
	return false
end

local function Remember(Received: any, Id: string, Stamped: any, Print: string?): { [string]: any }
	local Mark = Entry(Stamped, Print)
	if type(Received) ~= "table" then
		return { [Id] = Mark }
	end

	local Floor = if type(Stamped) == "number" then Stamped - PRUNE_HORIZON else nil

	if Floor == nil or not AnyOlderThan(Received, Floor) then
		local Kept: { [string]: any } = table.clone(Received)
		Kept[Id] = Mark
		return Kept
	end

	local Next: { [string]: any } = {}
	for Name, Stamp in Received do
		local When = At(Stamp)
		if When == nil or When >= (Floor :: number) then
			Next[Name] = Stamp
		end
	end
	Next[Id] = Mark
	return Next
end

local function Prune(Received: any, Stamped: any): { [string]: any }?
	if type(Received) ~= "table" or type(Stamped) ~= "number" then
		return nil
	end

	local Floor = Stamped - PRUNE_HORIZON
	local Kept: { [string]: any } = {}
	local Dropped = false
	for Name, Stamp in Received do
		local When = At(Stamp)
		if When == nil or When >= Floor then
			Kept[Name] = Stamp
		else
			Dropped = true
		end
	end

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
	PRUNE_HORIZON = PRUNE_HORIZON
})
