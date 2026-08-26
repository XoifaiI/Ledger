--!strict
--!optimize 2

--[=[
	Fixture: One store on the case bench, and everything a case does to it.

	A case spends most of its lines putting a key into a state and reading back what Ledger did.
	Both of those are here, so a case is left holding only the part that is about Ledger.
	Setting up and checking go straight at the disk, because setup through the store would be broken
	by the faults the case installed. State is the exception and asks the store on purpose.

	Return type: A table with New. The type is Fixture.
	Example usage:
		local Bank = T:Bank()
		Bank:Seed("a", { Gold = 100 })
--]=]

local Disk = require("../Disk")
local Lib = require("../Lib")
local Fault = require("./Fault")

local Entries = Lib.Entries
local Stamp = Lib.Stamp

type Spec = Fault.Spec

type FixtureImpl = {
	__index: FixtureImpl,

	New: (Store: any, Plate: Disk.Disk, Data: string, Marked: string, Node: string, Field: string?) -> Fixture,

	Seed: (self: Fixture, Key: string, Snapshot: { [string]: any }) -> (),
	Write: (self: Fixture, Key: string, Record: { [string]: any }) -> (),
	Marker: (self: Fixture, Id: string, Fields: { [string]: any }) -> (),
	Park: (self: Fixture, Key: string, Op: { [string]: any }) -> (),
	Append: (self: Fixture, Key: string, Ops: { any }) -> (),
	Forget: (self: Fixture, Key: string, Prefixes: { string }) -> (),

	Record: (self: Fixture, Key: string) -> any,
	Stored: (self: Fixture, Key: string) -> any,
	State: (self: Fixture, Key: string) -> any,
	Amount: (self: Fixture, Key: string, Field: string?) -> number,
	Aside: (self: Fixture, Key: string) -> number,
	Booked: (self: Fixture, Key: string) -> number,
	Names: (self: Fixture, Key: string) -> { [string]: any },
	Knows: (self: Fixture, Key: string, Tag: string, Id: string) -> boolean,
	Pending: (self: Fixture, Key: string) -> boolean,
	Marks: (self: Fixture) -> { string },
	Mark: (self: Fixture, Id: string) -> any,
	Buried: (self: Fixture, Id: string) -> boolean,
	Unmark: (self: Fixture, Id: string) -> (),

	Session: (self: Fixture, Key: string) -> any,
	TrySession: (self: Fixture, Key: string) -> (any, string?),
	Log: (self: Fixture) -> any,
	Format: (self: Fixture) -> any,

	Fault: (self: Fixture, Spec: Spec) -> Spec,
	MarkerFault: (self: Fixture, Spec: Spec) -> Spec,
	Budget: (self: Fixture, Asks: (Kind: Enum.DataStoreRequestType) -> number) -> (),
	MarkerBudget: (self: Fixture, Asks: (Kind: Enum.DataStoreRequestType) -> number) -> (),
	NoRetries: (self: Fixture) -> (),
	Healed: (self: Fixture) -> (),
}

export type Fixture = setmetatable<{
	Store: any,
	Plate: Disk.Disk,
	Data: string,
	Marked: string,
	Node: string,
	Field: string,
	Direct: any,
	DirectMarks: any,
	Faults: { Spec },
	MarkerFaults: { Spec },
}, FixtureImpl>

local Fixture = {} :: FixtureImpl
Fixture.__index = Fixture

local function Materialised(Raw: any): any
	if type(Raw) ~= "table" then
		return { Ops = {}, Seen = {} }
	end

	local Ops: { any } = {}
	if type(Raw.Ops) == "table" then
		for _, Entry in Raw.Ops do
			local Op: any = Entry
			if type(Op) ~= "table" or type(Op.Id) ~= "string" or type(Op.Kind) ~= "string" then
				continue
			end
			if Op.Tx ~= nil and type(Op.Tx) ~= "string" then
				continue
			end
			table.insert(Ops, Op)
		end
	end

	local Seen: { string } = {}
	if type(Raw.Seen) == "table" then
		for _, Id in Raw.Seen do
			if type(Id) == "string" then
				table.insert(Seen, Id)
			end
		end
	end

	return {
		Snapshot = if type(Raw.Snapshot) == "table" then Raw.Snapshot else nil,
		Ops = Ops,
		Seen = Seen,
		Envelope = if type(Raw.Envelope) == "number" then Raw.Envelope else nil,
		Version = if type(Raw.Version) == "number" then Raw.Version else nil,
		Floor = if type(Raw.Floor) == "number" then Raw.Floor else nil,
		Erased = if type(Raw.Erased) == "number" then Raw.Erased else nil,
		Bytes = if type(Raw.Bytes) == "number" then Raw.Bytes else nil,
	}
end

local function Sum(Held: any, Field: string): number
	if type(Held) ~= "table" then
		return 0
	end

	local Total = 0
	for _, Entry in Held do
		if type(Entry) == "table" and type(Entry[Field]) == "number" then
			Total += Entry[Field]
		end
	end
	return Total
end

local function Bookings(Held: any): number
	if type(Held) ~= "table" then
		return 0
	end

	local Count = 0
	for _, Entry in Held do
		if type(Entry) == "table" and type(Entry.Amount) == "number" and type(Entry.Field) == "string" then
			Count += 1
		end
	end
	return Count
end

function Fixture.New(Store: any, Plate: Disk.Disk, Data: string, Marked: string, Node: string, Field: string?): Fixture
	return setmetatable({
		Store = Store,
		Plate = Plate,
		Data = Data,
		Marked = Marked,
		Node = Node,
		Field = Field or "Gold",
		Direct = Disk.Open(Plate, Data),
		DirectMarks = Disk.Open(Plate, Marked),
		Faults = {},
		MarkerFaults = {},
	}, Fixture) :: any
