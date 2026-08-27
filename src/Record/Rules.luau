--!strict
--!optimize 2

--[=[
	Rules: The rules that an append is built from, in the order that they run.

	Each rule answers one question. A rule keeps what it must remember in the pass, because the
	datastore can run the transform again.
	A game's op stops at the log cap. One of Ledger's own may pass that cap, because a recovery op
	must be able to land on a key that is already full. It stops at a higher ceiling of its own.
	A sift decides op by op whether the record will take one.

	Readable is the one place that says whether this build may write a record at all. Legible is that
	same question as a rule, and the log asks it directly on the paths that are not an append.

	Return type: A table with Readable, Legible, Allowed, Fresh, Capped, Format, Tomb, Entombed and TOMB_HORIZON.
	Example usage:
		local Rules = require("./Rules")
		local List = { Rules.Legible(Key, Known), Rules.Fresh(Ops) }
--]=]

local Say = require("../Util/Say")
local Clock = require("../Util/Clock")
local Contract = require("../Contract/Op")
local Fault = require("../Contract/Fault")
local Reasons = require("../Contract/Reason")
local Limits = require("../Contract/Limits")
local Measure = require("../Encode/Measure")
local Horizons = require("../Contract/Horizons")
local Rule = require("../Kernel/Rule")

type Op = Contract.Op
type Record = Contract.Record<any>
type Pass = Rule.Pass
type Rule = Rule.Rule

export type Sift = (Record: Record) -> (Op: Op) -> boolean

local ENVELOPE = Contract.ENVELOPE

local TOMB_HORIZON = Horizons.TOMB

local function Entombed(Record: Record): boolean
	local At = Record.Erased
	return type(At) == "number" and Clock.Now() - At <= TOMB_HORIZON
end

local function Readable(Key: string, Known: number?, Record: Record)
	local Floor = Record.Floor
	if type(Known) ~= "number" or type(Floor) ~= "number" or Floor <= Known then
		return
	end

	error(Fault.New(Reasons.Behind, `'{Key}' needs format version {Floor} and this server only knows {Known} migrations, so a newer server wrote it and this one must not add to it`))
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
				Rule.Quiet(Pass)
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

			local Had = #Record.Ops
			for _, Op in Ops do
				if Wanted[Op.Id] then
					Wanted[Op.Id] = nil
					if Take ~= nil and not Take(Op) then
						table.insert(Turned, Op.Id)
						continue
					end
					table.insert(Record.Ops, Op)
				end
			end

			Pass.Notes.Turned = Turned
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
			local Ceiling = if Owned then Limits.Log else Limits.Held
			if Measure(Record.Ops) <= Ceiling then
				return nil
			end

			error(Fault.New(Reasons.Full, `'{Key}' is carrying {Ceiling} bytes of ops that have not been compacted away, so this one cannot go on as well`))
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

local function Tomb(Key: string, Owned: boolean): Rule
	return {
		Name = "tomb",
		Apply = function(Record: Record): Record?
			Record.Envelope = ENVELOPE
			if not Entombed(Record) then
				Record.Erased = nil
			end
			return Record
		end,
		After = function(_: Record, After: Record): string?
			if Owned and Entombed(After) then
				Say.Warn(
					`Ledger: '{Key}' was erased and something wrote to it anyway, so a session on another server is still live on that key. it keeps turning away transfers until the tomb runs out. get the player off every server before erasing them`
				)
			end
			return nil
		end,
	}
end

return table.freeze({
	Readable = Readable,
	Legible = Legible,
	Allowed = Allowed,
	Fresh = Fresh,
	Capped = Capped,
	Format = Format,
	Tomb = Tomb,
	Entombed = Entombed,
	TOMB_HORIZON = TOMB_HORIZON,
})
