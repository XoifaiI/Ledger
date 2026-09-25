--!strict
--!optimize 2

--[=[

	NewOp: Builds an op that has a new unique id.

	The id is what makes an append that runs twice apply once. Stamp puts the time on a caller's Once
	name and refuses one stamped outside the window a name is kept for. IdAt is when an op whose id
	the caller chose was first sent. A key refuses such an op as doubted once it may have forgotten
	that id, so New drops IdAt from an id it mints. Check is everything an op has to pass before it
	is offered anywhere: stamped, dated, then held against what a datastore can store.

	Return type: A table with New and Check.
	Example usage:
		local NewOp = require("./NewOp")
		local Op = NewOp.New("Add", { Amount = 5 })
--]=]

local TableUtil = require("../Util/TableUtil")
local Clock = require("../Util/Clock")
local Ids = require("../Encode/Ids")
local Storable = require("../Encode/Storable")
local Shapes = require("../Core/Shapes")
local Windows = require("../Core/Constants/Windows")

type Op = Shapes.Op

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
	if type(At) == "number" and At < Now - Windows.ONCE_FLOOR then
		return false,
			`OnceAt is further back than the {Windows.ONCE_FLOOR // Windows.DAY} days a name may be stamped in the past, so it would run out inside the {Windows.ONCE_MARGIN // Windows.DAY} days a retry has to arrive in and this op could apply again`
	end
	if type(At) ~= "number" or not (At <= Now) then
		Loose.OnceAt = Now
	end
	return true, nil
end

local function Dated(Op: Op): (boolean, string?)
	local Loose: { [any]: any } = Op :: any
	local At = Loose.IdAt
	if At == nil then
		return true, nil
	end
	if type(At) ~= "number" or At ~= At then
		return false, "IdAt has to be the time in seconds this op was first sent"
	end

	local Now = Clock.Now()
	if At > Now then
		Loose.IdAt = Now
	end
	return true, nil
end

local function Check(Op: Op): (boolean, string?)
	local Named, Unnamed = Stamp(Op)
	if not Named then
		return false, Unnamed
	end
	local Timed, Untimed = Dated(Op)
	if not Timed then
		return false, Untimed
	end
	return Storable.Op(Op)
end

local function NewOp(Kind: string, Fields: { [any]: any }?): Op
	assert(type(Kind) == "string" and #Kind > 0, "an op needs a Kind, a non-empty string")
	assert(Fields == nil or type(Fields) == "table", `op '{Kind}' Fields must be a table when given`)

	local Op: { [any]: any } = if Fields then TableUtil.DeepCopy(Fields) else {}
	if Op.Id ~= nil or Op.Kind ~= nil or Op.OnceAt ~= nil or Op.Booking ~= nil then
		warn(`Ledger: op '{Kind}' passed Id, Kind, OnceAt or Booking in its fields. those belong to Ledger, so they got overwritten`)
	end
	if Op.IdAt ~= nil then
		warn(`Ledger: op '{Kind}' passed IdAt, which only means something on an op whose Id you chose, with EditOp, CommitOp or Confirm. it was dropped`)
	end

	Op.Id = Ids.Fresh()
	Op.Kind = Kind
	Op.OnceAt = nil
	Op.Booking = nil
	Op.IdAt = nil

	return Op :: Op
end

return table.freeze({
	New = NewOp,
	Check = Check,
})
