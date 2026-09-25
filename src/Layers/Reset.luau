--!strict
--!optimize 2

--[=[

	Reset: Puts a key back to the state it starts from, and keeps Ledger's own fields.

	It wraps every other layer, so a reset op never reaches them or the game. The op carries the
	default state with the version and the floor of the build that wrote it. That state runs through
	the migrations this build knows, then the defaults it lacks fill in. A reset a newer build wrote,
	past the migrations this build has, is refused and waits for a build that has them. Every field
	starting with an underscore carries across from the state before, so a reset cannot strand money
	still being sent or forget an applied name.

	Return type: A table with Wrap.
	Example usage:
		local Reset = require("./Reset")
		local Reducer = Reset.Wrap(Inner, Initial, Steps)
--]=]

local TableUtil = require("../Util/TableUtil")
local Kinds = require("../Core/Constants/Kinds")
local Shapes = require("../Core/Shapes")
local Storable = require("../Encode/Storable")
local Reconcile = require("../Record/Reconcile")
local Schema = require("../Record/Schema")

type Op = Shapes.Op
type Reducer<S> = Shapes.Reducer<S>
type Migration = Shapes.Migration

local function Wrap(Inner: Reducer<any>, Initial: any, Steps: { Migration }): Reducer<any>
	local Known = #Steps

	local function Combined(State: any, Op: Op): any?
		if Op.Kind ~= Kinds.RESET then
			return Inner(State, Op)
		end

		local Snapshot = Op.State
		if type(Snapshot) ~= "table" then
			return nil
		end

		local Version = if type(Op.Version) == "number" then Op.Version else 0
		local Floor = if type(Op.Floor) == "number" then Op.Floor else Version
		if Version > Known and Floor > Known then
			return nil
		end

		local Migrated = Schema.Migrate(Steps, TableUtil.DeepCopy(Snapshot), Version)
		if Migrated == nil then
			return nil
		end

		local Next = Reconcile(Initial, Migrated)
		for Field, Held in State do
			if type(Field) == "string" and Storable.Bookkeeping(Field) then
				Next[Field] = Held
			end
		end
		return Next
	end

	return Combined
end

return table.freeze({
	Wrap = Wrap,
})
