--!strict
--!optimize 2

--[=[
	View: the state a read or load shows (record sheet 13 to 15): the stored state at the build's level.

	A floor above the build's last breaking migration answers Behind. A failing migration, one past StateCap, or a
	balance rejected after a migration (now or stored) answers Unreadable with its cause (Reading/Unreadable): reads
	never throw. Undeclared fields are kept.

	Return type: A plain table with IsBehind, IsFloorBehind, ViewState, MigrateFrom and MigratedFloor, and the View
	type.
	Example usage:
		local Viewed = View.ViewState(Setup, Kept)
		local Copied = View.MigrateFrom(Setup, State, Level, Floor)
--]=]

local Balances = require("../Tx/Legs/Balances")
local Guards = require("../Judging/Guards")
local Json = require("../Encoding/Json")
local Shapes = require("../Shapes")
local Value = require("../Stored/Value")

type Build = Shapes.Build
type Setup = Shapes.Setup
type Kept = Value.Kept

export type View =
	{ read Kind: "State", read State: { [unknown]: unknown } }
	| { read Kind: "Behind" }
	| { read Kind: "Unreadable", read Cause: "Migration" | "Balance" }

local function IsFloorBehind(Setup: Setup, Floor: number): boolean
	return Floor > Setup.Build.BreakingIndex
end

local function IsBehind(Setup: Setup, Kept: Kept): boolean
	return IsFloorBehind(Setup, Kept.Book.Floor)
end

local function MigrateFrom(Setup: Setup, State: Value.Fields, Level: number, Floor: number): View
	local Build = Setup.Build
	if IsFloorBehind(Setup, Floor) then
		return { Kind = "Behind" }
	end
	for Index = Level + 1, Build.MigrationCount do
		local Migrated = Guards.RunMigration(Build.Migrations[Index].Run, State, Setup.Limits)
		if Migrated.Kind ~= "State" or Json.Size(Migrated.State) > Setup.Limits.StateCap then
			return { Kind = "Unreadable", Cause = "Migration" }
		end
		State = Migrated.State
	end
	if Build.MigrationCount > 0 and Balances.HoldsInvalidBalance(State, Build.Balances) then
		return { Kind = "Unreadable", Cause = "Balance" }
	end
	return { Kind = "State", State = State }
end

local function MigratedFloor(Build: Build, Level: number, Floor: number): number
	local Migrated = Floor
	for Index = Level + 1, Build.MigrationCount do
		if Build.Migrations[Index].IsBreaking then
			Migrated = Index
		end
	end
	return Migrated
end

local function ViewState(Setup: Setup, Kept: Kept): View
	return MigrateFrom(Setup, Kept.State, Kept.Book.Level, Kept.Book.Floor)
end

return {
	IsBehind = IsBehind,
	IsFloorBehind = IsFloorBehind,
	ViewState = ViewState,
	MigrateFrom = MigrateFrom,
	MigratedFloor = MigratedFloor,
}
