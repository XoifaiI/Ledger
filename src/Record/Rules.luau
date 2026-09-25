--!strict
--!optimize 2

--[=[

	Rules: What a rule is, and the rules an append is built from, in the order they run.

	A rule has a check, a change and a test that must hold after the write. Each part is optional. A
	pass is what a rule remembers between those parts, and every run starts a fresh one. Entombed
	and Leaving each take the time a mark was set, since that time is all they read.

	Legible refuses a record a newer build wrote. Allowed runs the caller's guard. Kept answers Busy
	while an erase is taking the key off, so nothing lands between its tomb and its removal. Fresh
	adds only the ops the record lacks, and lets a sift turn one away or hold one back for a later
	write. It holds back an op first sent before the horizon, since the record may have forgotten
	its id, and names it as doubted. Capped refuses once the log is too long. Based stores the state a key starts from on its
	first write, so a later Default reaches only a key nobody has written. Format raises the version
	floor. Tomb stamps the envelope, and clears an erase mark or a removal mark that has run out.

	Return type: A table with Readable, Entombed, Leaving, Settle and the eight rules. The types are Pass, Rule and Sift.
	Example usage:
		local Rules = require("./Rules")
		local List = { Rules.Legible(Key, Known), Rules.Fresh(Ops) }
--]=]

local Clock = require("../Util/Clock")
local TableUtil = require("../Util/TableUtil")
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

local function Entombed(Erased: number?): boolean
	return type(Erased) == "number" and Clock.Now() - Erased <= Windows.TOMB
end

local function Leaving(Removing: number?): boolean
	return type(Removing) == "number" and Clock.Now() - Removing <= Windows.LEAVING
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
				Pass.Silent = true
			end
			return nil
		end,
	}
end

local function Kept(Key: string): Rule
	return {
		Name = "kept",
		Check = function(Record: Record): Reasons.Reason?
			if not Leaving(Record.Removing) then
				return nil
			end

			return Errors.Raise(Reasons.Busy, `'{Key}' is being taken off the datastore by an erase, so nothing can be added to it. try again once it is gone`)
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
			local Doubted: { string } = {}
			local Horizon = Record.Horizon

			local Had = #Record.Ops
			for _, Op in Ops do
				if Wanted[Op.Id] then
					Wanted[Op.Id] = nil
					local Sent = Op.IdAt
					if type(Horizon) == "number" and type(Sent) == "number" and Sent < Horizon then
						table.insert(Doubted, Op.Id)
						continue
					end
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
			Pass.Notes.Doubted = Doubted
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

local function Settle(Record: Record, Base: any?, Known: number?)
	if Base == nil or Record.Snapshot ~= nil or (Record.Version or 0) > (Known or 0) then
		return
	end

	local Snapshot = TableUtil.DeepCopy(Base)
	Record.Snapshot = Snapshot
	Record.Bytes = Measure(Snapshot)
	Record.Version = Known or 0
end

local function Based(Base: any?, Known: number?): Rule
	return {
		Name = "based",
		Apply = function(Record: Record): Record?
			Settle(Record, Base, Known)
			return Record
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
			if not Entombed(Record.Erased) then
				Record.Erased = nil
			end
			if not Leaving(Record.Removing) then
				Record.Removing = nil
			end
			return Record
		end,
	}
end

return table.freeze({
	Readable = Readable,
	Settle = Settle,
	Legible = Legible,
	Allowed = Allowed,
	Kept = Kept,
	Fresh = Fresh,
	Capped = Capped,
	Based = Based,
	Format = Format,
	Tomb = Tomb,
	Entombed = Entombed,
	Leaving = Leaving,
})
