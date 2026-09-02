--!strict
--!optimize 2

--[=[

	Mock: A datastore and a MemoryStore in memory that keep the limits of the real ones.

	Key and name caps, the value size caps, kept versions, expiry, the request budget, the queues
	and the request units, so a test writes against the same refusals a live game meets. It sees
	bytes and identity only, never the record format.

	Return type: A table with New and MAX_VALUE.
	Example usage:
		local Mock = require("./Mock")
		local Fake = Mock.New({ Throttled = false })
--]=]

local Json = require("@self/Json")
local Service = require("@self/Service")
local Types = require("@self/Types")

export type Options = Types.Options
export type Service = Types.Service
export type Store = Types.Store
export type HashMap = Types.HashMap
export type Pages = Types.Pages
export type KeyInfo = Types.KeyInfo

return table.freeze({
	New = Service.New,
	MAX_VALUE = Json.MAX_VALUE,
})
