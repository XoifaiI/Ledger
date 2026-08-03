--!strict
--!optimize 2

-- the applied id set a key keeps in its own state, namespaced so a transfer, a transaction and a Once name cant collide. an entry holds when the name was applied and what it meant, so an honest retry reads differently from the same name reused for something else

local TRANSFER = "t:"
local TX = "x:"
local ONCE = "o:"
local SENT = "s:"

local MEANT = "#"

export type Recalled = "Unseen" | "Same" | "Other"

local UNSEEN: Recalled = "Unseen"
local SAME: Recalled = "Same"
local OTHER: Recalled = "Other"

local function Key(Tag: string, Id: string): string
	assert(
		Tag == TRANSFER or Tag == TX or Tag == ONCE or Tag == SENT,
		"an applied name has to be tagged transfer, transaction, once or sent"
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

return table.freeze({
	TRANSFER = TRANSFER,
	TX = TX,
	ONCE = ONCE,
	SENT = SENT,

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
	Tagged = Tagged
})
