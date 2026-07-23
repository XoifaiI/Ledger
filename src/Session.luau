--!strict
--!optimize 2

--[=[
    Session: per player authority, folds live state from the log on load.

    Apply mutates state optimistically for gameplay, Commit is the authoritative path whose
    result you gate an external side effect on. the state a session holds and hands out is
    deep frozen everywhere, so a consumer or reducer that mutates instead of cloning throws
    at the mutation site instead of corrupting shared state. the freeze is FreezeDelta:
    unchanged children are already frozen from the previous state, so each transition only
    pays for the path the reducer actually cloned.

    Return type: frozen table { Load }
    Example usage:
        local Session = require("./Session")
        local Active = Session.Load(Wrapper, Key, Reducer, Initial):Wait()
        Active:Apply("AddGold", { Amount = 10 })
--]=]

local Future = require("./Util/Future")
local NoYield = require("./Util/NoYield")
local Observer = require("./Util/Observer")
local TableUtil = require("./Util/TableUtil")
local DataStoreWrapper = require("./Util/DataStoreWrapper")
local Log = require("./Log")
local Tx = require("./Tx")
local MakeOp = require("./MakeOp")
local Measure = require("./Measure")
local IsStorable = require("./Storable")
local Types = require("./Types")

type Op = Types.Op
type Record<S> = Types.Record<S>
type Reducer<S> = Types.Reducer<S>
type Future<T...> = Future.Future<T...>
type Observer<T> = Observer.Observer<T>
type Subject<T> = Observer.Subject<T>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type SessionImpl<S> = Types.SessionImpl<S>

export type Session<S> = Types.Session<S>

local MAX_STATE_BYTES = 2 * 1024 * 1024

local MAX_LOG_BYTES = 1536 * 1024

local MAX_PENDING = 4096

local PENDING_WAIT_ATTEMPTS = 15
local PENDING_WAIT_DELAY = 5

local function Guard<S>(State: S): S
	return TableUtil.FreezeDelta(State)
end

local Session = {}
Session.__index = Session

local function SumBytes(Ops: { Op }): number
	local Total = 0
	for _, Op in Ops do
		Total += Measure(Op)
	end
	return Total
end

local function Step<S>(Reducer: Reducer<S>, State: S, Op: Op): S?
	local Ok, Next = pcall(NoYield, Reducer, State, Op)
	return if Ok and type(Next) == "table" then Next else nil
end

local function ApplyPending<S>(self: Session<S>, State: S, Applied: { [string]: boolean }): S
	for _, Op in self.Pending do
		if Applied[Op.Id] then
			continue
		end
		Applied[Op.Id] = true
		local Next = Step(self.Reducer, State, Op)
		if Next ~= nil then
			State = Next
		end
	end
	return State
end

local function Push<S>(self: Session<S>): Record<any>?
	local Count = #self.Pending
	if Count == 0 then
		return nil
	end

	local Batch = table.move(self.Pending, 1, Count, 1, {})
	local Stored = Log.Append(self.Wrapper, self.Key, Batch)

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
	self.Pending = Kept

	self.LogSize = #Stored.Ops
	return Stored
end

local function Rebuild<S>(self: Session<S>, Stored: Record<any>, Mark: string?): (S, boolean)
	local State: S = Log.Rehydrate(Stored, self.Initial, self.Migrations)
	local Applied: { [string]: boolean } = {}
	local Accepted = false

	for _, Op in Stored.Ops do
		if Op.Tx ~= nil then
			continue
		end
		Applied[Op.Id] = true
		local Next = Step(self.Reducer, State, Op)
		if Next ~= nil then
			State = Next
			if Op.Id == Mark then
				Accepted = true
			end
		end
	end

	State = ApplyPending(self, State, Applied)

	self.State = Guard(State)
	self.Applied = Applied
	self.LogSize = #Stored.Ops
	self.LogBytes = SumBytes(Stored.Ops) + SumBytes(self.Pending)
	return State, Accepted
end

local function Notify<S>(self: Session<S>)
	self.Changed:Push(self.State)
end

local function SettlePending<S>(self: Session<S>, Stored: Record<any>): Record<any>
	local TxStore = self.TxStore
	if TxStore and Log.HasPending(Stored) then
		return Tx.Settle(self.Wrapper, TxStore, self.Key, Stored)
	end
	return Stored
end

function Session.Get<S>(self: Session<S>): S
	return self.State
end

function Session.Observe<S>(self: Session<S>): Observer<S>
	return self.Changed
end

