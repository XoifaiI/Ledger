--!strict
--!optimize 2

--[=[
	Class: The method table for the store.

	Core, Write, Read, Admin and Ops write their methods onto it. Store.luau requires those five, so
	the table must be in a file of its own. Store.luau freezes the table last.

	Return type: The method table. __index points at itself.
	Example usage:
		local Store = require("./Class")
		function Store.Peek(self: Store, Key: KeyLike) end
--]=]

local Types = require("./Types")

local Store = {} :: Types.StoreImpl<any>
Store.__index = Store

return Store
