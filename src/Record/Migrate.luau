--!strict
--!optimize 2

--[=[

	Migrate: Runs the migrations a key has not had yet.

	A key at level g read by a build at level M has migrations g + 1 to M run in order on a copy of
	its state. Each migration is handed the state and gives back the next one, and it may change the
	state it is handed. A migration sees every field of the state. A migration that throws, yields or
	gives back something other than a table has failed. So has a result that adds a top level field
	the build does not declare, holds a money field that is not a whole number below 2^53, cannot be
	stored, or passes StateCap. Nothing a failed run did is kept.

	Return type: A function that gives back the migrated state, or nil when the run failed.
	Example usage:
		local Migrate = require("./Migrate")
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
