--!strict
--!optimize 2

--[=[
	KindSetup: the Setup a key of each kind is judged by (extras sheet E1, hot keys sheet H1). A shard is judged by
	the shared shard build, a part by the store's PartBuild, over the store's limits and encoding; each states its
	own IsErasable and CreatesOnFirstWrite. A game key is judged by its store's Setup. IsErasableKey is the one test
	of whether a key can be erased, so has incarnations told apart by an identity; a key that cannot has one for ever.

	Return type: A plain table with SetupFor, SetupOfKey and IsErasableKey.
	Example usage:
		local Setup = KindSetup.SetupOfKey(Server, Key)
--]=]

local Cache = require("../Reading/Cache")
local Names = require("../Encoding/Names")
local Record = require("../Constants/Record")
local Shapes = require("../Shapes")
local Shard = require("../Extras/Totals/Shard")

type Build = Shapes.Build
type ServerState = Shapes.ServerState
type Setup = Shapes.Setup
type StoreKey = Names.StoreKey
type KeyKind = Shapes.KeyKind

local KeyKinds = Record.KeyKind

local ShardBuild = Shard.NewBuild()

local function WithBuild(Setup: Setup, Build: Build, CreatesOnFirstWrite: boolean): Setup
	return {
		Store = Setup.Store,
		Build = Build,
		Limits = Setup.Limits,
		Encoding = Setup.Encoding,
		IsErasable = false,
		CreatesOnFirstWrite = CreatesOnFirstWrite,
		PartBuild = Setup.PartBuild,
	}
end

local function SetupFor(Setup: Setup, Kind: KeyKind): Setup
	if Kind == KeyKinds.Shard then
		return WithBuild(Setup, ShardBuild, true)
	end
	if Kind == KeyKinds.Part then
		return WithBuild(Setup, Setup.PartBuild, false)
	end
	return Setup
end

local function SetupOfKey(Server: ServerState, Key: StoreKey): Setup
	return SetupFor(Cache.StoreOf(Server, Key).Setup, Cache.KindOfKey(Key))
end

local function IsErasableKey(Setup: Setup, Key: StoreKey): boolean
	return SetupFor(Setup, Cache.KindOfKey(Key)).IsErasable
end

return {
	SetupFor = SetupFor,
	SetupOfKey = SetupOfKey,
	IsErasableKey = IsErasableKey,
}
