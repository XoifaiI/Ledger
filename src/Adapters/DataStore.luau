--!strict
--!optimize 2

--[=[

	DataStore: Makes one datastore call and says what came of it.

	Each function answers as pcall does: true and the value, or false and the error. Nothing here
	retries or queues. A caller that wants another try sends another request, so each try is one call
	with its own transform. Get passes its options on, so a read with UseCache off skips the few
	seconds a server keeps a key it read. Update also answers whether a run of the transform gave a value to write,
	since an update that failed after it wrote may have landed. A remove may have landed whenever it
	was sent.

	Return type: A table with Get, Update and Remove.
	Example usage:
		local DataStore = require("./DataStore")
		local Ok, Value, Wrote = DataStore.Update(Store, "42", Transform)
--]=]

export type Transform = (Current: unknown, Info: DataStoreKeyInfo?) -> (unknown, { number }?, { [string]: any }?)

export type Store = {
	GetAsync: (self: any, Key: string, Options: DataStoreGetOptions?) -> (unknown, DataStoreKeyInfo?),
	UpdateAsync: (self: any, Key: string, Transform: Transform) -> (unknown, DataStoreKeyInfo?),
	RemoveAsync: (self: any, Key: string) -> (unknown, DataStoreKeyInfo?),
}

local function Get(Store: Store, Key: string, Options: DataStoreGetOptions?): (boolean, unknown, DataStoreKeyInfo?)
	return pcall(Store.GetAsync, Store, Key, Options)
end

local function Update(Store: Store, Key: string, Transform: Transform): (boolean, unknown, boolean, DataStoreKeyInfo?)
	local Wrote = false
	local function Run(Current: unknown, Info: DataStoreKeyInfo?): (unknown, { number }?, { [string]: any }?)
		local Next, UserIds, Metadata = Transform(Current, Info)
		if Next ~= nil then
			Wrote = true
		end
		return Next, UserIds, Metadata
	end
	local Ok, Value, Info = pcall(Store.UpdateAsync, Store, Key, Run)
	return Ok, Value, Wrote, Info
end

local function Remove(Store: Store, Key: string): (boolean, unknown, DataStoreKeyInfo?)
	return pcall(Store.RemoveAsync, Store, Key)
end

return table.freeze({
	Get = Get,
	Update = Update,
	Remove = Remove,
})
