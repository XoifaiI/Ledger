--!strict
--!optimize 2

--[=[
	Rebuild: Pushes the queued ops to the log, and builds the state again.
	
	Push reads back which ops landed, and does not trust the call that returned. Another server can
	write some of them first, and the guard can refuse the write.
	The fence is the erase mark that the key had when this session loaded. A write lands only while
	that mark is the same. A session that was live when the key was erased therefore stops,
	and does not write part of a dead profile back.
	Each op missing, and the fence broken, is the one shape that closes the session. A part of the
	batch that is missing is normal, and means that another server was first.
	The record is put into its current format one time, and both folds start from that. A migration
	may change the state that it gets, so to build it a second time would run each migration again.
	An op is only written if the record it lands in will take it, the way a store write is. An op that
	the record turns away is dropped from the queue, because it will be turned away every time.
	That test only runs when the log has moved since the last rebuild. A key that nobody else wrote to
	holds exactly what this session already checked against.
	
	Return type: A table with Push, Sifted, Rebuild, ApplyPending and SumBytes.
	Example usage:
		local Rebuild = require("./Rebuild")
		local Stored, Whole = Rebuild.Push(Active)
--]=]

local TableUtil = require("../Util/TableUtil")
local Fault = require("../Contract/Fault")
local Contract = require("../Contract/Op")
local Measure = require("../Encode/Measure")
local Fold = require("../Record/Fold")
local Shape = require("../Record/Shape")
local Stamp = require("../Record/Stamp")
local Step = require("../Record/Step")
local Types = require("./Types")

type Op = Contract.Op
type Record = Contract.Record<any>
type Session<S> = Types.Session<S>

local AUDITING = game:GetService("RunService"):IsStudio()

local function SumBytes(Ops: { Op }): number
	local Total = 0
	for _, Op in Ops do
		Total += Measure(Op)
	end
	return Total
end

local function ApplyPending<S>(self: Session<S>, State: S, Applied: { [string]: boolean }): S
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

local function Sifted<S>(self: Session<S>): (Record) -> (Op) -> boolean
	local Expect = self.LogSize
	local Format = self.Shape

	return function(Record: Record)
		if #Record.Ops == Expect then
			return function(): boolean
				return true
			end
		end

		local State = Format:Fold(Shape.Detached(Record))
		return function(Op: Op): boolean
			local Next = Step(Format.Reducer, State, Op)
			if Next == nil then
				return false
			end
			State = Next
			return true
		end
	end
end

local function Push<S>(self: Session<S>): (Record?, boolean?)
	local Count = #self.Pending
	if Count == 0 then
		return nil, true
	end

	local Batch = table.move(self.Pending, 1, Count, 1, {})
	local Fence = self.Fence
	local Stored, Turned = self.Log:Append(self.Key, Batch, function(Record: Record): boolean
		return Record.Erased == Fence
	end, Sifted(self))

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

	local Kept: { Op } = {}
	for _, Op in self.Pending do
		if not Landed[Op.Id] and not Dropped[Op.Id] then
			table.insert(Kept, Op)
		end
	end
	self.Pending = Kept

	local Missed = 0
	for _, Op in Batch do
		if not Landed[Op.Id] then
			Missed += 1
		end
	end
	Fault.Holds(Missed <= Count, "a push lost more ops than it was given, so one was counted twice")

	if Missed == Count and #Turned == 0 and Stored.Erased ~= Fence then
		self.Released = true
		warn(
			`Ledger: '{self.Key}' was erased while this session was live, so its {Count} unsaved op(s) were not written. the session is closed and this player needs to rejoin`
		)
	end

	self.LogSize = #Stored.Ops
	return Stored, Missed == 0
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

local function CheckPurity<S>(self: Session<S>, Stored: Record, Folded: S)
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

local function Rebuild<S>(self: Session<S>, Stored: Record, Mark: string?): (S, boolean)
	local Base: S = self.Shape:Rehydrate(Stored)
	local State, Accepted = Fold(Base, Stored.Ops, self.Shape.Reducer, Mark)
	local Applied: { [string]: boolean } = {}
	local Waiting: { [string]: boolean } = {}
	local Parked = 0
	for _, Op in Stored.Ops do
		if Op.Tx == nil then
			Applied[Op.Id] = true
		elseif type(Op.Tx) == "string" and not Waiting[Op.Tx] then
			Waiting[Op.Tx] = true
			Parked += 1
		end
	end

	State = ApplyPending(self, State, Applied)

	CheckPurity(self, Stored, State)

	self.State = TableUtil.FreezeDelta(State)
	self.Parked = Parked
	self.Landed = if Parked == 1
		then TableUtil.FreezeDelta(ApplyPending(self, Fold(Base, Stamp.Landed(Stored.Ops, next(Waiting) :: string), self.Shape.Reducer), {}))
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
		Fault.Holds(not Written[Op.Id], `op {Op.Id} is queued and already in the log for '{self.Key}', so it would be counted and folded twice`)
	end

	return State, Accepted
end

return table.freeze({
	Push = Push,
	Sifted = Sifted,
	Rebuild = Rebuild,
	ApplyPending = ApplyPending,
	SumBytes = SumBytes
})
