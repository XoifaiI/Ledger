--!strict
--!optimize 2

--[=[

	Effect: A request a machine sends, as data, for the driver to carry out.

	Get reads a key, Update runs a transform on one, and Wait passes time. The reply is what the
	DataStore call answers: Ok, Value and Info, then Wrote for an update. A wait replies true.

	Return type: A table with Kind, Get, Update and Wait. The types are Effect, and Call, Spec and
	State for a machine that sends effects, whose answer is typed unknown for its caller to read.
	Example usage:
		Machine.Send(Call, Effect.Update(Store, Key, Transform))
--]=]

local DataStore = require("../Adapters/DataStore")
local Machine = require("../Core/Machine")

type Store = DataStore.Store

export type Effect =
	{
		read Kind: "Get",
		read Store: Store,
		read Key: string,
		read Options: DataStoreGetOptions?,
	}
	| {
		read Kind: "Update",
		read Store: Store,
		read Key: string,
		read Transform: DataStore.Transform,
		read UserIds: { number }?,
	}
	| {
		read Kind: "Wait",
		read Seconds: number,
	}

export type Call<Context, Answer> = Machine.Call<Context, Effect, Answer, (boolean, unknown, DataStoreKeyInfo?, boolean?)>
export type Spec<Context, Answer> = Machine.Spec<Context, Effect, Answer, (boolean, unknown, DataStoreKeyInfo?, boolean?)>
export type State<Context, Answer> = Machine.State<Context, Effect, Answer, (boolean, unknown, DataStoreKeyInfo?, boolean?)>

local Kind: {
	read Get: "Get",
	read Update: "Update",
	read Wait: "Wait",
} = {
	Get = "Get",
	Update = "Update",
	Wait = "Wait",
}

local Effect = { Kind = Kind }

function Effect.Get(Store: Store, Key: string, Options: DataStoreGetOptions?): Effect
	return { Kind = Kind.Get, Store = Store, Key = Key, Options = Options }
end

function Effect.Update(Store: Store, Key: string, Transform: DataStore.Transform, UserIds: { number }?): Effect
	return { Kind = Kind.Update, Store = Store, Key = Key, Transform = Transform, UserIds = UserIds }
end

function Effect.Wait(Seconds: number): Effect
	return { Kind = Kind.Wait, Seconds = Seconds }
end

return Effect
