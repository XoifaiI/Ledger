--!strict
--!optimize 2

-- the applied id set a key keeps in its own state, namespaced so a transfer, a transaction and a Once name cant collide

local TRANSFER = "t:"
local TX = "x:"
local ONCE = "o:"

local function Key(Tag: string, Id: string): string
	return `{Tag}{Id}`
end

local function Has(Received: any, Tag: string, Id: string): boolean
	if type(Received) ~= "table" then
		return false
	end
	return Received[Key(Tag, Id)] ~= nil or Received[Id] ~= nil
end

local function Tagged(Id: any, Tag: string): boolean
	return type(Id) == "string" and string.sub(Id, 1, #Tag) == Tag
end

return table.freeze({
	TRANSFER = TRANSFER,
	TX = TX,
	ONCE = ONCE,
	Key = Key,
	Has = Has,
	Tagged = Tagged
})
