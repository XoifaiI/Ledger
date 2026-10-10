--!strict
--!optimize 2

--[=[
	Unreachable: the warning for a key whose work names a decider, or a pinned record a leg, in a store this server
	never opened. Only a server with that store open ends the work. It warns once for each pair of the key's store and
	the other store.

	Return type: A plain table with WarnOnce.
	Example usage:
		Unreachable.WarnOnce(State, Key, Entry.Work, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Composed = require("../../Composed")
local Events = require("../../Events")
local GetOrMake = require("../../GetOrMake").GetOrMake
local Names = require("../../Encoding/Names")
local Work = require("../../Stored/Items/Work")

type Command = Events.Command
type Mark = Work.Mark
type StoreKey = Names.StoreKey
type State = Composed.State

local function Advice(Store: string, Other: string): string
	return `the work on this key names a key of the store {Other}, which this server never opened. Only a server with `
		.. `{Other} open ends the work, so it waits until one touches this key. Open {Other} with Ledger.New on every `
		.. `server that touches {Store}. Ledger warns of this once for the stores {Store} and {Other}.`
end

local function NewWarnedSet(): { [string]: true }
	return {}
end

local function NamedKeys(Key: StoreKey, Item: Mark): { StoreKey }
	local Named: { StoreKey } = {}
	if Item.Kind == "Pinned" then
		for _, Reference in Item.OtherLegs do
			table.insert(Named, Names.KeyOfReference(Key, Reference))
		end
		return Named
	end
	table.insert(Named, Names.KeyOfReference(Key, Item.Decider))
	return Named
end

local function WarnOnce(State: State, Key: StoreKey, Listed: { Mark }, Commands: { Command })
	local Warned = GetOrMake(State.Tx.UnreachableWarned, Key.Store, NewWarnedSet)
	for _, Item in Listed do
		for _, Other in NamedKeys(Key, Item) do
			if Cache.FindStore(State.Server, Other) == nil and Warned[Other.Store] == nil then
				Warned[Other.Store] = true
				local Warn: Command = { Kind = "Warn", Key = Key, Text = Advice(Key.Store, Other.Store) }
				table.insert(Commands, Warn)
			end
		end
	end
end

return {
	WarnOnce = WarnOnce,
}
