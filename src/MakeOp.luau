--!strict
--!optimize 2

--[=[
    MakeOp: builds an op with a fresh unique id.

    the id is what makes appends idempotent so a retried write never duplicates the op.

    Return type: the MakeOp function
    Example usage:
        local MakeOp = require("./MakeOp")
        local Op = MakeOp("AddGold", { Amount = 10 })
--]=]

local HttpService = game:GetService("HttpService")

local TableUtil = require("./Util/TableUtil")
local Types = require("./Types")

type Op = Types.Op

local function MakeOp(Kind: string, Fields: { [any]: any }?): Op
	assert(type(Kind) == "string" and #Kind > 0, "an op needs a Kind, a non-empty string")
	assert(Fields == nil or type(Fields) == "table", `op '{Kind}' Fields must be a table when given`)

	local Op: { [any]: any } = if Fields then TableUtil.DeepCopy(Fields) else {}
	if Op.Id ~= nil or Op.Kind ~= nil then
		warn(`Ledger: op '{Kind}' fields carried Id or Kind, those are reserved and were overwritten`)
	end

	Op.Id = HttpService:GenerateGUID(false)
	Op.Kind = Kind

	return Op :: Op
end

return MakeOp
