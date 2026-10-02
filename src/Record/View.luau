--!strict
--!optimize 2

--[=[
	View: Logic. A key's state as one build reads it, with the counters a server shows it by.

	Spec: record 5.3 and 7.

	Read runs the migrations the key has not had, in memory, and writes nothing. An empty or sealed
	key is Missing. A key past this build's floor or format is Behind. A key whose migrations fail is
	Refused, and a broken key is Unresolved. Level and Floor are those of the state the view shows:
	the build's when migrations ran, else the key's. The view carries the work room, the loss room
	and the gate as the key holds them.

	Return type: The View module, and the View type.
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
		State = Migrated
		Level = Build.Level
		Floor = Build.Floor
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
