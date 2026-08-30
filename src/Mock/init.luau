--!strict
--!optimize 2

--[=[

	Mock: A datastore in memory that keeps the limits of the real one.

	Key and name caps, the value size cap, kept versions, the request budget and the queues, so a
	test writes against the same refusals a live game meets. It sees bytes and identity only, never
	the record format.

	Return type: A table with New and MAX_VALUE.
	Example usage:
		local Mock = require("./Mock")
		local Fake = Mock.New({ Throttled = false })
--]=]

local Codec = require("@self/Codec")
local Service = require("@self/Service")
local Types = require("@self/Types")

export type Options = Types.Options
export type Service = Types.Service
export type Store = Types.Store
export type Pages = Types.Pages
export type KeyInfo = Types.KeyInfo

return table.freeze({
	New = Service.New,
	MAX_VALUE = Codec.MAX_VALUE,
})
