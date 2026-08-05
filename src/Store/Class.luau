--!strict
--!optimize 2

--[=[
	Class: The method table that every half of the store writes its methods onto.

	The store is too large for one file, and the halves cannot each hold their own class table. So the
	table lives here on its own, and Core, Write, Read, Admin and Ops each write onto it directly.
	Nothing has to be copied across afterwards, and a method is declared where it is written.
	Store.luau requires all of them before it freezes this, which is what makes the table complete.

	Return type: The method table, with __index already pointing at itself.
	Example usage:
		local Store = require("./Class")
		function Store.Peek(self: Store, Key: KeyLike) end
--]=]

local Types = require("./Types")

local Store = {} :: Types.StoreImpl
Store.__index = Store

return Store
