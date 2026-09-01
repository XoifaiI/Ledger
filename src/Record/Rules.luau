--!strict
--!optimize 2

--[=[

	Rules: What a rule is, and the rules an append is built from, in the order they run.

	A rule has a check, a change and a test that must hold after the write, and each part is optional.
	A pass is what a rule remembers between those parts, and it is cleared at the start of every run.
	The rules are: legible refuses a record a newer build wrote, allowed runs the caller's guard, fresh
	adds only the ops the record lacks and lets a sift turn one away or hold one back for a later
	write, capped refuses once the log is too long, format raises the version floor, and tomb stamps
	the envelope.

	Return type: A table with New, Reset, Readable, Entombed and the six rules. The types are Pass, Rule and Sift.
	Example usage:
		local Rules = require("./Rules")
		local List = { Rules.Legible(Key, Known), Rules.Fresh(Ops) }
--]=]

local Clock = require("../Util/Clock")
local Kinds = require("../Core/Constants/Kinds")
local Shapes = require("../Core/Shapes")
local Errors = require("../Core/Errors")
local Reasons = require("../Core/Constants/Reasons")
local Sizes = require("../Core/Constants/Sizes")
local Measure = require("../Encode/Measure")
local Windows = require("../Core/Constants/Windows")

type Op = Shapes.Op
type Record = Shapes.Record<any>
type Reason = Reasons.Reason

export type Pass = {
	Refused: Reason?,
	Silent: boolean,
	Notes: { [string]: any },
}

export type Rule = {
	Name: string,
	Check: ((Record: Record, Pass: Pass) -> Reason?)?,
	Apply: ((Record: Record, Pass: Pass) -> Record?)?,
	After: ((Before: Record, After: Record, Pass: Pass) -> string?)?,
}

export type Sift = (Record: Record) -> (Op: Op) -> boolean?

local function Quiet(Pass: Pass)
	Pass.Silent = true
end

local function New(): Pass
	return { Refused = nil, Silent = false, Notes = {} }
end

local function Reset(Pass: Pass)
	Pass.Refused = nil
	Pass.Silent = false
	table.clear(Pass.Notes)
end

local function Entombed(Record: Record): boolean
	local At = Record.Erased
	return type(At) == "number" and Clock.Now() - At <= Windows.TOMB
end

local function Readable(Key: string, Known: number?, Record: Record)
	local Floor = Record.Floor
	if type(Known) ~= "number" or type(Floor) ~= "number" or Floor <= Known then
		return
	end

	Errors.Raise(Reasons.Behind, `'{Key}' was written by a newer build with more migrations than this server has, so this server must not add to it. finish the deploy`)
end

local function Legible(Key: string, Known: number?): Rule
	return {
		Name = "legible",
		Check = function(Record: Record): Reasons.Reason?
			Readable(Key, Known, Record)
			return nil
		end,
	}
end

local function Allowed(Guard: ((Record) -> boolean)?): Rule
	return {
		Name = "allowed",
		Check = function(Record: Record, Pass: Pass): Reasons.Reason?
			if Guard ~= nil and not Guard(Record) then
				Quiet(Pass)
			end
			return nil
		end,
	}
end

local function Fresh(Ops: { Op }, Sift: Sift?): Rule
	return {
		Name = "fresh",
		Apply = function(Record: Record, Pass: Pass): Record?
			local Wanted: { [string]: boolean } = {}
			for _, Op in Ops do
				Wanted[Op.Id] = true
			end
			for _, Existing in Record.Ops do
				Wanted[Existing.Id] = nil
			end
			for _, Id in Record.Seen do
				Wanted[Id] = nil
			end

			local Take = if Sift ~= nil then Sift(Record) else nil
			local Turned: { string } = {}
			local Waiting: { string } = {}

			local Had = #Record.Ops
			for _, Op in Ops do
				if Wanted[Op.Id] then
					Wanted[Op.Id] = nil
					if Take ~= nil then
						local Taken = Take(Op)
						if Taken == nil then
							table.insert(Waiting, Op.Id)
							continue
						end
						if not Taken then
							table.insert(Turned, Op.Id)
							continue
						end
					end
					table.insert(Record.Ops, Op)
				end
			end

			Pass.Notes.Turned = Turned
			Pass.Notes.Waiting = Waiting
			if #Record.Ops == Had then
				return nil
			end

			Pass.Notes.Before = Had
			Pass.Notes.Added = #Record.Ops - Had
			return Record
		end,
		After = function(_: Record, After: Record, Pass: Pass): string?
			local Before, Added = Pass.Notes.Before, Pass.Notes.Added
			if type(Added) ~= "number" or Added <= 0 then
				return "the record was rewritten without adding any of the ops it was given"
			end
			if #After.Ops ~= Before + Added then
				return "the ops it wrote did not all come back, so the write was only partly stored"
			end
			return nil
		end,
	}
end

local function Capped(Key: string, Owned: boolean): Rule
	return {
		Name = "capped",
		Check = function(Record: Record): Reasons.Reason?
			local Ceiling = if Owned then Sizes.Log else Sizes.Held
			if Measure(Record.Ops) <= Ceiling then
				return nil
			end

			return Errors.Raise(Reasons.Full, `'{Key}' holds more than {Ceiling} bytes of unsaved ops, so it cannot take this one`)
		end,
	}
end

local function Format(Floor: number?): Rule
	return {
		Name = "format",
		Apply = function(Record: Record): Record?
			if type(Floor) == "number" and Floor > (Record.Floor or 0) then
				Record.Floor = Floor
			end
			return Record
		end,
	}
end

local function Tomb(): Rule
	return {
		Name = "tomb",
		Apply = function(Record: Record): Record?
			Record.Envelope = Kinds.ENVELOPE
			if not Entombed(Record) then
				Record.Erased = nil
			end
			return Record
		end,
	}
end

return table.freeze({
	New = New,
	Reset = Reset,

	Readable = Readable,
	Legible = Legible,
	Allowed = Allowed,
	Fresh = Fresh,
	Capped = Capped,
	Format = Format,
	Tomb = Tomb,
	Entombed = Entombed,
})