end

function Fixture.Seed(self: Fixture, Key: string, Snapshot: { [string]: any })
	self:Write(Key, { Snapshot = Snapshot, Ops = {}, Seen = {} })
end

function Fixture.Write(self: Fixture, Key: string, Record: { [string]: any })
	self.Direct:UpdateAsync(Key, function(): any
		return Record
	end)
end

function Fixture.Marker(self: Fixture, Id: string, Fields: { [string]: any })
	self.DirectMarks:UpdateAsync(Id, function(): any
		return Fields
	end)
end

function Fixture.Park(self: Fixture, Key: string, Op: { [string]: any })
	local Home = self.Marked
	self.Direct:UpdateAsync(Key, function(Current: any): any
		local Record: any = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		if type(Record.Ops) ~= "table" then
			Record.Ops = {}
		end
		if type(Record.Seen) ~= "table" then
			Record.Seen = {}
		end

		local Entry = table.clone(Op)
		if Entry.TxHome == nil then
			Entry.TxHome = Home
		end
		table.insert(Record.Ops, Entry)
		return Record
	end)
end

function Fixture.Append(self: Fixture, Key: string, Ops: { any })
	self.Store:Records():Append(Key, Ops)
end

function Fixture.Forget(self: Fixture, Key: string, Prefixes: { string })
	self.Store:Records():Compact(Key, self.Store:Format())

	self.Direct:UpdateAsync(Key, function(Current: any): any
		if type(Current) ~= "table" or type(Current.Seen) ~= "table" then
			return nil
		end

		local Kept: { string } = {}
		for _, Id in Current.Seen :: { string } do
			local Strip = false
			for _, Prefix in Prefixes do
				if string.sub(Id, 1, #Prefix) == Prefix then
					Strip = true
				end
			end
			if not Strip then
				table.insert(Kept, Id)
			end
		end

		Current.Seen = Kept
		return Current
	end)
end

function Fixture.Record(self: Fixture, Key: string): any
	return Materialised(Disk.Peek(self.Plate, self.Data, Key))
end

function Fixture.Stored(self: Fixture, Key: string): any
	return self.Store:Format():Fold(self:Record(Key))
end

function Fixture.State(self: Fixture, Key: string): any
	return (self.Store:Peek(Key):Wait())
end

function Fixture.Amount(self: Fixture, Key: string, Field: string?): number
	local Held = self:Stored(Key)
	local Value = if type(Held) == "table" then Held[Field or self.Field] else nil
	return if type(Value) == "number" then Value else 0
end

function Fixture.Aside(self: Fixture, Key: string): number
	return Sum(self:Stored(Key)._Held, "Amount")
end

function Fixture.Booked(self: Fixture, Key: string): number
	return Bookings(self:Stored(Key)._Booked)
end

function Fixture.Names(self: Fixture, Key: string): { [string]: any }
	local Held = self:Stored(Key)._Received
	return if type(Held) == "table" then Held else {}
end

function Fixture.Knows(self: Fixture, Key: string, Tag: string, Id: string): boolean
	return Entries.Has(self:Stored(Key)._Received, Tag, Id)
end

function Fixture.Pending(self: Fixture, Key: string): boolean
	return Stamp.HasPending(self:Record(Key))
end

function Fixture.Marks(self: Fixture): { string }
	return Disk.Keys(self.Plate, self.Marked)
end

function Fixture.Mark(self: Fixture, Id: string): any
	return Disk.Peek(self.Plate, self.Marked, Id)
end

function Fixture.Buried(self: Fixture, Id: string): boolean
	local Held = self:Mark(Id)
	return Held == nil or (type(Held) == "table" and Held.Dead == true)
end

function Fixture.Unmark(self: Fixture, Id: string)
	self.DirectMarks:RemoveAsync(Id)
end

function Fixture.Session(self: Fixture, Key: string): any
	local Active, Why = self:TrySession(Key)
	assert(Active ~= nil, `the case could not open a session on '{Key}': {tostring(Why)}`)
	return Active
end

function Fixture.TrySession(self: Fixture, Key: string): (any, string?)
	return Lib.OpenSession(self.Store:Records(), self.Store:Format(), Key, self.Store.TxWrapper):Wait()
end

function Fixture.Log(self: Fixture): any
	return self.Store:Records()
end

function Fixture.Format(self: Fixture): any
	return self.Store:Format()
end

function Fixture.Fault(self: Fixture, Spec: Spec): Spec
	table.insert(self.Faults, Spec)
	return Spec
end

function Fixture.MarkerFault(self: Fixture, Spec: Spec): Spec
	table.insert(self.MarkerFaults, Spec)
	return Spec
end

function Fixture.Budget(self: Fixture, Asks: (Kind: Enum.DataStoreRequestType) -> number)
	self.Store.Wrapper.Budgets = Asks
end

function Fixture.MarkerBudget(self: Fixture, Asks: (Kind: Enum.DataStoreRequestType) -> number)
	self.Store.TxWrapper.Budgets = Asks
end

function Fixture.NoRetries(self: Fixture)
	self.Store.Wrapper.Attempts = 1
	self.Store.TxWrapper.Attempts = 1
end

function Fixture.Healed(self: Fixture)
	table.clear(self.Faults)
	table.clear(self.MarkerFaults)
end

table.freeze(Fixture)

return table.freeze({
	New = Fixture.New,
})
