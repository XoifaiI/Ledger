--!strict
--!optimize 2

--[=[

	Fixture: One store on the case bench, and everything a case does to it.

	Seed, Write, Park and Marker put a key into a state by writing raw records straight at the mock,
	so setup is not broken by the faults a case installed. Record, Stored, Amount and the rest read it
	back through Ledger's own reader over an unfaulted handle, so nothing here works out what a record
	means for itself.

	Return type: A table with New. The type is Fixture.
	Example usage:
		local Bank = T:Bank()
		Bank:Seed("a", { Gold = 100 })
--]=]

local Applied = require("../../src/Core/Applied")
local Mark = require("../../src/Encode/Mark")
local Cleanup = require("../../src/Protocol/Tx/Cleanup")
local TxStamp = require("../../src/Record/TxStamp")
local Log = require("../../src/Record/Log")
local Wrapper = require("../../src/Util/DataStoreWrapper")
local Session = require("../../src/Session/Session")
local Fault = require("./Fault")
local Mock = require("../../src/Mock")

type Spec = Fault.Spec
type Fake = Mock.Store
type Service = Mock.Service

type FixtureImpl = {
	__index: FixtureImpl,

	New: (Store: any, Hook: Fault.Faulted, Service: Service, Data: string, Marked: string, Node: string, Field: string?) -> Fixture,

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
	Aside: (self: Fixture, Key: string, Field: string?) -> number,
	Names: (self: Fixture, Key: string) -> { [string]: any },
	Knows: (self: Fixture, Key: string, Tag: string, Id: string) -> boolean,
	Pending: (self: Fixture, Key: string) -> boolean,
	Marks: (self: Fixture) -> { string },
	Rolled: (self: Fixture) -> { [string]: boolean },
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
	Hook: Fault.Faulted,
	Service: Service,
	Data: string,
	Marked: string,
	Node: string,
	Field: string,
	Direct: any,
	DirectMarks: any,
	Books: any,
}, FixtureImpl>

local ROLL = "__"

local Fixture = {} :: FixtureImpl
Fixture.__index = Fixture

local function Peek(Held: Fake, Key: string): any
	return (Held:Current(Key))
end

local function Reader(Store: any, Service: Service, Data: string): any
	local Plain = Wrapper.New(Data, Store.Wrapper.Scheduler, Store.Wrapper.Hook)
	Plain.Store = Service:GetDataStore(Data)
	Plain.Attempts = 1
	return Log.New(Plain)
end

local function Live(Held: Fake): { string }
	local Found: { string } = {}
	for _, Key in Held.Names do
		local Slot = Held.Slots[Key]
		if Slot ~= nil and Slot.Live ~= nil then
			table.insert(Found, Key)
		end
	end
	return Found
end

local function Sum(Held: any, Field: string?): number
	if type(Held) ~= "table" then
		return 0
	end

	local Total = 0
	for _, Entry in Held do
		if type(Entry) == "table" and type(Entry.Amount) == "number" and Entry.Field == Field then
			Total += Entry.Amount
		end
	end
	return Total
end

function Fixture.New(Store: any, Hook: Fault.Faulted, Service: Service, Data: string, Marked: string, Node: string, Field: string?): Fixture
	return setmetatable({
		Store = Store,
		Hook = Hook,
		Service = Service,
		Data = Data,
		Marked = Marked,
		Node = Node,
		Field = Field or "Gold",
		Direct = Service:GetDataStore(Data),
		DirectMarks = Service:GetDataStore(Marked),
		Books = Reader(Store, Service, Data),
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
	self.DirectMarks:UpdateAsync(Cleanup.Key(Id, self.Store.Wrapper.Scheduler.Now()), function(Current: any): any
		local Held = if type(Current) == "string" then Mark.Unpack(Current) else {}
		if table.find(Held, Id) ~= nil then
			return Current
		end

		table.insert(Held, Id)
		return Mark.Pack(Held)
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
	return self.Books:Read(Key)
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

function Fixture.Aside(self: Fixture, Key: string, Field: string?): number
	return Sum(self:Stored(Key)._Held, Field)
end

function Fixture.Names(self: Fixture, Key: string): { [string]: any }
	local Held = self:Stored(Key)._Received
	return if type(Held) == "table" then Held else {}
end

function Fixture.Knows(self: Fixture, Key: string, Tag: string, Id: string): boolean
	return Applied.Has(self:Stored(Key)._Received, Tag, Id)
end

function Fixture.Pending(self: Fixture, Key: string): boolean
	return TxStamp.HasPending(self:Record(Key))
end

function Fixture.Marks(self: Fixture): { string }
	local Found: { string } = {}
	for _, Named in Live(self.DirectMarks) do
		if string.sub(Named, 1, #ROLL) == ROLL then
			continue
		end
		table.insert(Found, Named)
	end
	return Found
end

function Fixture.Rolled(self: Fixture): { [string]: boolean }
	local Found: { [string]: boolean } = {}
	for _, Named in Live(self.DirectMarks) do
		if string.sub(Named, 1, #ROLL) ~= ROLL then
			continue
		end

		local Held = Peek(self.DirectMarks, Named)
		if type(Held) ~= "string" then
			continue
		end
		for _, Id in Mark.Unpack(Held) do
			Found[Id] = true
		end
	end
	return Found
end

function Fixture.Mark(self: Fixture, Id: string): any
	return Peek(self.DirectMarks, Id)
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
	return Session.Load(self.Store:Records(), self.Store:Format(), Key, self.Store.TxWrapper):Wait()
end

function Fixture.Log(self: Fixture): any
	return self.Store:Records()
end

function Fixture.Format(self: Fixture): any
	return self.Store:Format()
end

function Fixture.Fault(self: Fixture, Spec: Spec): Spec
	return self.Hook.Fail(Spec:OnStore(self.Data))
end

function Fixture.MarkerFault(self: Fixture, Spec: Spec): Spec
	return self.Hook.Fail(Spec:OnStore(self.Marked))
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
	self.Hook.Clear()
end

table.freeze(Fixture)

return table.freeze({
	New = Fixture.New,
})