local function Admit<S>(self: Session<S>, Op: Op): (boolean, S?)
	if self.Released then
		warn(`Ledger: rejected op '{Op.Kind}', the session was already released (the player left)`)
		return false, nil
	end

	if self.LogBytes + Measure(Op) > MAX_LOG_BYTES then
		warn(`Ledger: rejected op '{Op.Kind}', the unsaved op backlog is at the {MAX_LOG_BYTES} byte cap (a datastore outage is likely blocking saves)`)
		return false, nil
	end

	local Next = NoYield(self.Reducer, self.State, Op)
	if Next ~= nil and type(Next) ~= "table" then
		warn(`Ledger: rejected op '{Op.Kind}', the reducer returned a {typeof(Next)} instead of the next state table`)
		return false, nil
	end
	if Next ~= nil then
		local Bytes = Measure(Next)
		if Bytes > MAX_STATE_BYTES and Bytes > Measure(self.State) then
			warn(`Ledger: rejected op '{Op.Kind}', the profile is at the {MAX_STATE_BYTES} byte cap and this op would grow it`)
			return false, nil
		end
	end

	return true, Next
end

function Session.Apply<S>(self: Session<S>, Kind: string, Fields: { [any]: any }?): boolean
	if #self.Pending >= MAX_PENDING then
		warn(`Ledger: rejected op '{Kind}', {MAX_PENDING} ops are already pending (a datastore outage is likely blocking saves)`)
		return false
	end

	local Op = MakeOp(Kind, Fields)

	local Storable, Reason = IsStorable.Op(Op)
	if not Storable then
		warn(`Ledger: rejected op '{Kind}', {Reason}`)
		return false
	end

	local Admitted, Next = Admit(self, Op)
	if not Admitted or Next == nil then
		return false
	end

	self.State = Guard(Next)
	self.Applied[Op.Id] = true
	table.insert(self.Pending, Op)
	self.LogBytes += Measure(Op)
	Notify(self)
	return true
end

function Session.CommitOp<S>(self: Session<S>, Op: Op): Future<boolean>
	if type(Op) ~= "table" or type(Op.Id) ~= "string" or #Op.Id == 0 or type(Op.Kind) ~= "string" or #Op.Kind == 0 then
		warn("Ledger: rejected commit, an op needs a string Id and a string Kind")
		return Future.Completed(false)
	end

	local Storable, Reason = IsStorable.Op(Op)
	if not Storable then
		warn(`Ledger: rejected commit '{Op.Kind}', {Reason}`)
		return Future.Completed(false)
	end

	local Admitted = Admit(self, Op)
	if not Admitted then
		return Future.Completed(false)
	end

	return Future.New(function(): boolean
		Push(self)

		local Stored = SettlePending(self, Log.Append(self.Wrapper, self.Key, { Op }))
		for _ = 1, PENDING_WAIT_ATTEMPTS do
			if not Log.HasPending(Stored) then
				break
			end
			task.wait(PENDING_WAIT_DELAY)
			Stored = SettlePending(self, Log.Read(self.Wrapper, self.Key))
		end
		if Log.HasPending(Stored) then
			warn(`Ledger: commit '{Op.Kind}' settled against a record with a stuck transaction leg, its verdict may flip when that leg resolves`)
		end

		local _, Accepted = Rebuild(self, Stored, Op.Id)
		Notify(self)
		return Accepted
	end)
end

function Session.Commit<S>(self: Session<S>, Kind: string, Fields: { [any]: any }?): Future<boolean>
	return Session.CommitOp(self, MakeOp(Kind, Fields))
end

function Session.Flush<S>(self: Session<S>): Future<()>
	return Future.New(function()
		local Stored = SettlePending(self, Push(self) or Log.Read(self.Wrapper, self.Key))
		Rebuild(self, Stored)
		Notify(self)
	end)
end

function Session.Compact<S>(self: Session<S>): Future<()>
	return Future.New(function()
		Push(self)

		local Stored = Log.Compact(self.Wrapper, self.Key, self.Reducer, self.Initial, self.Migrations)
		if #Stored.Ops > 0 then
			Rebuild(self, Stored)
			Notify(self)
			return
		end

		local Base: S = if Stored.Snapshot == nil then self.Initial else Stored.Snapshot :: S
		table.clear(self.Applied)
		self.State = Guard(ApplyPending(self, Base, self.Applied))
		self.LogSize = 0
		self.LogBytes = SumBytes(self.Pending)
		Notify(self)
	end)
end

function Session.Release<S>(self: Session<S>): Future<()>
	return Future.New(function()
		self.Released = true
		Push(self)
	end)
end

local function Load<S>(
	Wrapper: DataStoreWrapper,
	Key: string,
	Reducer: Reducer<S>,
	Initial: S,
	Migrations: { Types.Migration }?,
	TxStore: DataStoreWrapper?
): Future<Session<S>>
	return Future.New(function(): Session<S>
		local Body = {
			Wrapper = Wrapper,
			Key = Key,
			Reducer = Reducer,
			Migrations = Migrations or {},
			TxStore = TxStore,
			Initial = Initial,
			State = Initial,
			Applied = {},
			Pending = {},
			LogSize = 0,
			LogBytes = 0,
			Changed = Observer.New(),
			Released = false,
		}

		local Active: Session<S> = setmetatable(Body :: any, Session) :: any
		Rebuild(Active, SettlePending(Active, Log.Read(Wrapper, Key)))
		return Active
	end)
end

table.freeze(Session)

return table.freeze({
	Load = Load,
})
