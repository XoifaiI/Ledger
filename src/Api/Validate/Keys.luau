--!strict
--!optimize 2

--[=[
	Keys: the store's key mode applied to a call's key or player (A11). A player store's key is a Player or a whole
	UserId, stored as decimal text; an entity store's is 1 to KeyBytesMost bytes of UTF-8 outside Ledger's total and
	quantity prefixes. GameKeyOf reads a key back as the game gave it, ListedKeyOf a listed name, or nil.

	Return type: A plain table with Key, GameKeyOf, ListedKeyOf, PlayerStoreOnly and Player.
	Example usage:
		local Key = Keys.Key(Settings, Player, "Store:Edit")
--]=]

local Check = require("../../Encoding/Check")
local Names = require("../../Encoding/Names")
local Record = require("../../Constants/Record")
local Rules = require("./Rules")
local ShellSetup = require("../../Shell/Setup")

type KeysMode = ShellSetup.KeysMode
type Settings = ShellSetup.Settings
type StoreKey = Names.StoreKey

local KeysModes = ShellSetup.KeysMode
local ReservedPrefixes = { Record.ShardKeyPrefix, Record.PartKeyPrefix }

local UserIdMost = Record.VarintLimit - 1
local WholeText = "%d"

local CheckAccepted = "Keys: a Check rule accepted a value of another type. The rule must reject it"
local NotAUserId = "Keys: a player store's key is not a UserId's text. Keys.Key writes only whole numbers"
local PlayerStoreWanted = `"{KeysModes.Player}", since sessions are for player stores only`
local PlayerWanted = "a Player"
local UserIdWanted = `a Player, or a UserId: a whole number from -{UserIdMost} to {UserIdMost}`
local EntityKeyWanted = `a string of 1 to {Record.KeyBytesMost} bytes of valid UTF-8 that does not start with `
	.. `"{Record.ShardKeyPrefix}" or "{Record.PartKeyPrefix}", which Ledger keeps for totals and quantities`

local UserIdRule = Check.Whole(-UserIdMost, UserIdMost)
local EntityKeyText = Check.Text(1, Record.KeyBytesMost)
local IsPlayerStore = Rules.Equals(KeysModes.Player, PlayerStoreWanted)

local function IsPlayer(Value: unknown): boolean
	return typeof(Value) == "Instance" and Value:IsA("Player")
end

local function PlayerRule(Value: unknown): string?
	if IsPlayer(Value) then
		return nil
	end
	return PlayerWanted
end

local function PlayerKey(Value: unknown): string?
	if IsPlayer(Value) or UserIdRule(Value) == nil then
		return nil
	end
	return UserIdWanted
end

local function HasReservedPrefix(Text: string): boolean
	for _, Prefix in ReservedPrefixes do
		if string.sub(Text, 1, #Prefix) == Prefix then
			return true
		end
	end
	return false
end

local function EntityKey(Value: unknown): string?
	if EntityKeyText(Value) ~= nil or type(Value) ~= "string" or HasReservedPrefix(Value) then
		return EntityKeyWanted
	end
	return nil
end

local function StoreKeyOf(Settings: Settings, Text: string): StoreKey
	return { Store = Settings.Name, Scope = ShellSetup.StoreScope, Key = Text }
end

local function UserIdText(Value: unknown): string
	if typeof(Value) == "Instance" and Value:IsA("Player") then
		return string.format(WholeText, Value.UserId)
	end
	assert(type(Value) == "number", CheckAccepted)
	return string.format(WholeText, Value)
end

local function Key(Settings: Settings, Value: unknown, Where: string): StoreKey
	if Settings.Keys == KeysModes.Player then
		Check.Table({ Key = Value }, { Key = PlayerKey }, Where)
		return StoreKeyOf(Settings, UserIdText(Value))
	end
	Check.Table({ Key = Value }, { Key = EntityKey }, Where)
	assert(type(Value) == "string", CheckAccepted)
	return StoreKeyOf(Settings, Value)
end

local function GameKeyOf(Mode: KeysMode, Key: StoreKey): string | number
	if Mode ~= KeysModes.Player then
		return Key.Key
	end
	local UserId = tonumber(Key.Key)
	if UserId == nil then
		error(NotAUserId, 0)
	end
	return UserId
end

local function UserIdOfText(Text: string): number?
	local UserId = tonumber(Text)
	if UserId == nil or UserIdRule(UserId) ~= nil or string.format(WholeText, UserId) ~= Text then
		return nil
	end
	return UserId
end

local function ListedKeyOf(Mode: KeysMode, Name: string): (string | number)?
	if Mode == KeysModes.Player then
		return UserIdOfText(Name)
	end
	if EntityKey(Name) ~= nil then
		return nil
	end
	return Name
end

local function PlayerStoreOnly(Settings: Settings, Where: string): ()
	Check.Table({ Keys = Settings.Keys }, { Keys = IsPlayerStore }, Where)
end

local function Player(Settings: Settings, Value: unknown, Where: string): Player
	PlayerStoreOnly(Settings, Where)
	Check.Table({ Player = Value }, { Player = PlayerRule }, Where)
	assert(typeof(Value) == "Instance" and Value:IsA("Player"), CheckAccepted)
	return Value
end

return {
	Key = Key,
	GameKeyOf = GameKeyOf,
	ListedKeyOf = ListedKeyOf,
	PlayerStoreOnly = PlayerStoreOnly,
	Player = Player,
}
