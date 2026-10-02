--!strict
--!optimize 2

--[=[

	Build: Logic. Turns a store's config into the build every write of this server judges with.

	Spec: record 5.1 and 7.

	The fields a build declares are the keys of Default. A migration is a function, which breaks old
	servers, or { Apply, Compatible }, which does not when Compatible is true. The level is the
	number of migrations and the floor the index of the last one that breaks. A config that cannot
	work throws at the game's own call. Windows gives an op kind how long its names are kept. A
	store is Erasable when its keys carry an incarnation id, by default when its keys must exist. A
	game may set each room within its bounds, and every room together within Limits.ROOMS_MAX. It
	may set KeepNamed from 7 to 30 days. LegLimit is the most legs a transaction on the store may
	have. A loss room must hold two fold slots and one event of every money field, and a store
	declares at most Limits.MONEY_MAX money fields. OnLoadFailed is called with a player whose load
	failed, and a player it does not handle is kicked. Totals gives the shard count of each total a
	config declares, from 1 to Limits.SHARDS_MAX. A total with no count gets Limits.SHARDS. A
	total's name has at most Limits.TOTAL_NAME bytes. Splits gives the declaration of each split
	quantity a config declares: from 1 to Limits.SPLIT_MAX parts, Final or Open, with a whole stock.
	A quantity's name has at most Limits.SPLIT_NAME bytes, and its print covers the whole
	declaration. Serials gives a final quantity serial numbers from that first one, one per unit of
	its stock. Proceeds names at most Limits.PROCEEDS_MAX money fields its takes pay into.

	Return type: A table with New, Totals and Splits. The types are Config and Migration.
	Example usage:
		local Made = Build.New(Config)
--]=]

local Answer = require("../Core/Answer")
local Book = require("../Record/Book")
local DataStore = require("../Adapters/DataStore")
local Errors = require("../Core/Errors")
local Limits = require("../Core/Constants/Limits")
local Ops = require("../Store/Ops")
local Parts = require("../Record/Parts")
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
	read Erasable: boolean?,
	read TimedRoom: number?,
	read UntimedRoom: number?,
	read WorkRoom: number?,
	read LossRoom: number?,
	read CutNames: number?,
	read KeepNamed: number?,
	read LegLimit: number?,
	read Totals: { [string]: { read Shards: number? } }?,
	read Splits: { [string]: { read Parts: number, read Mode: Parts.Mode?, read Stock: number?, read Serials: number?, read Proceeds: { string }? } }?,
	read DataStore: DataStore.Store?,
	read OnLoadFailed: ((Player: Player, Why: Answer.Answer) -> boolean)?,
}

local Build = {}

local function Whole(Value: unknown, Least: number, Most: number): boolean
	return type(Value) == "number" and Value % 1 == 0 and Value >= Least and Value <= Most
end

local function Setting(Config: Config, Field: string, Default: number, Least: number, Most: number): number
	local Given = (Config :: any)[Field]
	if Given == nil then
		return Default
	elseif not Whole(Given, Least, Most) then
		Errors.Misuse(`the {Field} of {Config.Name} is not a whole number from {Least} to {Most}`, 2)
	end
	return Given
end

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

function Build.Totals(Config: Config): { [string]: number }
	local Found: { [string]: number } = {}
	local Declared = Config.Totals
	if Declared == nil then
		return Found
	elseif type(Declared) ~= "table" then
		Errors.Misuse(`the Totals of {Config.Name} is not a table of totals by name`, 1)
	end
	for Name, Total in Declared do
		local Shards = if type(Total) == "table" then Total.Shards or Limits.SHARDS else nil
		if type(Name) ~= "string" or Name == "" or #Name > Limits.TOTAL_NAME then
			Errors.Misuse(`a total of {Config.Name} needs a name of 1 to {Limits.TOTAL_NAME} bytes`, 1)
		elseif not (type(Shards) == "number" and Shards % 1 == 0 and Shards >= 1 and Shards <= Limits.SHARDS_MAX) then
			Errors.Misuse(`the total {Name} of {Config.Name} needs Shards, a whole number from 1 to {Limits.SHARDS_MAX}`, 1)
		end
		Found[Name] = Shards
	end
	return Found
end

