--!strict
--!optimize 2

--[=[
	Lib: The only place that the sweep reaches into src.

	It stays small on purpose. A sweep that needs a private function tests something a game cannot do.
	The cases reach through Suite/Insides instead, which is a wider door for a different job.

	Return type: A table of the library parts the sweep names.
	Example usage:
		local Store = Lib.Ledger.New(Options)
--]=]

local Ledger = require("../src")
local Mock = require("../src/Mock")
local Session = require("../src/Live/Session")
local DataStoreWrapper = require("../src/Util/DataStoreWrapper")
local Registry = require("../src/Store/Registry")
local Horizons = require("../src/Contract/Horizons")
local Reasons = require("../src/Contract/Reason")

local Entries = require("../src/Kernel/Entries")
local Ident = require("../src/Encode/Ident")
local Mark = require("../src/Encode/Mark")
local Shape = require("../src/Record/Shape")
local Stamp = require("../src/Record/Stamp")
local LogTypes = require("../src/Record/Types")

export type Reason = Reasons.Reason
export type Shape<S> = LogTypes.Shape<S>

return table.freeze({
	Ledger = Ledger :: any,
	Mock = Mock,
	Wrapper = DataStoreWrapper,
	Reasons = Reasons,
	Horizons = Horizons,

	OpenSession = Session.Load,
	MAX_PENDING = Session.MAX_PENDING,

	Sweep = Registry.Sweep,
	Stores = Registry.Stores,
	Shutting = Registry.Shutting,

	Entries = Entries,
	Mark = Mark,
	Ident = Ident,
	Shape = Shape,
	Stamp = Stamp
})
