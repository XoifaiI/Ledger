--!strict
--!optimize 2

--[=[
	Migrate: Logic. Runs the migrations a key has not had on a copy of its state.

	A migration sees every field. The run fails on a throw, a yield, or a result that is not a table.
	It also fails when the last state is one Guard does not admit, cannot be stored, or passes
	StateCap. A failed run keeps nothing, and the state it was given is never changed.

	Return type: A function that gives back the migrated state, or nil.
	Example usage:
		local State = Migrate(Run.State, Record.Level, Build)
--]=]

local Guard = require("./Guard")
local Reduce = require("../Core/Reduce")
local Types = require("./Types")
local Value = require("../Encode/Value")

type Build = Types.Build
type State = { [string]: any }

local function Migrate(Base: State, Level: number, Build: Build): State?
	local State = Reduce.Copy(Base)
	for Index = Level + 1, Build.Level do
		local Next = Reduce.Run(Build.Migrations[Index], State, nil)
		if Next == nil then
			return nil
		end
		State = Next
	end
	if not Guard.Admits(Build, Base, State) then
		return nil
	end
	local Bytes = Value.Check(State)
	if Bytes == nil or Bytes > Build.StateCap then
		return nil
	end
	return State
end

return Migrate
