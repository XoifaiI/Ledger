--!strict
--!optimize 2

--[=[

	Session: One player and one key, with the state folded from the log.

	Apply is hopeful: it folds against live state, answers at once, and queues the op. Commit writes
	before it answers, and a commit whose op has already been folded into the snapshot cannot be
	answered and says so. A commit the sift held back writes again a few times at most, since nothing
	but that count paces it. A commit that finds the log full compacts it once, as a flush does, and
	answers Full if it is full still. A commit whose IdAt is older than the ids the key still keeps
	answers Unresolved and is not written. A commit whose op landed, or may have landed on a try whose
	answer was lost, and then went with an erase answers Unresolved and not Refused. Flush pushes what
	is queued, Compact folds the log into a snapshot, and Release is the last save on the way out. The fence is taken on load and dropped once the erase it
	marks has run out. A session the fence or a newer build stopped keeps nothing queued and answers
	why on every save after.

	Return type: A table with Load and MAX_PENDING.
	Example usage:
		local Session = require("./Session")
		local Active = Session.Load(Books, Format, "1", TxStore):Wait()
--]=]

local Clock = require("../Util/Clock")
local Future = require("../Util/Future")
local Observer = require("../Util/Observer")
local TableUtil = require("../Util/TableUtil")
local DataStoreWrapper = require("../Util/DataStoreWrapper")
local Errors = require("../Core/Errors")
local Reasons = require("../Core/Constants/Reasons")
local Shapes = require("../Core/Shapes")
local Tags = require("../Core/Constants/Tags")
local Applied = require("../Core/Applied")
local Validate = require("../Core/Validate")
local Windows = require("../Core/Constants/Windows")
local Measure = require("../Encode/Measure")
local LogTypes = require("../Record/Types")
local NewOp = require("../Record/NewOp")
local TxStamp = require("../Record/TxStamp")
local Tx = require("../Protocol/Tx")
local Admit = require("./Admit")
local Rebuild = require("./Rebuild")
local Types = require("./Types")

type Op = Shapes.Op
type Record = Shapes.Record<any>
type Reason = Reasons.Reason
type Future<T...> = Future.Future<T...>
type Observer<T> = Observer.Observer<T>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

export type Session<S> = Types.Session<S>

local MAX_PENDING = 4096
local MAX_APPENDS = 4

local REFUSED = Reasons.Refused
local BACKLOG = Reasons.Backlog
local INVALID = Reasons.Invalid
local UNRESOLVED = Reasons.Unresolved
local BEHIND = Reasons.Behind
local FULL = Reasons.Full

local function Rejected(Why: Reason?): Future<boolean, Reason?>
	return Future.Completed(false, Why)
end

local Session = {} :: Types.SessionImpl<any>
Session.__index = Session

local function Unparked<S>(self: Session<S>, Stored: Record, Deadline: number): Record
	local Held = Stored
	while TxStamp.HasPending(Held) and Clock.Now() < Deadline do
		Clock.Wait(Windows.POLL)
		Held = self:Settled((self.Log:Read(self.Key)))
	end
	return Held
end

local function Load<S>(Records: LogTypes.Log, Format: LogTypes.Shape<S>, Key: string, TxStore: DataStoreWrapper?): Future<Session<S>?, Reason?>
	return Future.New(function(): (Session<S>?, Reason?)
		local Body = {
			Log = Records,
			Shape = Format,
			Key = Key,
			TxStore = TxStore,
			State = Format.Initial,
			Landed = nil,
			Fence = nil,
			Parked = 0,
			Applied = {},
			Pending = {},
			LogSize = 0,
			LogBytes = 0,
			StateBytes = 0,
			Changed = Observer.New(),
			Released = false,
			Stopped = nil,
		}

		local Active: Session<S> = setmetatable(Body :: any, Session) :: any
		local Ok, Reason = pcall(function()
			local Stored = Active:Settled((Records:Read(Key)))
			Active.Fence = Rebuild.Fenced(Stored.Erased)
			Rebuild.Rebuild(Active, Stored)
		end)
		if not Ok then
			warn(`Ledger: could not load '{Key}': {Reason}`)
			return nil, Errors.Reason(Reason)
		end

		return Active, nil
	end)
end

