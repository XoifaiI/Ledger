--!strict
--!optimize 2

--[=[

	View: Logic. A key's state as one build reads it, with the counters a server shows it by.

	Spec: record 5.3 and 7.

	Read runs the migrations the key has not had in memory and writes nothing. A key that holds
	nothing or is being erased is Missing. A key past this build's floor or format is Behind. A key
	whose migrations fail is Refused, and a broken key is Unresolved. A view carries the key's work
	room, for touches and for judging beside its marks, and its loss room and gate. Level and Floor
	are those of the state it shows: the build's when it ran migrations, else the key's.

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
	read Level: number,
	read Floor: number,
	read Id: string?,
	read Work: { [string]: Book.Work },
	read Events: { Book.Event }?,
	read Slots: { Book.Slot }?,
	read Gate: Book.Gate?,
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
	local Level, Floor = Record.Level, Record.Floor
	if Record.Floor > Build.Floor then
		return Answer.Behind
	elseif Record.Level < Build.Level then
		local Migrated = Migrate(State, Record.Level, Build)
		if Migrated == nil then
			return Answer.Refused
		end
		State, Level, Floor = Migrated, Build.Level, Build.Floor
	end
	return {
		State = State,
		Writes = Record.Writes,
		Cuts = Record.Cuts,
		Horizon = Record.Horizon,
		Level = Level,
		Floor = Floor,
		Id = Record.Id,
		Work = Record.Work,
		Events = Record.Events,
		Slots = Record.Slots,
		Gate = Record.Gate,
	}
end

return View
