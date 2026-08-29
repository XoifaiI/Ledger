--!strict
--!optimize 2

--[=[
	Validate: Refuses each store that Ledger.New cannot build.

	A store that is set up wrong throws where it was built. It does not behave wrongly on a key
	months later.

	Return type: A function that throws, and gives back nothing.
	Example usage:
		local Validate = require("./Validate")
		Validate(Options)
--]=]

local Storable = require("../Encode/Storable")
local Api = require("../Core/Api")

type Config<D> = Api.Config<D>

local MAX_NAME = 47

local function Named<D>(Options: Config<D>)
	assert(type(Options.Name) == "string" and #Options.Name > 0 and #Options.Name <= MAX_NAME, `New needs Name, a datastore name of 1 to {MAX_NAME} characters (the transaction store appends _Tx)`)
	assert(type(Options.Reducer) == "function", "New needs Reducer, a (State, Op) -> State? function")
	assert(type(Options.Default) == "table", "New needs Default, the fresh state table")
	assert(Options.Keys == nil or Options.Keys == "Player" or Options.Keys == "String", `Keys must be "Player" or "String"`)
	assert(Options.OnLoadFailed == nil or type(Options.OnLoadFailed) == "function", "OnLoadFailed must be a (Player, Reason) -> boolean function if you pass one")
	assert(Options.OnLoadFailed == nil or Options.Keys ~= "String", `OnLoadFailed only fires for Store:Load, which needs Keys to be "Player"`)
end

local function Stores<D>(Options: Config<D>)
	for Key in Options.Default :: any do
		assert(not (type(Key) == "string" and Storable.Bookkeeping(Key)), `Default key '{tostring(Key)}' uses the '_' prefix reserved for Ledger's bookkeeping`)
	end

	local Fits, Unstorable = Storable.Value(Options.Default)
	assert(Fits, `Default cannot be stored: {Unstorable}`)
end

local function Stepped<D>(Options: Config<D>)
	local Steps = Options.Migrations
	if Steps == nil then
		return
	end

	assert(type(Steps) == "table", "Migrations must be an array of steps")
	for Index, Step in Steps do
		assert(type(Step) == "function" or (type(Step) == "table" and type((Step :: any).Apply) == "function"), `migration {Index} must be a function or a table with an Apply function`)
	end
end

local function Balanced<D>(Options: Config<D>)
	local Field = Options.Balance
	if Field == nil then
		return
	end

	assert(type(Field) == "string" and #Field > 0, `Balance must name a field, like "Gold"`)
	assert(type((Options.Default :: any)[Field]) == "number", `Balance names '{Field}' but the Default has no numeric field by that name`)
end

local function Validate<D>(Options: Config<D>)
	assert(type(Options) == "table", "New takes an options table")

	Named(Options)
	Stores(Options)
	Stepped(Options)
	Balanced(Options)
end

return Validate
