--!strict
--!optimize 2

--[=[

	Effect: The requests a machine sends, as data, and the reply each one gets.

	A machine never calls a datastore or waits. It sends an effect, and the driver makes the call and
	steps the machine with the reply. Get reads a key, Update runs a transform on one, and Wait passes
	time. An update names the user ids a key it makes is given. Each replies as its DataStore call
	answers: Ok, Value and Info, and for an update Wrote after them. A wait replies true.

	Return type: A table with Kind, Get, Update and Wait. The types are Effect, and Call and Spec for
	a machine that sends effects.
	Example usage:
		local Effect = require("./Effect")
		Machine.Send(Call, Effect.Update(Store, Key, Transform))
		local Waits = Sent.Kind == Effect.Kind.Wait
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

local Kind: {
	read Get: "Get",
	read Update: "Update",
	read Wait: "Wait",
} = {
	Get = "Get",
	Update = "Update",
	Wait = "Wait",
}

local function Get(Store: Store, Key: string, Options: DataStoreGetOptions?): Effect
	return { Kind = Kind.Get, Store = Store, Key = Key, Options = Options }
end

local function Update(Store: Store, Key: string, Transform: DataStore.Transform, UserIds: { number }?): Effect
	return { Kind = Kind.Update, Store = Store, Key = Key, Transform = Transform, UserIds = UserIds }
end

local function Wait(Seconds: number): Effect
	return { Kind = Kind.Wait, Seconds = Seconds }
end

return table.freeze({
	Kind = table.freeze(Kind),
	Get = Get,
	Update = Update,
	Wait = Wait,
})
