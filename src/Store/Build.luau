--!strict
--!optimize 2

--[=[

	Build: Logic. Turns a store's config into the build every write of this server judges with.

	Spec: record 5.1 and 7.

	The fields a build declares are the keys of Default. A migration is a function, which breaks old
	servers, or { Apply, Compatible }, which does not when Compatible is true. The level is the
	number of migrations and the floor the index of the last one that breaks. A config that cannot
	work throws at the game's own call. Windows gives an op kind how long its names are kept.
	OnLoadFailed is called with a player whose load failed, and a player it does not handle is kicked.

	Return type: A table with New. The types are Config and Migration.
	Example usage:
		local Made = Build.New(Config)
--]=]

local Answer = require("../Core/Answer")
local DataStore = require("../Adapters/DataStore")
local Errors = require("../Core/Errors")
local Ops = require("../Store/Ops")
local Sizes = require("../Core/Constants/Sizes")
local Types = require("../Record/Types")
local Value = require("../Encode/Value")
local Windows = require("../Core/Constants/Windows")

export type Migration = ((State: any) -> unknown) | { read Apply: (State: any) -> unknown, read Compatible: boolean? }

export type Config = {
	read Name: string,
	read Default: { [string]: any },
	read Reducer: (State: any, Op: any) -> unknown,
	read Migrations: { Migration }?,
	read Money: { string }?,
	read Windows: { [string]: number }?,
	read MustExist: boolean?,
	read DataStore: DataStore.Store?,
	read OnLoadFailed: ((Player: Player, Why: Answer.Answer) -> boolean)?,
}

local Build = {}

local function Steps(Migrations: { Migration }): ({ (State: any) -> unknown }, number)
	local Made: { (State: any) -> unknown } = {}
	local Floor = 0
	for Index, Migration in Migrations do
		if type(Migration) == "function" then
			Made[Index], Floor = Migration, Index
		elseif type(Migration) == "table" and type(Migration.Apply) == "function" then
			Made[Index] = Migration.Apply
			Floor = if Migration.Compatible then Floor else Index
		else
			Errors.Misuse(`migration {Index} is not a function or a table with Apply`, 2)
		end
	end
	return Made, Floor
end

function Build.New(Config: Config): Types.Build
	if type(Config.Name) ~= "string" or Config.Name == "" then
		Errors.Misuse("a store needs a Name", 1)
	elseif type(Config.Default) ~= "table" or Value.Check(Config.Default) == nil then
		Errors.Misuse(`the Default of {Config.Name} is not a table a datastore can hold`, 1)
	elseif type(Config.Reducer) ~= "function" then
		Errors.Misuse(`the Reducer of {Config.Name} is not a function`, 1)
	elseif Config.OnLoadFailed ~= nil and type(Config.OnLoadFailed) ~= "function" then
		Errors.Misuse(`the OnLoadFailed of {Config.Name} is not a function`, 1)
	end
	local Fields: { [string]: true } = {}
	for Field in Config.Default do
		Fields[Field] = true
	end
	for _, Field in Config.Money or {} do
		if type(Config.Default[Field]) ~= "number" then
			Errors.Misuse(`the money field {Field} of {Config.Name} is not a number in Default`, 1)
		end
	end
	local Window: { [number]: number } = {}
	for Kind, Seconds in Config.Windows or {} do
		if not (type(Seconds) == "number" and Seconds >= Windows.MINTED and Seconds <= Windows.CEILING) then
			Errors.Misuse(`the window of {Kind} in {Config.Name} is not from {Windows.MINTED} to {Windows.CEILING} seconds`, 1)
		end
		local Index = Ops.Kind(Kind)
		Window[Index] = math.max(Window[Index] or 0, Seconds)
	end
	local Migrations, Floor = Steps(Config.Migrations or {})
	return {
		Reducer = Config.Reducer,
		Migrations = Migrations,
		Default = Config.Default,
		Level = #Migrations,
		Floor = Floor,
		Money = Config.Money or {},
		Fields = Fields,
		Window = Window,
		Minted = Windows.MINTED,
		CutWindow = Windows.CUT,
		TimedRoom = Sizes.TIMED_ROOM,
		UntimedRoom = Sizes.UNTIMED_ROOM,
		WorkRoom = Sizes.WORK_ROOM,
		CutNames = Sizes.CUT_NAMES,
		StateCap = Sizes.STATE_CAP,
		Ahead = Windows.AHEAD,
		Hold = Windows.HOLD,
	}
end

return Build
