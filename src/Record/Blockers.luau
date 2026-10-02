--!strict
--!optimize 2

--[=[
	Blockers: Logic. What a writer learns of a mark in its way, and what it sends to end it.

	Spec: transaction 4.2.

	A note lists the items in the way. Pick takes the one the server's number falls on in name order,
	so helpers on different servers spread. A read of the mark's decider decides a commit, with the
	attempt that committed, or an abort. It says gone when the decider holds no value, and nothing
	while the decider has not decided the mark's attempt. A decider that holds no trace of the name,
	and whose horizon has passed the mark's stamp, has aborted. A writer may fence a mark that is
	younger than its own op, or one Windows.SETTLE old. That fence is never final.

	Return type: The Blockers module, and the Found, Blocker and Decision types.
	Example usage:
		local Decided = Blockers.Read(Value, Found)
--]=]

local Book = require("../Record/Book")
local Key = require("../Record/Key")
local Requests = require("./Requests")
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
	read Outcome: Requests.Outcome?,
	read Attempt: number,
	read Gone: boolean,
	read Value: number?,
}

local WorkForm = Book.WorkForm
local Fate = Book.Fate
local Role = Book.Role
local Report = Types.Report
local Outcome = Requests.Outcome
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
	local Mark = Book.AsMark(Picked.Item)
	if Mark == nil then
		return nil
	end
	return { Name = Picked.Name, Item = Mark, Ref = Picked.Ref }
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
	if Pinned and Pinned.Form == WorkForm.Pinned then
		return { Outcome = Outcome.Commit, Attempt = Pinned.Attempt, Gone = false, Value = Pinned.Value }
	end
	local Held = Record:Held(Found.Name)
	if Held and Held.Role == Role.Decision then
		local Attempt = Held.Attempt or 0
		if Held.Fate == Fate.Took then
			return { Outcome = Outcome.Commit, Attempt = Attempt, Gone = false, Value = Held.Value }
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
		return { Outcome = Outcome.Commit, Attempt = Note.Attempt or Found.Item.Attempt, Gone = false, Value = Note.Value }
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

function Blockers.Fence(Found: Blocker): Requests.Request
	local Item = Found.Item
	return Requests.Fence({ Name = Found.Name, Stamp = Item.Stamp, Attempt = Item.Attempt, Print = Item.Print, Final = false })
end

function Blockers.End(Found: Blocker, Outcome: Requests.Outcome, Attempt: number, Value: number?): Requests.End
	return { Name = Found.Name, Stamp = Found.Item.Stamp, Attempt = Attempt, Print = Found.Item.Print, Outcome = Outcome, Value = Value }
end

return Blockers
