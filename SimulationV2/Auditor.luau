--!strict
--!optimize 2

--[=[
	Auditor: Checks that each answer was one that the call may give.

	It does not predict the answer, because under faults and concurrency there is no single right one.
	It starts with everything the catalogue permits and takes away what the conditions rule out.

	Return type: A table with New and NEEDS. The types are Facts, Broken and Auditor.
	Example usage:
		local Books = Auditor.New()
		local Verdict = Books:Observe("Edit", Facts, false, "Busy")
--]=]

local Catalogue = require("./Catalogue")

type Reason = Catalogue.Reason

export type Facts = {
	Faults: boolean,
	Concurrent: boolean,
	Shutting: boolean,
	Aged: boolean,
	Fat: boolean,
	Junk: boolean,
}

export type Broken = {
	read Named: string,
	read Why: string,
	read Allowed: { string },
	read Says: string,
}

type AuditorImpl = {
	__index: AuditorImpl,

	New: () -> Auditor,

	Permit: (self: Auditor, Named: string, Facts: Facts) -> { [string]: boolean },
	Observe: (self: Auditor, Named: string, Facts: Facts, Ok: boolean, Why: string?) -> Broken?,
	Report: (self: Auditor) -> string,
}

export type Auditor = setmetatable<{
	Seen: number,
	Checked: number,
	Broken: { Broken },
}, AuditorImpl>

local OK = "Ok"

local SESSIONS: { [string]: boolean } = {
	Apply = true,
	Commit = true,
	CommitOp = true,
	Flush = true,
	SessionCompact = true,
	SessionRelease = true,
}

local NEEDS: { [string]: (Facts: Facts, Named: string) -> boolean } = {
	Unresolved = function(Facts: Facts, _: string): boolean
		return Facts.Faults or Facts.Concurrent
	end,
	Closed = function(Facts: Facts, Named: string): boolean
		return Facts.Shutting or SESSIONS[Named] == true
	end,
	Behind = function(Facts: Facts, _: string): boolean
		return Facts.Aged
	end,
	Busy = function(Facts: Facts, _: string): boolean
		return Facts.Concurrent
	end,
	Full = function(Facts: Facts, _: string): boolean
		return Facts.Fat
	end,
	Backlog = function(Facts: Facts, _: string): boolean
		return Facts.Fat
	end,
	Invalid = function(Facts: Facts, _: string): boolean
		return Facts.Junk
	end,
}

local SAYS: { [string]: string } = {
	Unresolved = "nothing was faulted and nothing else was in flight, so there was nothing to be unsure about",
	Closed = "no shutdown had run, so no queue could have been skipped under this caller, and this is not a session call",
	Behind = "every build in this run knows the same migrations",
	Busy = "only one worker was on this store, so nothing else could have parked a leg",
	Full = "nothing on this store was anywhere near the byte caps",
	Backlog = "nothing on this store was anywhere near the byte caps",
	Invalid = "this op carried nothing a datastore cannot hold",
}

local Auditor = {} :: AuditorImpl
Auditor.__index = Auditor

function Auditor.New(): Auditor
	return setmetatable({ Seen = 0, Checked = 0, Broken = {} }, Auditor) :: any
end

function Auditor.Permit(self: Auditor, Named: string, Facts: Facts): { [string]: boolean }
	local Allowed: { [string]: boolean } = {}

	if not Facts.Junk then
		Allowed[OK] = true
	end

	for _, Reason in Catalogue.Find(Named).Reasons do
		local Needs = NEEDS[Reason]
		if Needs == nil or Needs(Facts, Named) then
			Allowed[Reason] = true
		end
	end

	return Allowed
end

function Auditor.Observe(self: Auditor, Named: string, Facts: Facts, Ok: boolean, Why: string?): Broken?
	self.Seen += 1

	if not Ok and Why == nil then
		return nil
	end

	local Allowed = self.Permit(self, Named, Facts)
	local Answer = if Ok then OK else Why :: string
	self.Checked += 1

	if Allowed[Answer] then
		return nil
	end

	local Listed: { string } = {}
	for Reason in Allowed do
		table.insert(Listed, Reason)
	end
	table.sort(Listed)

	local Held: Broken = {
		Named = Named,
		Why = Answer,
		Allowed = Listed,
		Says = SAYS[Answer] or "the catalogue does not list that as something this call can answer",
	}
	table.insert(self.Broken, Held)
	return Held
end

function Auditor.Report(self: Auditor): string
	return `{self.Checked} answer(s) checked of {self.Seen} seen, {#self.Broken} outside what was allowed`
end

table.freeze(Auditor)

return table.freeze({
	New = Auditor.New,
	NEEDS = NEEDS,
})
