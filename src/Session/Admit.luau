--!strict
--!optimize 2

--[=[

	Admit: Rules on one op against the live state.

	This is the only place that decides whether an op may join a session. It answers with a reason
	rather than a boolean. It runs the reducer against live state, and checks the op against the log
	and state caps. It turns an op away while a parked transaction could settle either way.

	Return type: A table with Admit.
	Example usage:
		local Admit = require("./Admit")
		local Ruling = Admit.Admit(Active, Op, Bytes)
--]=]

local Messages = require("../Core/Constants/Messages")
local NoYield = require("../Util/NoYield")
local Sizes = require("../Core/Constants/Sizes")
local Reasons = require("../Core/Constants/Reasons")
local Shapes = require("../Core/Shapes")
local Measure = require("../Encode/Measure")
local Apply = require("../Record/Apply")
local Rebuild = require("./Rebuild")
local Types = require("./Types")

type Op = Shapes.Op
type Reason = Reasons.Reason
type Session<S> = Types.Session<S>
type Admitted<S> = Types.Admitted<S>

local BUSY = Reasons.Busy
local CLOSED = Reasons.Closed
local BACKLOG = Reasons.Backlog
local FULL = Reasons.Full
local INVALID = Reasons.Invalid
local UNRESOLVED = Reasons.Unresolved

local REJECTED: Admitted<any> = table.freeze({ Outcome = "Rejected" }) :: any

local function Refused(Kind: string, Why: Reason, Says: string): Admitted<any>
	warn(`Ledger: rejected op '{Kind}', {Says}`)
	return { Outcome = "Refused", Why = Why }
end

local function Rejected(Kind: string, Says: string): Admitted<any>
	warn(`Ledger: rejected op '{Kind}', {Says}`)
	return REJECTED
end

local function Admit<S>(self: Session<S>, Op: Op, OpBytes: number, Durable: boolean?): Admitted<S>
	local Kind = Op.Kind
	local Key = self.Key

	if self.Released then
		return Refused(Kind, CLOSED, `that session closed when the player left`)
	end

	if self.LogBytes + OpBytes + Rebuild.SEPARATOR > Sizes.Log then
		if self.Parked > 0 then
			return Refused(Kind, BUSY, `'{Key}' has hit the {Sizes.Log} byte cap and cannot shrink while a transaction is parked on it. it clears once that settles`)
		end
		return Refused(Kind, BACKLOG, `unsaved ops have hit the {Sizes.Log} byte cap. saves are not going through, check the datastore`)
	end

	local Fine, Next = pcall(NoYield.Run, self.Shape.Reducer, self.State, Op)
	if not Fine then
		if string.find(tostring(Next), Messages.YIELDED, 1, true) ~= nil then
			error(Next, 0)
		end
		return Rejected(Kind, `your reducer threw: {tostring(Next)}`)
	end

	if Next ~= nil and type(Next) ~= "table" then
		return Refused(Kind, INVALID, `your reducer handed back a {typeof(Next)} instead of the next state table`)
	end

	if Next == nil then
		local Waiting = self.Landed
		if Waiting ~= nil and not Durable and Apply(self.Shape.Reducer, Waiting, Op) ~= nil then
			return Refused(Kind, UNRESOLVED, `a transaction is parked on '{Key}' and this op only holds if that transaction goes through. ask again once it settles`)
		end
		return REJECTED
	end

	if self.Parked > 1 and not Durable then
		return Refused(Kind, UNRESOLVED, `more than one transaction is parked on '{Key}' and this op only holds for some of the ways they can settle. ask again once they clear`)
	end

	local Also: S? = nil
	local Parked = self.Landed
	if Parked ~= nil and not Durable then
		Also = Apply(self.Shape.Reducer, Parked, Op)
		if Also == nil then
			return Refused(Kind, UNRESOLVED, `a transaction is parked on '{Key}' and this op only holds if that transaction does not go through. ask again once it settles`)
		end
	end

	if self.StateBytes + OpBytes > Sizes.StateFloor then
		local Counted, Bytes = pcall(Measure, Next)
		if not Counted then
			return Refused(Kind, INVALID, `your reducer built state a datastore cannot hold: {tostring(Bytes)}`)
		end
		if Bytes > Sizes.State and Bytes > Measure(self.State) then
			return Refused(Kind, FULL, `this profile is already at the {Sizes.State} byte cap and the op would make it bigger`)
		end
		return { Outcome = "Accepted", Next = Next, Bytes = Bytes, Also = Also }
	end

	return { Outcome = "Accepted", Next = Next, Also = Also }
end

return table.freeze({
	Admit = Admit,
})
