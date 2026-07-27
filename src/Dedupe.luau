--!strict
--!optimize 2

-- the applied id set a key keeps in its own state, transfers and transactions namespaced apart so the same name cant collide

local TRANSFER = "t:"
local TX = "x:"

local function Key(Tag: string, Id: string): string
	return `{Tag}{Id}`
end

local function Has(Received: any, Tag: string, Id: string): boolean
	if type(Received) ~= "table" then
		return false
	end
	return Received[Key(Tag, Id)] ~= nil or Received[Id] ~= nil
end

return table.freeze({
	TRANSFER = TRANSFER,
	TX = TX,
	Key = Key,
	Has = Has
})