function Build.Splits(Config: Config): { [string]: Parts.Declared }
	local Found: { [string]: Parts.Declared } = {}
	local Declared = Config.Splits
	if Declared == nil then
		return Found
	elseif type(Declared) ~= "table" then
		Errors.Misuse(`the Splits of {Config.Name} is not a table of quantities by name`, 1)
	end
	for Name, Split in Declared do
		local Given: any = if type(Split) == "table" then Split else {}
		local Mode, Stock = Given.Mode or Parts.MODE.Final, Given.Stock or 0
		if type(Name) ~= "string" or Name == "" or #Name > Limits.SPLIT_NAME then
			Errors.Misuse(`a split quantity of {Config.Name} needs a name of 1 to {Limits.SPLIT_NAME} bytes`, 1)
		elseif not Whole(Given.Parts, 1, Limits.SPLIT_MAX) then
			Errors.Misuse(`the quantity {Name} of {Config.Name} needs Parts, a whole number from 1 to {Limits.SPLIT_MAX}`, 1)
		elseif Mode ~= Parts.MODE.Final and Mode ~= Parts.MODE.Open then
			Errors.Misuse(`the Mode of the quantity {Name} of {Config.Name} is not Final or Open`, 1)
		elseif not Whole(Stock, 0, Limits.MONEY_LIMIT - 1) then
			Errors.Misuse(`the Stock of the quantity {Name} of {Config.Name} is not a whole number of 0 or more`, 1)
		elseif Given.Serials ~= nil and (Mode ~= Parts.MODE.Final or not Whole(Given.Serials, 0, Limits.MONEY_LIMIT - 1 - Stock)) then
			Errors.Misuse(`the Serials of the quantity {Name} of {Config.Name} is not the whole first serial of a final quantity`, 1)
		end
		local Proceeds: { string } = Given.Proceeds or {}
		if type(Proceeds) ~= "table" or #Proceeds > Limits.PROCEEDS_MAX then
			Errors.Misuse(`the Proceeds of the quantity {Name} of {Config.Name} is not a list of at most {Limits.PROCEEDS_MAX} names`, 1)
		end
		for _, Field in Proceeds do
			if type(Field) ~= "string" or Parts.FIELDS[Field] then
				Errors.Misuse(`the proceeds field {Field} of the quantity {Name} of {Config.Name} is not a free name`, 1)
			end
		end
		local First = Given.Serials
		local Print = Ops.Print({ Name = Name, Parts = Given.Parts, Mode = Mode, Stock = Stock, First = First, Proceeds = Proceeds })
		local Place = `{Config.Name}{Parts.PREFIX}{Name}:{Given.Parts}`
		Found[Name] = { Name = Name, Parts = Given.Parts, Mode = Mode, Stock = Stock, First = First, Proceeds = Proceeds, Print = Print, Place = Place }
	end
	return Found
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
	elseif Config.Erasable ~= nil and type(Config.Erasable) ~= "boolean" then
		Errors.Misuse(`the Erasable of {Config.Name} is not true or false`, 1)
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
	local Money = Config.Money or {}
	if #Money > Limits.MONEY_MAX then
		Errors.Misuse(`{Config.Name} declares more than {Limits.MONEY_MAX} money fields`, 1)
	end
	local LossFloor = Book.LossFloor(#Money)
	local Rooms = {
		Timed = Setting(Config, "TimedRoom", Sizes.TIMED_ROOM, Sizes.TIMED_ROOM_MIN, Sizes.TIMED_ROOM_MAX),
		Untimed = Setting(Config, "UntimedRoom", Sizes.UNTIMED_ROOM, Sizes.UNTIMED_ROOM_MIN, Sizes.UNTIMED_ROOM_MAX),
		Work = Setting(Config, "WorkRoom", Sizes.WORK_ROOM, Sizes.WORK_ROOM_MIN, Sizes.WORK_ROOM_MAX),
		Loss = Setting(Config, "LossRoom", math.max(Sizes.LOSS_ROOM, LossFloor), LossFloor, Sizes.LOSS_ROOM_MAX),
		Cut = Setting(Config, "CutNames", Sizes.CUT_NAMES, Sizes.CUT_NAMES_MIN, Sizes.CUT_NAMES_MAX),
	}
	if Rooms.Timed + Rooms.Untimed + Rooms.Work + Rooms.Loss + Rooms.Cut * Limits.ITEM_MAX > Limits.ROOMS_MAX then
		Errors.Misuse(`the rooms of {Config.Name} take more than {Limits.ROOMS_MAX} bytes together`, 1)
	end
	local Migrations, BreakingFloor = Steps(Config.Migrations or {})
	return {
		Reducer = Config.Reducer,
		Migrations = Migrations,
		Default = Config.Default,
		Level = #Migrations,
		Floor = BreakingFloor,
		Money = Money,
		Fields = Fields,
		Erasable = if Config.Erasable == nil then Config.MustExist == true else Config.Erasable,
		Window = Window,
		Minted = Windows.MINTED,
		CutWindow = Windows.CUT,
		TimedRoom = Rooms.Timed,
		UntimedRoom = Rooms.Untimed,
		WorkRoom = Rooms.Work,
		CutNames = Rooms.Cut,
		LossRoom = Rooms.Loss,
		KeepNamed = Setting(Config, "KeepNamed", Windows.KEEP_NAMED, Windows.KEEP_NAMED_MIN, Windows.KEEP_NAMED_MAX),
		LegLimit = Setting(Config, "LegLimit", math.huge, Limits.LEGS_MIN, math.huge),
		StateCap = Sizes.STATE_CAP,
		Ahead = Windows.AHEAD,
		Hold = Windows.HOLD,
	}
end

return Build
