--!strict
--!optimize 2

-- builds an op with a fresh unique id, which is what makes a retried append apply once

local HttpService = game:GetService("HttpService")

local TableUtil = require("../Util/TableUtil")
local Clock = require("../Clock")
local Types = require("../Types")

type Op = Types.Op

local function Stamp(Op: Op)
	local Loose: { [any]: any } = Op :: any
	if Loose.Once == nil then
		return
	end

	assert(
		type(Loose.Once) == "string" and #Loose.Once > 0,
		`op '{tostring(Loose.Kind)}' Once must be a non-empty string when given, it is the name a retry repeats`
	)
	if type(Loose.OnceAt) ~= "number" then
		Loose.OnceAt = Clock.Now()
	end
end

local function MakeOp(Kind: string, Fields: { [any]: any }?): Op
	assert(type(Kind) == "string" and #Kind > 0, "an op needs a Kind, a non-empty string")
	assert(Fields == nil or type(Fields) == "table", `op '{Kind}' Fields must be a table when given`)

	local Op: { [any]: any } = if Fields then TableUtil.DeepCopy(Fields) else {}
	if Op.Id ~= nil or Op.Kind ~= nil or Op.OnceAt ~= nil then
		warn(`Ledger: op '{Kind}' passed Id, Kind or OnceAt in its fields. those belong to Ledger, so they got overwritten`)
	end

	Op.Id = HttpService:GenerateGUID(false)
	Op.Kind = Kind
	Op.OnceAt = nil
	Stamp(Op :: Op)

	return Op :: Op
end

return table.freeze({
	New = MakeOp,
	Stamp = Stamp
})
