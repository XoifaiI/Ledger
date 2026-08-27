--!strict
--!optimize 2

--[=[
	Admit: Rules on one op against the live state.

	This is the only place that decides whether an op may join the session, and it answers with a
	reason and not a boolean.
	Admit measures the state only when the state could be near the cap, because a measure walks the
	whole profile. An op that makes an oversized profile smaller is still allowed.
	Admit turns an op away while two or more transactions are parked, because it cannot prove that
	the op holds for every way they can settle.

	Return type: A table with Admit.
	Example usage:
		local Admit = require("./Admit")
		local Ruling = Admit.Admit(Active, Op, Bytes)
--]=]

local Say = require("../Util/Tools/Say")
local NoYield = require("../Util/Work/NoYield")
local Limits = require("../Contract/Limits")
local Reasons = require("../Contract/Reason")
local Contract = require("../Contract/Op")
local Measure = require("../Encode/Measure")
local Step = require("../Record/Step")
local Types = require("./Types")

type Op = Contract.Op
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
	Say.Warn(`Ledger: rejected op '{Kind}', {Says}`, 1)
	return { Outcome = "Refused", Why = Why }
end

local function Rejected(Kind: string, Says: string): Admitted<any>
	Say.Warn(`Ledger: rejected op '{Kind}', {Says}`, 1)
	return REJECTED
end

local function Admit<S>(self: Session<S>, Op: Op, OpBytes: number, Durable: boolean?): Admitted<S>
	local Kind = Op.Kind
	local Key = self.Key

	if self.Released then
		return Refused(Kind, CLOSED, `that session closed when the player left`)
	end

	if self.LogBytes + OpBytes > Limits.Log then
		if self.Parked > 0 then
			return Refused(Kind, BUSY, `'{Key}' has hit the {Limits.Log} byte cap and cannot shrink while a transaction is parked on it. it clears once that settles`)
		end
		return Refused(Kind, BACKLOG, `unsaved ops have hit the {Limits.Log} byte cap. saves are not going through, check the datastore`)
	end

	local Fine, Next = pcall(NoYield.Run, self.Shape.Reducer, self.State, Op)
	if not Fine then
		if string.find(tostring(Next), NoYield.YIELDED, 1, true) ~= nil then
			error(Next, 0)
		end
		return Rejected(Kind, `your reducer threw: {tostring(Next)}`)
	end

	if Next ~= nil and type(Next) ~= "table" then
		return Refused(Kind, INVALID, `your reducer handed back a {typeof(Next)} instead of the next state table`)
	end

	if Next == nil then
		local Waiting = self.Landed
		if Waiting ~= nil and not Durable and Step(self.Shape.Reducer, Waiting, Op) ~= nil then
			return Refused(Kind, UNRESOLVED, `a transaction is parked on '{Key}' and this op only holds if that transaction goes through. ask again once it settles`)
		end
		return REJECTED
	end

	if self.Parked > 1 and not Durable then
		return Refused(
			Kind,
			UNRESOLVED,
			`more than one transaction is parked on '{Key}' and this op only holds for some of the ways they can settle. ask again once they clear`
		)
	end

	local Also: S? = nil
	local Parked = self.Landed
	if Parked ~= nil and not Durable then
		Also = Step(self.Shape.Reducer, Parked, Op)
		if Also == nil then
			return Refused(Kind, UNRESOLVED, `a transaction is parked on '{Key}' and this op only holds if that transaction does not go through. ask again once it settles`)
		end
	end

	if self.StateBytes + OpBytes > Limits.StateFloor then
		local Counted, Bytes = pcall(Measure, Next)
		if not Counted then
			return Refused(Kind, INVALID, `your reducer built state a datastore cannot hold: {tostring(Bytes)}`)
		end
		if Bytes > Limits.State and Bytes > Measure(self.State) then
			return Refused(Kind, FULL, `this profile is already at the {Limits.State} byte cap and the op would make it bigger`)
		end
		return { Outcome = "Accepted", Next = Next, Bytes = Bytes, Also = Also }
	end

	return { Outcome = "Accepted", Next = Next, Also = Also }
end

return table.freeze({
	Admit = Admit,
})
