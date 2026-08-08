--!strict
--!optimize 2

--[=[
	Admit: Rules on one op against the live state.
	
	This is the only place that decides whether an op may join the session, and it answers with a
	reason and not a boolean.
	State is measured only when it could be near the cap, because a measure walks the whole profile.
	One op can add no more than the largest that an op may be.
	An op that makes an oversized profile smaller is still allowed, so a cleanup works when a game
	is already past the cap.
	With two or more transactions parked, there are too many ways for them to settle to prove that
	an op holds for all of them. The op is turned away, and not guessed at.
	
	Return type: A table with Admit and MAX_STATE_BYTES.
	Example usage:
		local Admit = require("./Admit")
		local Ruling = Admit.Admit(Active, Op, Bytes)
--]=]

local NoYield = require("../Util/NoYield")
local Reasons = require("../Contract/Reason")
local Contract = require("../Contract/Op")
local Measure = require("../Encode/Measure")
local IsStorable = require("../Encode/Storable")
local Log = require("../Record/Log")
local Step = require("../Record/Step")
local Types = require("./Types")

type Op = Contract.Op
type Session<S> = Types.Session<S>
type Admitted<S> = Types.Admitted<S>

local MAX_STATE_BYTES = Contract.MAX_STATE_BYTES

local STATE_CHECK_FLOOR = MAX_STATE_BYTES - IsStorable.MAX_BYTES

local MAX_LOG_BYTES = Log.MAX_LOG_BYTES

local BUSY = Reasons.Busy
local CLOSED = Reasons.Closed
local BACKLOG = Reasons.Backlog
local FULL = Reasons.Full
local INVALID = Reasons.Invalid
local UNRESOLVED = Reasons.Unresolved

local function Admit<S>(self: Session<S>, Op: Op, OpBytes: number, Durable: boolean?): Admitted<S>
	if self.Released then
		warn(`Ledger: rejected op '{Op.Kind}', that session closed when the player left`)
		return { Outcome = "Refused", Why = CLOSED }
	end

	if self.LogBytes + OpBytes > MAX_LOG_BYTES then
		if self.Parked > 0 then
			warn(
				`Ledger: rejected op '{Op.Kind}', '{self.Key}' has hit the {MAX_LOG_BYTES} byte cap and cannot shrink while a transaction is parked on it. it clears once that settles`
			)
			return { Outcome = "Refused", Why = BUSY }
		end
		warn(`Ledger: rejected op '{Op.Kind}', unsaved ops have hit the {MAX_LOG_BYTES} byte cap. saves are not going through, check the datastore`)
		return { Outcome = "Refused", Why = BACKLOG }
	end

	local Next = NoYield.Run(self.Shape.Reducer, self.State, Op)
	if Next ~= nil and type(Next) ~= "table" then
		warn(`Ledger: rejected op '{Op.Kind}', your reducer handed back a {typeof(Next)} instead of the next state table`)
		return { Outcome = "Refused", Why = INVALID }
	end
	if Next == nil then
		return { Outcome = "Rejected" }
	end

	assert(Next ~= self.State, `your reducer handed back the very table it was given for op '{Op.Kind}', so it changed live state in place`)

	if self.Parked > 1 and not Durable then
		warn(
			`Ledger: rejected op '{Op.Kind}', more than one transaction is parked on '{self.Key}' and this op only holds for some of the ways they can settle. ask again once they clear`
		)
		return { Outcome = "Refused", Why = UNRESOLVED }
	end

	local Also: S? = nil
	local Parked = self.Landed
	if Parked ~= nil and not Durable then
		Also = Step(self.Shape.Reducer, Parked, Op)
		if Also == nil then
			warn(
				`Ledger: rejected op '{Op.Kind}', a transaction is parked on '{self.Key}' and this op only holds if that transaction does not go through. ask again once it settles`
			)
			return { Outcome = "Refused", Why = UNRESOLVED }
		end
	end

	if self.StateBytes + OpBytes > STATE_CHECK_FLOOR then
		local Bytes = Measure(Next)
		if Bytes > MAX_STATE_BYTES and Bytes > Measure(self.State) then
			warn(`Ledger: rejected op '{Op.Kind}', this profile is already at the {MAX_STATE_BYTES} byte cap and the op would make it bigger`)
			return { Outcome = "Refused", Why = FULL }
		end
		return { Outcome = "Accepted", Next = Next, Bytes = Bytes, Also = Also }
	end

	return { Outcome = "Accepted", Next = Next, Also = Also }
end

return table.freeze({
	Admit = Admit,
	MAX_STATE_BYTES = MAX_STATE_BYTES
})
