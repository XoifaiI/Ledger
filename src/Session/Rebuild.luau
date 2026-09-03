--!strict
--!optimize 2

--[=[

	Rebuild: Pushes the queued ops to the log, and builds the state again.

	Push reads back which ops actually landed rather than trusting the call that returned. Append
	carries the fence, which is the erase mark the key had at load. A write lands only while that mark
	is unchanged or has run out, and Fenced drops a mark that has.

	The sift folds the record with and without any parked leg. An op that holds one way but not the
	other stays queued until the leg settles. Rebuild folds the record that came back and puts the
	still queued ops on top. It counts the log the way the record's own cap counts it, as an array
	with a separator after each op.

	Return type: A table with Fenced, Append, Push, Rebuild, ApplyPending, SumBytes and SEPARATOR.
	Example usage:
		local Rebuild = require("./Rebuild")
		local Stored, Whole = Rebuild.Push(Active)
--]=]

local TableUtil = require("../Util/TableUtil")
local Shapes = require("../Core/Shapes")
local Errors = require("../Core/Errors")
local Reasons = require("../Core/Constants/Reasons")
local Sizes = require("../Core/Constants/Sizes")
local Measure = require("../Encode/Measure")
local Compact = require("../Record/Compact")
local Rules = require("../Record/Rules")
local Fold = require("../Record/Fold")
local Schema = require("../Record/Schema")
local TxStamp = require("../Record/TxStamp")
local Apply = require("../Record/Apply")
local Types = require("./Types")

type Op = Shapes.Op
type Record = Shapes.Record<any>
type Session<S> = Types.Session<S>

local AUDITING = game:GetService("RunService"):IsStudio()

local SEPARATOR = 1

local function SumBytes(Ops: { Op }): number
	local Total = 0
	for _, Op in Ops do
		Total += Measure(Op) + SEPARATOR
	end
	return Total
end

local function ApplyPending<S>(self: Session<S>, State: S, Applied: { [string]: boolean }): S
	for _, Op in self.Pending do
		if Applied[Op.Id] then
			continue
		end
		Applied[Op.Id] = true
		local Next = Apply(self.Shape.Reducer, State, Op)
		if Next ~= nil then
			State = Next
		end
	end
	return State
end

local function Sifted<S>(self: Session<S>): (Record) -> (Op) -> boolean?
	local Format = self.Shape

	return function(Record: Record)
		local State = Format:Fold(Schema.Detached(Record))
		local Landed: S? = nil
		if TxStamp.HasPending(Record) then
			local Committed = Schema.Detached(Record)
			Committed.Ops = TxStamp.Landed(Record.Ops, nil)
			Landed = Format:Fold(Committed)
		end

		return function(Op: Op): boolean?
			local Next = Apply(Format.Reducer, State, Op)
			if Landed ~= nil then
				local Also = Apply(Format.Reducer, Landed, Op)
				if (Next == nil) ~= (Also == nil) then
					return nil
				end
				if Also ~= nil then
					Landed = Also
				end
			end
			if Next == nil then
				return false
			end
			State = Next
			return true
		end
	end
end

local function Fenced(Erased: number?): number?
	if Erased == nil or not Rules.Entombed({ Ops = {}, Seen = {}, Erased = Erased }) then
		return nil
	end
	return Erased
end

local function Append<S>(self: Session<S>, Ops: { Op }): (Record, { string }, { string })
	local Fence = self.Fence
	return self.Log:Append(self.Key, Ops, function(Record: Record): boolean
		return Record.Erased == Fence or (not Rules.Entombed(Record) and Fenced(Fence) == nil)
	end, Sifted(self))
end

local function Roomed<S>(self: Session<S>, Batch: { Op }): (Record, { string }, { string })
	local Ok, Stored, Turned, Waiting = pcall(function(): (Record, { string }, { string })
		return Append(self, Batch)
	end)
	if Ok then
		return Stored, Turned, Waiting
	end
	if Errors.Reason(Stored) ~= Reasons.Full then
		error(Stored, 0)
	end

	self.Log:Compact(self.Key, self.Shape)
	return Append(self, Batch)
end