function Session.Settled<S>(self: Session<S>, Stored: Record): Record
	local TxStore = self.TxStore
	if TxStore == nil or not TxStamp.HasPending(Stored) then
		return Stored
	end

	local Ok, Resolved = pcall(function(): Record
		return Tx.Settle(self.Log, TxStore, self.Key, Stored)
	end)
	if Ok then
		return Resolved
	end
	warn(`Ledger: a transaction parked on '{self.Key}' could not be settled, so this read leaves it out for now: {Resolved}`)
	return Stored
end

function Session.Notify<S>(self: Session<S>)
	self.Changed:Push(self.State)
end

function Session.Get<S>(self: Session<S>): S
	return self.State
end

function Session.Observe<S>(self: Session<S>): Observer<S>
	return self.Changed
end

function Session.DidApply<S>(self: Session<S>, Id: string): boolean
	assert(type(Id) == "string" and #Id > 0, "DidApply needs the same Once name the op was written under")
	return Applied.Has((self.State :: any)._Received, Tags.ONCE, Id)
end

function Session.Apply<S>(self: Session<S>, Kind: string, Fields: { [any]: any }?): (boolean, Reason?)
	if #self.Pending >= MAX_PENDING then
		warn(`Ledger: rejected op '{Kind}', {MAX_PENDING} ops are already pending. saves are not going through, check the datastore`)
		return false, BACKLOG
	end

	local Op = NewOp.New(Kind, Fields)

	local Fine, Wrong = NewOp.Check(Op)
	if not Fine then
		warn(`Ledger: rejected op '{Kind}', {Wrong}`)
		return false, INVALID
	end

	local OpBytes = Measure(Op)
	local Ruling = Admit.Admit(self, Op, OpBytes)
	if Ruling.Outcome == "Refused" then
		return false, Ruling.Why
	end
	if Ruling.Outcome == "Rejected" then
		return false, REFUSED
	end

	assert(not self.Applied[Op.Id], "an op id was accepted twice on one session, so the same change would apply again")

	self.State = TableUtil.FreezeDelta(Ruling.Next)
	self.Landed = if Ruling.Also ~= nil then TableUtil.FreezeDelta(Ruling.Also) else nil
	self.StateBytes = Ruling.Bytes or self.StateBytes + OpBytes
	self.Applied[Op.Id] = true
	table.insert(self.Pending, Op)
	self.LogBytes += OpBytes + Rebuild.SEPARATOR
	self:Notify()
	return true, nil
end

function Session.CommitOp<S>(self: Session<S>, Op: Op): Future<boolean, Reason?>
	if not Validate.Op(Op) then
		warn("Ledger: rejected commit, an op needs a string Id and a string Kind")
		return Rejected(INVALID)
	end

	local Fine, Wrong = NewOp.Check(Op)
	if not Fine then
		warn(`Ledger: rejected commit '{Op.Kind}', {Wrong}`)
		return Rejected(INVALID)
	end

	local Ruling = Admit.Admit(self, Op, Measure(Op), true)
	if Ruling.Outcome == "Refused" then
		return Rejected(Ruling.Why)
	end

	return Future.New(function(): (boolean, Reason?)
		local Ok, Accepted, Stuck = pcall(function(): (boolean, boolean)
			Rebuild.Push(self)

			local Forgotten = false
			local Wrote = false
			local Maybe = false
			local function Land(): (Record, { string })
				local Written, _, Waiting, Doubted, Again = Rebuild.Roomed(self, { Op })
				Forgotten = #Doubted > 0
				Wrote = Wrote or TxStamp.Carries(Written, Op.Id)
				Maybe = Maybe or Again
				return self:Settled(Written), Waiting
			end

			local Stored, Waiting = Land()
			local Deadline = Clock.Now() + Windows.TX + Windows.POLL
			Stored = Unparked(self, Stored, Deadline)
			local Tries = 0
			while #Waiting > 0 and Tries < MAX_APPENDS and not TxStamp.HasPending(Stored) and Clock.Now() < Deadline do
				Tries += 1
				Stored, Waiting = Land()
				Stored = Unparked(self, Stored, Deadline)
			end

			local Blocked = TxStamp.HasPending(Stored)
			local Sure = true
			if Blocked then
				local _, Certain = self.Shape:Certain(Stored, Op.Id)
				Sure = Certain
			end

			if Forgotten then
				warn(
					`Ledger: commit '{Op.Kind}' was not written. its Id may have gone through already, and '{self.Key}' no longer keeps ids from when it was first sent. read the key to see whether it landed`
				)
			end

			local Faded = not TxStamp.Holds(Stored, Op.Id) and TxStamp.Carries(Stored, Op.Id)
			local _, Took = Rebuild.Rebuild(self, Stored, Op.Id)
			local Lost = not TxStamp.Carries(Stored, Op.Id) and (Wrote or Maybe and self.Stopped ~= nil)
			self:Notify()
			if Blocked and not (Took and Sure) then
				warn(`Ledger: commit '{Op.Kind}' answered while a transaction was parked on '{self.Key}', and that transaction can still change whether it applies. read the key once it settles`)
			end
			return Took and Sure, Blocked or Faded or Forgotten or Lost
		end)

		if not Ok then
			if Errors.Reason(Accepted) == FULL then
				warn(`Ledger: commit '{Op.Kind}' was not written, '{self.Key}' holds more unsaved ops than it can take even after compacting`)
				return false, FULL
			end
			warn(`Ledger: commit '{Op.Kind}' could not be written, though it might still have gone through: {Accepted}`)
			return false, UNRESOLVED
		end
		if Accepted then
			return true, nil
		end

		return false, if Stuck then UNRESOLVED else REFUSED
	end)
end

function Session.Commit<S>(self: Session<S>, Kind: string, Fields: { [any]: any }?): Future<boolean, Reason?>
	return Session.CommitOp(self, NewOp.New(Kind, Fields))
end

function Session.Flush<S>(self: Session<S>): Future<boolean, Reason?>
	return Future.New(function(): (boolean, Reason?)
		local Stopped = self.Stopped
		if Stopped ~= nil then
			return false, Stopped
		end

		local Whole = true
		local Ok, Err = pcall(function()
			local Pushed, Landed = Rebuild.Push(self)
			Whole = Landed ~= false

			local Stored = if Pushed ~= nil then Pushed else (self.Log:Read(self.Key))
			Rebuild.Rebuild(self, self:Settled(Stored))
			self:Notify()
		end)
		if Ok then
			if self.Stopped ~= nil then
				return false, self.Stopped
			end
			if not Whole then
				return false, REFUSED
			end
			return true, nil
		end

		local Why = Errors.Reason(Err)
		if Why == BEHIND then
			self.Released = true
			self.Stopped = Why
			warn(`Ledger: '{self.Key}' now needs a newer build than this server has, so this session is closed and its {#self.Pending} unsaved op(s) are not written. the player has to rejoin`)
			self.Pending = {}
			return false, Why
		end

		warn(`Ledger: flush for '{self.Key}' failed. its ops stay pending and the next flush picks them up: {Err}`)
		return false, Why
	end)
end

function Session.Compact<S>(self: Session<S>): Future<boolean, Reason?>
	return Future.New(function(): (boolean, Reason?)
		local Ok, Err = pcall(function()
			Rebuild.Push(self)
			Rebuild.Rebuild(self, self.Log:Compact(self.Key, self.Shape))
			self:Notify()
		end)
		if Ok then
			return self.Stopped == nil, self.Stopped
		end

		warn(`Ledger: compaction for '{self.Key}' failed, so its log just stays long for now: {Err}`)
		return false, Errors.Reason(Err)
	end)
end

function Session.Release<S>(self: Session<S>): Future<boolean, Reason?>
	return Future.New(function(): (boolean, Reason?)
		self.Released = true

		local Whole = true
		if self.Stopped == nil then
			local Ok, Err = pcall(function()
				local _, Landed = Rebuild.Push(self)
				Whole = Landed ~= false
			end)
			if not Ok then
				warn(`Ledger: final save for '{self.Key}' failed, so {#self.Pending} unsaved op(s) die with this server: {Err}`)
				return false, Errors.Reason(Err)
			end
		end

		local Stopped = self.Stopped
		if Stopped == REFUSED then
			warn(`Ledger: final save for '{self.Key}' wrote nothing, that key was erased while this session held it`)
		end
		if Stopped ~= nil then
			return false, Stopped
		end
		if not Whole then
			return false, REFUSED
		end
		if #self.Pending > 0 then
			warn(`Ledger: final save for '{self.Key}' left {#self.Pending} op(s) unwritten. they were waiting on a transaction parked on that key and die with this server`)
		end
		return true, nil
	end)
end

table.freeze(Session)

return table.freeze({
	Load = Load,
	MAX_PENDING = MAX_PENDING,
})
