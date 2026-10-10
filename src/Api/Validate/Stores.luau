--!strict
--!optimize 2

--[=[
	Stores: the live store objects Ledger.New made on this server, each with its Settings, so a call that names a store
	(a Tx leg) takes only a real one. Destroy marks its object destroying, which Load and Destroy refuse, then
	unregisters it, which every method refuses. The set is weak, and a look-alike table is not in it.

	Return type: A plain table with Register, SettingsOf, IsLive, CheckLive, IsDestroyingOrDestroyed,
	CheckNotDestroying, MarkDestroying and Unregister.
	Example usage:
		Stores.Register(Object, Settings)
		local Settings = Stores.SettingsOf(Leg.Store)
--]=]

local ShellSetup = require("../../Shell/Setup")

type Settings = ShellSetup.Settings

type Entry = {
	read Settings: Settings,
	IsDestroying: boolean,
}

local NotRegistered = "Stores: a store object was marked destroying while not registered. Check it first"

local Registered: { [unknown]: Entry } = {}
setmetatable(Registered, { __mode = "k" })

local function Destroyed(Name: string): string
	return `Ledger: {Name} was destroyed. Its store object takes no more calls.`
end

local function Register(Object: unknown, Settings: Settings): ()
	Registered[Object] = { Settings = Settings, IsDestroying = false }
end

local function SettingsOf(Value: unknown): Settings?
	local Entry = Registered[Value]
	if Entry == nil then
		return nil
	end
	return Entry.Settings
end

local function IsLive(Object: unknown): boolean
	return Registered[Object] ~= nil
end

local function CheckLive(Object: unknown, Name: string): ()
	if not IsLive(Object) then
		error(Destroyed(Name), 0)
	end
end

local function IsDestroyingOrDestroyed(Object: unknown): boolean
	local Entry = Registered[Object]
	return Entry == nil or Entry.IsDestroying
end

local function CheckNotDestroying(Object: unknown, Name: string): ()
	if IsDestroyingOrDestroyed(Object) then
		error(Destroyed(Name), 0)
	end
end

local function MarkDestroying(Object: unknown): ()
	local Entry = Registered[Object]
	assert(Entry ~= nil, NotRegistered)
	Entry.IsDestroying = true
end

local function Unregister(Object: unknown): ()
	Registered[Object] = nil
end

return {
	Register = Register,
	SettingsOf = SettingsOf,
	IsLive = IsLive,
	CheckLive = CheckLive,
	IsDestroyingOrDestroyed = IsDestroyingOrDestroyed,
	CheckNotDestroying = CheckNotDestroying,
	MarkDestroying = MarkDestroying,
	Unregister = Unregister,
}
