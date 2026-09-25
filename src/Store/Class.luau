--!strict
--!optimize 2

--[=[

	Class: The method table for the store.

	Shared and every file under Api write their methods onto it, and Store.luau freezes it once all
	of them have been required.

	Return type: The method table. __index points at itself.
	Example usage:
		local Store = require("./Class")
		function Store.Peek(self: Store, Key: KeyLike) end
--]=]

local Types = require("./Types")

local Store = {} :: Types.StoreImpl<any>
Store.__index = Store

return Store
