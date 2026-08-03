--!strict
--!optimize 2

-- per player authority, folds live state from the log on load. Apply is optimistic, Commit is durable before it answers

local Future = require("./Util/Future")
local NoYield = require("./Util/NoYield")
local Observer = require("./Util/Observer")
local TableUtil = require("./Util/TableUtil")
local DataStoreWrapper = require("./Util/DataStoreWrapper")
local Fault = require("./Fault")
local Dedupe = require("./Record/Dedupe")
local Fold = require("./Record/Fold")
local Log = require("./Record/Log")
local Tx = require("./Tx")
local MakeOp = require("./Record/MakeOp")
local Measure = require("./Record/Measure")
local Reasons = require("./Reason")
local Step = require("./Record/Step")
local IsStorable = require("./Record/Storable")
local Types = require("./Types")

type Op = Types.Op
type Record<S> = Types.Record<S>
type Reason = Types.Reason
type Future<T...> = Future.Future<T...>
type Observer<T> = Observer.Observer<T>
type Subject<T> = Observer.Subject<T>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type SessionImpl<S> = Types.SessionImpl<S>
type Admitted<S> = Types.Admitted<S>

export type Session<S> = Types.Session<S>

local MAX_STATE_BYTES = 2 * 1024 * 1024
local MAX_OP_BYTES = 1024 * 1024
local STATE_CHECK_FLOOR = MAX_STATE_BYTES - MAX_OP_BYTES

local MAX_LOG_BYTES = Log.MAX_LOG_BYTES
local MAX_PENDING = 4096
local PENDING_POLL = 5

local AUDITING = game:GetService("RunService"):IsStudio()

local REFUSED = Reasons.Refused
local BUSY = Reasons.Busy
local CLOSED = Reasons.Closed
local BACKLOG = Reasons.Backlog
local FULL = Reasons.Full
local INVALID = Reasons.Invalid
local UNRESOLVED = Reasons.Unresolved

local function Guard<S>(State: S): S
	return TableUtil.FreezeDelta(State)
end

local function Rejected(Why: Reason?): Future<boolean, Reason?>
	return Future.Completed(false, Why)
end

local Session = {} :: SessionImpl<any>
Session.__index = Session

local function SumBytes(Ops: { Op }): number
	local Total = 0
	for _, Op in Ops do
		Total += Measure(Op)
	end
	return Total
end

function Session.ApplyPending<S>(self: Session<S>, State: S, Applied: { [string]: boolean }): S
	for _, Op in self.Pending do
		if Applied[Op.Id] then
			continue
		end
		Applied[Op.Id] = true
		local Next = Step(self.Shape.Reducer, State, Op)
		if Next ~= nil then
			State = Next
		end
	end
	return State
end

