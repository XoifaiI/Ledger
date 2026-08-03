--!strict
--!optimize 2

-- the one list of stores this server built, plus the sweep that walks them. shared so neither has to require the other

local Sweeper = require("./Sweeper")
local Types = require("../Types")

type DataStore = Types.DataStore

local Stores: { DataStore } = {}

return table.freeze({
	Stores = Stores,
	Claimed = {} :: { [string]: boolean },
	Shutting = { Now = false },
	Sweep = Sweeper.New(Stores)
})
