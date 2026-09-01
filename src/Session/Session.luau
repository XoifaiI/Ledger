--!strict
--!optimize 2

--[=[

	Session: One player and one key, with the state folded from the log.

	Apply is hopeful: it folds against live state, answers at once, and queues the op. Commit writes
	before it answers. Flush pushes what is queued, Compact folds the log into a snapshot, and Release
	is the last save on the way out. The fence is taken on load and dropped once the erase it marks
	has run out.

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

local REFUSED = Reasons.Refused
local BACKLOG = Reasons.Backlog
local INVALID = Reasons.Invalid
local UNRESOLVED = Reasons.Unresolved
local BEHIND = Reasons.Behind

local function Rejected(Why: Reason?): Future<boolean, Reason?>
	return Future.Completed(false, Why)
end

local Session = {} :: Types.SessionImpl<any>
Session.__index = Session

local function SettlePending<S>(self: Session<S>, Stored: Record): Record
	local TxStore = self.TxStore
	if TxStore and TxStamp.HasPending(Stored) then
		return Tx.Settle(self.Log, TxStore, self.Key, Stored)
	end
	return Stored
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
		}

		local Active: Session<S> = setmetatable(Body :: any, Session) :: any
		local Ok, Reason = pcall(function()
			local Stored = Active:Settled(Records:Read(Key))
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
	local Ok, Resolved = pcall(function(): Record
		return SettlePending(self, Stored)
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

	assert(#self.Pending <= MAX_PENDING, "more ops are queued than the cap allows, so the backlog guard let one through")
	return true, nil
end

function Session.CommitOp<S>(self: Session<S>, Op: Op): Future<boolean, Reason?>
	if type(Op) ~= "table" or type(Op.Id) ~= "string" or #Op.Id == 0 or type(Op.Kind) ~= "string" or #Op.Kind == 0 then
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

			local Written, _, Waiting = Rebuild.Append(self, { Op })
			local Stored = self:Settled(Written)
			local Deadline = Clock.Now() + Windows.TX + Windows.POLL
			while true do
				local Pending = TxStamp.HasPending(Stored)
				if not Pending and #Waiting > 0 and Clock.Now() < Deadline then
					Written, _, Waiting = Rebuild.Append(self, { Op })
					Stored = self:Settled(Written)
					continue
				end
				if not Pending or Clock.Now() >= Deadline then
					break
				end
				Clock.Wait(Windows.POLL)
				Stored = self:Settled(self.Log:Read(self.Key))
			end

			local Blocked = TxStamp.HasPending(Stored)
			if Blocked then
				warn(`Ledger: commit '{Op.Kind}' answered while a transaction was stuck on '{self.Key}'. this answer can change once that clears`)
			end

			local _, Took = Rebuild.Rebuild(self, Stored, Op.Id)
			self:Notify()
			return Took, Blocked
		end)

		if not Ok then
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
		local Whole = true
		local Ok, Err = pcall(function()
			local Pushed, Landed = Rebuild.Push(self)
			Whole = Landed ~= false
			local Stored = self:Settled(Pushed or self.Log:Read(self.Key))
			Rebuild.Rebuild(self, Stored)
			self:Notify()
		end)
		if Ok then
			if not Whole then
				return false, REFUSED
			end
			return true, nil
		end

		local Why = Errors.Reason(Err)
		if Why == BEHIND then
			self.Released = true
			warn(`Ledger: '{self.Key}' now needs a newer build than this server has, so this session is closed and its {#self.Pending} unsaved op(s) are not written. the player has to rejoin`)
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

			local Stored = self.Log:Compact(self.Key, self.Shape)
			if #Stored.Ops > 0 then
				Rebuild.Rebuild(self, Stored)
				self:Notify()
				return
			end

			local Base: S = self.Shape:Rehydrate(Stored)
			table.clear(self.Applied)
			self.State = TableUtil.FreezeDelta(Rebuild.ApplyPending(self, Base, self.Applied))
			self.Landed = nil
			self.Parked = 0
			self.StateBytes = Measure(self.State)
			self.LogSize = 0
			self.LogBytes = Measure(Stored.Ops) + Rebuild.SumBytes(self.Pending)
			self:Notify()
		end)
		if Ok then
			return true, nil
		end

		warn(`Ledger: compaction for '{self.Key}' failed, so its log just stays long for now: {Err}`)
		return false, Errors.Reason(Err)
	end)
end

function Session.Release<S>(self: Session<S>): Future<boolean, Reason?>
	return Future.New(function(): (boolean, Reason?)
		self.Released = true

		local Whole = true
		local Ok, Err = pcall(function()
			local _, Landed = Rebuild.Push(self)
			Whole = Landed ~= false
		end)
		if Ok then
			if not Whole then
				warn(`Ledger: final save for '{self.Key}' wrote nothing, that key was erased while this session held it`)
				return false, REFUSED
			end
			if #self.Pending > 0 then
				warn(`Ledger: final save for '{self.Key}' left {#self.Pending} op(s) unwritten. they were waiting on a transaction parked on that key and die with this server`)
			end
			return true, nil
		end

		warn(`Ledger: final save for '{self.Key}' failed, so {#self.Pending} unsaved op(s) die with this server: {Err}`)
		return false, Errors.Reason(Err)
	end)
end

table.freeze(Session)

return table.freeze({
	Load = Load,
	MAX_PENDING = MAX_PENDING,
})