function Session.Push<S>(self: Session<S>): Record<any>?
	local Count = #self.Pending
	if Count == 0 then
		return nil
	end

	local Batch = table.move(self.Pending, 1, Count, 1, {})
	local Stored = self.Log:Append(self.Key, Batch)

	local InBatch: { [Op]: boolean } = {}
	for _, Op in Batch do
		InBatch[Op] = true
	end

	local Kept: { Op } = {}
	for _, Op in self.Pending do
		if not InBatch[Op] then
			table.insert(Kept, Op)
		end
	end
	assert(#Kept <= #self.Pending - Count, "a push kept more ops than it started with, so one was queued twice")
	self.Pending = Kept

	self.LogSize = #Stored.Ops
	return Stored
end

local function Diverged(Live: any, Folded: any, Path: string): string?
	if Live == Folded then
		return nil
	end
	if type(Live) == "buffer" and type(Folded) == "buffer" then
		return if buffer.tostring(Live) == buffer.tostring(Folded)
			then nil
			else `{Path} holds different bytes live and refolded`
	end
	if type(Live) ~= "table" or type(Folded) ~= "table" then
		return `{Path} is {tostring(Live)} live and {tostring(Folded)} refolded`
	end

	for Key, Value in Live do
		local Where = Diverged(Value, Folded[Key], `{Path}.{tostring(Key)}`)
		if Where ~= nil then
			return Where
		end
	end
	for Key in Folded do
		if Live[Key] == nil then
			return `{Path}.{tostring(Key)} exists only in the refold`
		end
	end
	return nil
end

function Session.CheckPurity<S>(self: Session<S>, Stored: Record<any>, Folded: S)
	if not AUDITING or self.LogSize == 0 then
		return
	end

	for _, Op in Stored.Ops do
		if Op.Tx == nil and not self.Applied[Op.Id] then
			return
		end
	end

	local Where = Diverged(self.State, Folded, "state")
	if Where == nil then
		return
	end

	warn(
		`Ledger: the reducer for '{self.Key}' is not deterministic, so two servers would fold this log differently. replaying the same ops changed {Where}. read only the two arguments, and pass os.time or math.random in on the op instead`
	)
end

function Session.Rebuild<S>(self: Session<S>, Stored: Record<any>, Mark: string?): (S, boolean)
	local Base: S = self.Shape:Rehydrate(Stored)
	local State, Accepted = Fold(Base, Stored.Ops, self.Shape.Reducer, Mark)
	local Applied: { [string]: boolean } = {}
	for _, Op in Stored.Ops do
		if Op.Tx == nil then
			Applied[Op.Id] = true
		end
	end

	State = self:ApplyPending(State, Applied)

	self:CheckPurity(Stored, State)

	self.State = Guard(State)
	self.Landed = if Log.HasPending(Stored)
		then Guard(self:ApplyPending(Fold(self.Shape:Rehydrate(Stored), Log.Landed(Stored.Ops), self.Shape.Reducer), {}))
		else nil
	self.StateBytes = Measure(State)
	self.Applied = Applied
	self.LogSize = #Stored.Ops
	self.LogBytes = SumBytes(Stored.Ops) + SumBytes(self.Pending)

	local Written: { [string]: boolean } = {}
	for _, Op in Stored.Ops do
		Written[Op.Id] = true
	end
	for _, Op in self.Pending do
		assert(not Written[Op.Id], `op {Op.Id} is queued and already in the log for '{self.Key}', so it would be counted and folded twice`)
	end

	return State, Accepted
end

function Session.Notify<S>(self: Session<S>)
	self.Changed:Push(self.State)
end

function Session.SettlePending<S>(self: Session<S>, Stored: Record<any>): Record<any>
	local TxStore = self.TxStore
	if TxStore and Log.HasPending(Stored) then
		return Tx.Settle(self.Log, TxStore, self.Key, Stored)
	end
	return Stored
end

function Session.Settled<S>(self: Session<S>, Stored: Record<any>): Record<any>
	local Ok, Resolved = pcall(function(): Record<any>
		return self:SettlePending(Stored)
	end)
	if Ok then
		return Resolved
	end
	warn(`Ledger: could not settle a pending transaction leg on '{self.Key}', so this fold leaves it out for now: {Resolved}`)
	return Stored
end

function Session.Get<S>(self: Session<S>): S
	return self.State
end

function Session.Observe<S>(self: Session<S>): Observer<S>
	return self.Changed
end

function Session.DidApply<S>(self: Session<S>, Id: string): boolean
	assert(type(Id) == "string" and #Id > 0, "DidApply needs the same Once name the op was written under")
	return Dedupe.Has((self.State :: any)._Received, Dedupe.ONCE, Id)
end

function Session.Admit<S>(self: Session<S>, Op: Op, OpBytes: number, Durable: boolean?): Admitted<S>
	if self.Released then
		warn(`Ledger: rejected op '{Op.Kind}', that session closed when the player left`)
		return { Outcome = "Refused", Why = CLOSED }
	end

	if self.LogBytes + OpBytes > MAX_LOG_BYTES then
		if self.Landed ~= nil then
			warn(
				`Ledger: rejected op '{Op.Kind}', '{self.Key}' has hit the {MAX_LOG_BYTES} byte cap and cannot shrink while a transaction is parked on it. it clears once that settles`
			)
			return { Outcome = "Refused", Why = BUSY }
		end
		warn(`Ledger: rejected op '{Op.Kind}', unsaved ops have hit the {MAX_LOG_BYTES} byte cap. saves are not going through, check the datastore`)
		return { Outcome = "Refused", Why = BACKLOG }
	end

	local Next = NoYield(self.Shape.Reducer, self.State, Op)
	if Next ~= nil and type(Next) ~= "table" then
		warn(`Ledger: rejected op '{Op.Kind}', your reducer handed back a {typeof(Next)} instead of the next state table`)
		return { Outcome = "Refused", Why = INVALID }
	end
	if Next == nil then
		return { Outcome = "Rejected" }
	end

	assert(Next ~= self.State, `your reducer handed back the very table it was given for op '{Op.Kind}', so it changed live state in place`)

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

function Session.Apply<S>(self: Session<S>, Kind: string, Fields: { [any]: any }?): (boolean, Reason?)
	if #self.Pending >= MAX_PENDING then
		warn(`Ledger: rejected op '{Kind}', {MAX_PENDING} ops are already pending. saves are not going through, check the datastore`)
		return false, BACKLOG
	end

	local Op = MakeOp.New(Kind, Fields)

	local Named, Unnamed = MakeOp.Stamp(Op)
	if not Named then
		warn(`Ledger: rejected op '{Kind}', {Unnamed}`)
		return false, INVALID
	end

	local Storable, Unstorable = IsStorable.Op(Op)
	if not Storable then
		warn(`Ledger: rejected op '{Kind}', {Unstorable}`)
		return false, INVALID
	end

	local OpBytes = Measure(Op)
	local Ruling = self:Admit(Op, OpBytes)
	if Ruling.Outcome == "Refused" then
		return false, Ruling.Why
	end
	if Ruling.Outcome == "Rejected" then
		return false, REFUSED
	end

	assert(not self.Applied[Op.Id], "an op id was accepted twice on one session, so the same change would apply again")

	self.State = Guard(Ruling.Next)
	self.Landed = if Ruling.Also ~= nil then Guard(Ruling.Also) else nil
	self.StateBytes = Ruling.Bytes or self.StateBytes + OpBytes
	self.Applied[Op.Id] = true
	table.insert(self.Pending, Op)
	self.LogBytes += OpBytes
	self:Notify()

	assert(#self.Pending <= MAX_PENDING, "more ops are queued than the cap allows, so the backlog guard let one through")
	return true, nil
end

function Session.CommitOp<S>(self: Session<S>, Op: Op): Future<boolean, Reason?>
	if type(Op) ~= "table" or type(Op.Id) ~= "string" or #Op.Id == 0 or type(Op.Kind) ~= "string" or #Op.Kind == 0 then
		warn("Ledger: rejected commit, an op needs a string Id and a string Kind")
		return Rejected(INVALID)
	end

	local Named, Unnamed = MakeOp.Stamp(Op)
	if not Named then
		warn(`Ledger: rejected commit '{Op.Kind}', {Unnamed}`)
		return Rejected(INVALID)
	end

	local Storable, Unstorable = IsStorable.Op(Op)
	if not Storable then
		warn(`Ledger: rejected commit '{Op.Kind}', {Unstorable}`)
		return Rejected(INVALID)
	end

	local Ruling = self:Admit(Op, Measure(Op), true)
	if Ruling.Outcome == "Refused" then
		return Rejected(Ruling.Why)
	end

	return Future.New(function(): (boolean, Reason?)
		local Ok, Accepted, Stuck = pcall(function(): (boolean, boolean)
			self:Push()

			local Stored = self:Settled(self.Log:Append(self.Key, { Op }))
			local Deadline = os.clock() + Tx.TIMEOUT + PENDING_POLL
			while Log.HasPending(Stored) and os.clock() < Deadline do
				task.wait(PENDING_POLL)
				Stored = self:Settled(self.Log:Read(self.Key))
			end

			local Blocked = Log.HasPending(Stored)
			if Blocked then
				warn(`Ledger: commit '{Op.Kind}' answered while a transaction was stuck on the record, so this answer can change once that clears`)
			end

			local _, Took = self:Rebuild(Stored, Op.Id)
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
	return Session.CommitOp(self, MakeOp.New(Kind, Fields))
end

function Session.Flush<S>(self: Session<S>): Future<boolean, Reason?>
	return Future.New(function(): (boolean, Reason?)
		local Ok, Err = pcall(function()
			local Stored = self:Settled(self:Push() or self.Log:Read(self.Key))
			self:Rebuild(Stored)
			self:Notify()
		end)
		if Ok then
			return true, nil
		end

		warn(`Ledger: flush for '{self.Key}' failed. its ops stay pending and the next flush picks them up: {Err}`)
		return false, Fault.Named(Err)
	end)
end

function Session.Compact<S>(self: Session<S>): Future<boolean, Reason?>
	return Future.New(function(): (boolean, Reason?)
		local Ok, Err = pcall(function()
			self:Push()

			local Stored = self.Log:Compact(self.Key, self.Shape)
			if #Stored.Ops > 0 then
				self:Rebuild(Stored)
				self:Notify()
				return
			end

			local Base: S = self.Shape:Rehydrate(Stored)
			table.clear(self.Applied)
			self.State = Guard(self:ApplyPending(Base, self.Applied))
			self.Landed = nil
			self.StateBytes = Measure(self.State)
			self.LogSize = 0
			self.LogBytes = SumBytes(self.Pending)
			self:Notify()
		end)
		if Ok then
			return true, nil
		end

		warn(`Ledger: compaction for '{self.Key}' failed, so its log just stays long for now: {Err}`)
		return false, Fault.Named(Err)
	end)
end

function Session.Release<S>(self: Session<S>): Future<boolean, Reason?>
	return Future.New(function(): (boolean, Reason?)
		self.Released = true

		local Ok, Err = pcall(function()
			self:Push()
		end)
		if Ok then
			return true, nil
		end

		warn(`Ledger: final save for '{self.Key}' failed, so {#self.Pending} unsaved op(s) die with this server: {Err}`)
		return false, Fault.Named(Err)
	end)
end

local function Load<S>(Records: Log.Log, Format: Log.Shape<S>, Key: string, TxStore: DataStoreWrapper?): Future<Session<S>?, Reason?>
	return Future.New(function(): (Session<S>?, Reason?)
		local Body = {
			Log = Records,
			Shape = Format,
			Key = Key,
			TxStore = TxStore,
			State = Format.Initial,
			Landed = nil,
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
			Active:Rebuild(Active:Settled(Records:Read(Key)))
		end)
		if not Ok then
			warn(`Ledger: could not load '{Key}': {Reason}`)
			return nil, Fault.Named(Reason)
		end

		return Active, nil
	end)
end

table.freeze(Session)

return table.freeze({
	Load = Load
})
