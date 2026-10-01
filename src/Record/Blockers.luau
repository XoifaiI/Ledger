--!strict
--!optimize 2

--[=[

	Blockers: Logic. What a writer learns of a mark in its way, and what it sends to end it.

	Spec: transaction 4.2.

	Pick gives one item a note listed, the one the server's number falls on in name order, so
	helpers on different servers spread. Mark gives it back as a mark, or nil for a pinned record.
	Read says what a read of the mark's decider decides. It gives a commit with the attempt that
	committed, or an abort. It gives gone when the decider holds no value, and nil when it decides
	nothing yet. Fenced says the same of the report of a fence sent there. Due says whether the
	writer may fence the mark: it is younger than the writer, or Windows.SETTLE old. Fence gives
	that fence, which is not final, and End gives the end a writer carries to the mark's key once
	the mark is decided.

	Return type: A table with Pick, Mark, Read, Fenced, Due, Fence and End. The types are Found,
	Blocker and Decision.
	Example usage:
		local Decided = Blockers.Read(Value, Found)
--]=]

local Book = require("../Record/Book")
local Key = require("../Record/Key")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

export type Found = {
	read Name: string,
	read Item: Book.Work,
	read Ref: Book.Ref,
}

export type Blocker = {
	read Name: string,
	read Item: Book.Escrow | Book.Exclusive,
	read Ref: Book.Ref,
}

export type Decision = {
	read Outcome: Types.Outcome?,
	read Attempt: number,
	read Gone: boolean,
}

local Fate = Book.Fate
local Role = Book.Role
local Report = Types.Report
local Outcome = Types.Outcome
local Why = Types.Why

local Blockers = {}

function Blockers.Pick(Items: { [string]: Book.Work }, Ref: Book.Ref, Server: number): Found?
	local Names: { string } = {}
	for Name in Items do
		table.insert(Names, Name)
	end
	if Names[1] == nil then
		return nil
	end
	table.sort(Names)
	local Name = Names[Server % #Names + 1]
	return { Name = Name, Item = Items[Name], Ref = Ref }
end

function Blockers.Mark(Picked: Found): Blocker?
	local Item = Picked.Item
	if Item.Form == "Pinned" then
		return nil
	end
	return { Name = Picked.Name, Item = Item, Ref = Picked.Ref }
end

function Blockers.Read(Value: unknown, Found: Blocker): Decision?
	local Read = Key.Read(Value)
	local Item = Found.Item
	if Read == nil or Read == Why.Missing then
		return { Attempt = Item.Attempt, Gone = true }
	elseif type(Read) == "string" then
		return nil
	end
	local Record = Read.Book
	local Pinned = Record.Work[Found.Name]
	if Pinned and Pinned.Form == "Pinned" then
		return { Outcome = Outcome.Commit, Attempt = Pinned.Attempt, Gone = false }
	end
	local Held = Record:Held(Found.Name)
	if Held and Held.Role == Role.Decision then
		local Attempt = Held.Attempt or 0
		if Held.Fate == Fate.Took then
			return { Outcome = Outcome.Commit, Attempt = Attempt, Gone = false }
		elseif Held.Fate ~= Fate.Fenced or Held.Final or Attempt >= Item.Attempt then
			return { Outcome = Outcome.Abort, Attempt = Item.Attempt, Gone = false }
		end
	elseif Held == nil and Pinned == nil and Item.Stamp <= Record.Horizon then
		return { Outcome = Outcome.Abort, Attempt = Item.Attempt, Gone = false }
	end
	return nil
end

function Blockers.Fenced(Note: Types.Note?, Found: Blocker): Decision?
	local Said = if Note then Note.Report else nil
	if Note and Said == Report.Committed then
		return { Outcome = Outcome.Commit, Attempt = Note.Attempt or Found.Item.Attempt, Gone = false }
	elseif Said == Report.Fenced or Said == Report.Refused or Said == Report.Forgotten then
		return { Outcome = Outcome.Abort, Attempt = Found.Item.Attempt, Gone = false }
	elseif Note and Note.Why == Why.Missing then
		return { Attempt = Found.Item.Attempt, Gone = true }
	end
	return nil
end

function Blockers.Due(Found: Blocker, Stamp: number, Name: string, Now: number): boolean
	local Held = Found.Item.Stamp
	local Younger = Held > Stamp or (Held == Stamp and Found.Name > Name)
	return Younger or Now - Held >= Windows.SETTLE
end

function Blockers.Fence(Found: Blocker): Types.Request
	local Item = Found.Item
	return {
		Writer = 0,
		Ack = 0,
		MustExist = true,
		Ops = {},
		Fence = { Name = Found.Name, Stamp = Item.Stamp, Attempt = Item.Attempt, Print = Item.Print, Final = false },
	}
end

function Blockers.End(Found: Blocker, Outcome: Types.Outcome, Attempt: number): Types.End
	return { Name = Found.Name, Stamp = Found.Item.Stamp, Attempt = Attempt, Print = Found.Item.Print, Outcome = Outcome }
end

return Blockers
