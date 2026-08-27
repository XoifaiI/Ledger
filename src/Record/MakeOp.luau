--!strict
--!optimize 2

--[=[
	MakeOp: Builds an op that has a new unique id.

	The id is what makes an append that runs two times apply one time.
	A caller can put its own OnceAt on an op, but only inside the window a name is kept for. A time
	in the future would hold the name past its own horizon. A time further back than the window is
	already past it, so the next write that carries a name drops it and the op could apply again.

	Return type: A table with New and Stamp.
	Example usage:
		local MakeOp = require("./MakeOp")
		local Op = MakeOp.New("Add", { Amount = 5 })
--]=]

local Say = require("../Util/Say")
local TableUtil = require("../Util/TableUtil")
local Clock = require("../Util/Clock")
local Ident = require("../Encode/Ident")
local Contract = require("../Contract/Op")
local Horizons = require("../Contract/Horizons")

type Op = Contract.Op

local PRUNE_HORIZON = Horizons.PRUNE

local function Stamp(Op: Op): (boolean, string?)
	local Loose: { [any]: any } = Op :: any
	if Loose.Once == nil then
		return true, nil
	end

	if type(Loose.Once) ~= "string" or #Loose.Once == 0 then
		return false, "Once has to be a string with something in it if you pass one"
	end

	local Now = Clock.Now()
	local At = Loose.OnceAt
	if type(At) == "number" and At < Now - PRUNE_HORIZON then
		return false, `OnceAt is further back than the {PRUNE_HORIZON // 86400} days a name is kept for, so the name would be dropped by the next write that carries one and this op could apply again`
	end
	if type(At) ~= "number" or not (At <= Now) then
		Loose.OnceAt = Now
	end
	return true, nil
end

local function MakeOp(Kind: string, Fields: { [any]: any }?): Op
	assert(type(Kind) == "string" and #Kind > 0, "an op needs a Kind, a non-empty string")
	assert(Fields == nil or type(Fields) == "table", `op '{Kind}' Fields must be a table when given`)

	local Op: { [any]: any } = if Fields then TableUtil.DeepCopy(Fields) else {}
	if Op.Id ~= nil or Op.Kind ~= nil or Op.OnceAt ~= nil then
		Say.Warn(`Ledger: op '{Kind}' passed Id, Kind or OnceAt in its fields. those belong to Ledger, so they got overwritten`)
	end

	Op.Id = Ident.Fresh()
	Op.Kind = Kind
	Op.OnceAt = nil

	return Op :: Op
end

return table.freeze({
	New = MakeOp,
	Stamp = Stamp,
})