local function Push<S>(self: Session<S>): (Record?, boolean?)
	local Count = #self.Pending
	if Count == 0 then
		return nil, true
	end

	local Batch = table.move(self.Pending, 1, Count, 1, {})
	local Stored, Turned, Waiting = Roomed(self, Batch)

	local Landed: { [string]: boolean } = {}
	for _, Op in Stored.Ops do
		Landed[Op.Id] = true
	end
	for _, Id in Stored.Seen do
		Landed[Id] = true
	end
	local Dropped: { [string]: boolean } = {}
	for _, Id in Turned do
		Dropped[Id] = true
	end

	local Held: { [string]: boolean } = {}
	for _, Id in Waiting do
		Held[Id] = true
	end

	local Kept: { Op } = {}
	for _, Op in self.Pending do
		if not Landed[Op.Id] and not Dropped[Op.Id] then
			table.insert(Kept, Op)
		end
	end
	self.Pending = Kept

	local Missed = 0
	for _, Op in Batch do
		if not Landed[Op.Id] and not Held[Op.Id] then
			Missed += 1
		end
	end
	assert(Missed <= Count, "a push lost more ops than it was given, so one was counted twice")

	if Missed == Count and #Turned == 0 and Stored.Erased ~= self.Fence then
		self.Released = true
		warn(`Ledger: '{self.Key}' was erased while this session was live, so its {Count} unsaved op(s) were not written. the session is closed and this player needs to rejoin`)
	end

	self.LogSize = #Stored.Ops
	return Stored, Missed == 0
end

local function Diverged(Live: any, Folded: any, Path: string): string?
	if Live == Folded then
		return nil
	end
	if type(Live) == "buffer" and type(Folded) == "buffer" then
		return if buffer.tostring(Live) == buffer.tostring(Folded) then nil else `{Path} holds different bytes live and refolded`
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

local function CheckPurity<S>(self: Session<S>, Stored: Record, Base: S, Folded: S)
	if not AUDITING or #Stored.Ops == 0 then
		return
	end

	local Again = Fold(Base, Stored.Ops, self.Shape.Reducer)
	local Where = Diverged(Folded, Again, "state")
	if Where == nil then
		return
	end

	warn(
		`Ledger: the reducer for '{self.Key}' is not deterministic, so two servers would fold this log differently. replaying the same ops changed {Where}. read only the two arguments, and pass os.time or math.random in on the op instead`
	)
end

local function Rebuild<S>(self: Session<S>, Stored: Record, Mark: string?): (S, boolean)
	self.Fence = Fenced(self.Fence)
	local Base: S = self.Shape:Rehydrate(Stored)
	local State, Accepted = Fold(Base, Stored.Ops, self.Shape.Reducer, Mark)
	local Applied: { [string]: boolean } = {}
	local Written: { [string]: boolean } = {}
	local Waiting: { [string]: boolean } = {}
	local Parked = 0
	for _, Op in Stored.Ops do
		Written[Op.Id] = true
		if Op.Tx == nil then
			Applied[Op.Id] = true
		elseif type(Op.Tx) == "string" and not Waiting[Op.Tx] then
			Waiting[Op.Tx] = true
			Parked += 1
		end
	end

	CheckPurity(self, Stored, Base, State)

	State = ApplyPending(self, State, Applied)

	self.State = TableUtil.FreezeDelta(State)
	self.Parked = Parked
	self.Landed = if Parked == 1 then TableUtil.FreezeDelta(ApplyPending(self, Fold(Base, TxStamp.Landed(Stored.Ops, next(Waiting) :: string), self.Shape.Reducer), {})) else nil
	self.Applied = Applied
	self.LogSize = #Stored.Ops
	self.LogBytes = Measure(Stored.Ops) + SumBytes(self.Pending)

	local Reach = Compact.Bulk(Stored) + self.LogBytes
	self.StateBytes = if Reach > Sizes.StateFloor then Measure(State) else Reach

	for _, Op in self.Pending do
		assert(not Written[Op.Id], `op {Op.Id} is queued and already in the log for '{self.Key}', so it would be counted and folded twice`)
	end

	return State, Accepted
end

return table.freeze({
	Fenced = Fenced,
	Append = Append,
	Push = Push,
	Rebuild = Rebuild,
	ApplyPending = ApplyPending,
	SumBytes = SumBytes,
	SEPARATOR = SEPARATOR,
})
