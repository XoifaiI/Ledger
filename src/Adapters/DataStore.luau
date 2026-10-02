--!strict
--!optimize 2

--[=[
	DataStore: Plumbing. One datastore call, answered as pcall answers.

	Nothing here retries; Machine/Runner does. Update answers, last, whether any run of the transform
	gave a value to write, which is true even when the call then failed. Every write keeps the key's
	user ids and metadata, and a write that makes a key gives it the user ids passed in.

	Return type: A table of the calls, and the Transform and Store types.
	Example usage:
		local Ok, Value, Info, Wrote = DataStore.Update(Store, "42", Transform, { UserId })
--]=]

local DataStoreService = game:GetService("DataStoreService")

export type Transform = (Current: unknown, Info: DataStoreKeyInfo?) -> unknown

type Run = (Current: unknown, Info: DataStoreKeyInfo?) -> (unknown, { number }?, ...{ [string]: any })

export type Store = {
	GetAsync: (self: any, Key: string, Options: DataStoreGetOptions?) -> (unknown, DataStoreKeyInfo?),
	UpdateAsync: (self: any, Key: string, Transform: Run) -> (unknown, DataStoreKeyInfo?),
	RemoveAsync: (self: any, Key: string) -> (unknown, DataStoreKeyInfo?),
}

local DataStore = {}

function DataStore.Open(Name: string): Store
	return DataStoreService:GetDataStore(Name)
end

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
