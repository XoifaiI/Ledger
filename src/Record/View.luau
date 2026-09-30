--!strict
--!optimize 2

--[=[

	View: Logic. A key's state as one build reads it, with the counters a server shows it by.

	Spec: record 5.3 and 7.

	Read runs the migrations the key has not had in memory and writes nothing. A key that holds
	nothing or is being erased is Missing, a key past this build's floor or format is Behind, a key
	whose migrations fail is Refused, and a broken key is Unresolved. A view carries the key's work
	room, for touches and for judging beside its marks.

	Return type: A table with Read. The type is View.
	Example usage:
		local Shown = View.Read(Current, Build)
--]=]

local Answer = require("../Core/Answer")
local Book = require("./Book")
local Key = require("./Key")
local Migrate = require("./Migrate")
local Types = require("./Types")

type Answer = Answer.Answer

export type View = {
	read State: { [string]: any },
	read Writes: number,
	read Cuts: number,
	read Horizon: number,
	read Id: string?,
	read Work: { [string]: Book.Work },
}

local Why = Types.Why

local STOPS: { [Types.Why]: Answer } = {
	[Why.Missing] = Answer.Missing,
	[Why.Behind] = Answer.Behind,
	[Why.Corrupt] = Answer.Unresolved,
}

local View = {}

function View.Read(Current: unknown, Build: Types.Build): View | Answer
	local Found = Key.Read(Current)
	if Found == nil then
		return Answer.Missing
	elseif type(Found) == "string" then
		return STOPS[Found] or Answer.Unresolved
	end
	local Record, State = Found.Book, Found.State
	if Record.Floor > Build.Floor then
		return Answer.Behind
	elseif Record.Level < Build.Level then
		local Migrated = Migrate(State, Record.Level, Build)
		if Migrated == nil then
			return Answer.Refused
		end
		State = Migrated
	end
	return { State = State, Writes = Record.Writes, Cuts = Record.Cuts, Horizon = Record.Horizon, Id = Record.Id, Work = Record.Work }
end

return View
