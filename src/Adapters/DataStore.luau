--!strict
--!optimize 2

--[=[

	DataStore: One datastore call, answered as pcall answers.

	Nothing retries. Update also answers, last, whether a run gave a value to write. Every write keeps
	the key's user ids and metadata, and a write that makes a key gives it the user ids passed in.

	Return type: A table with Get, Update and Remove. The types are Transform and Store.
	Example usage:
		local Ok, Value, Info, Wrote = DataStore.Update(Store, "42", Transform, { UserId })
--]=]

export type Transform = (Current: unknown, Info: DataStoreKeyInfo?) -> unknown

type Run = (Current: unknown, Info: DataStoreKeyInfo?) -> (unknown, { number }?, ...{ [string]: any })

export type Store = {
	GetAsync: (self: any, Key: string, Options: DataStoreGetOptions?) -> (unknown, DataStoreKeyInfo?),
	UpdateAsync: (self: any, Key: string, Transform: Run) -> (unknown, DataStoreKeyInfo?),
	RemoveAsync: (self: any, Key: string) -> (unknown, DataStoreKeyInfo?),
}

local DataStore = {}

function DataStore.Get(Store: Store, Key: string, Options: DataStoreGetOptions?): (boolean, unknown, DataStoreKeyInfo?)
	return pcall(Store.GetAsync, Store, Key, Options)
end

function DataStore.Update(Store: Store, Key: string, Transform: Transform, UserIds: { number }?): (boolean, unknown, DataStoreKeyInfo?, boolean)
	local Wrote = false
	local function Run(Current: unknown, Info: DataStoreKeyInfo?): (unknown, { number }?, ...{ [string]: any })
		local Next = Transform(Current, Info)
		Wrote = Wrote or Next ~= nil
		if Info then
			return Next, Info:GetUserIds(), Info:GetMetadata()
		end
		return Next, UserIds
	end
	local Ok, Value, Info = pcall(Store.UpdateAsync, Store, Key, Run)
	return Ok, Value, Info, Wrote
end

function DataStore.Remove(Store: Store, Key: string): (boolean, unknown, DataStoreKeyInfo?)
	return pcall(Store.RemoveAsync, Store, Key)
end

return DataStore
