--!strict
--!optimize 2

--[=[

	Writer: One server's queue of ops for one key, and what it makes of each answer.

	A request carries every op whose fate is not heard. An op keeps the stamp and incarnation of its
	first send. Only a clean op, which no failed request carried and no run decided, answers a no
	from a cancel or a horizon. A clean minted op that is forgotten or ahead is stamped again. Withdraw
	takes back an op that was never sent.

	Return type: The Writer class, with New and Transform, and the methods Ack, Push, Send, Heard,
	Failed and Withdraw.
	Example usage:
		local Sent = Queue:Send(Clock)
--]=]

local Answer = require("../Core/Answer")
local Book = require("../Record/Book")
local Limits = require("../Core/Constants/Limits")
local Step = require("../Record/Step")
local Types = require("../Record/Types")

type Answer = Answer.Answer
type Note = Types.Note
type Op = Types.Op

export type Reply = true | Answer

export type Asked = {
	read Form: Types.Form,
	read Kind: number,
	read Name: string?,
	read Print: number?,
	read Stamp: number?,
	read View: number?,
	read MustExist: boolean,
	read Body: unknown,
}

export type Item = {
	read Seq: number,
	read Asked: Asked,
	Stamp: number?,
	Id: string?,
	Create: string?,
	Op: Op?,
	First: number?,
	Dirty: boolean,
	Tries: number,
	Said: boolean,
	Done: boolean,
}

export type Heard = {
	read Item: Item,
	read Reply: Reply,
	read Code: number?,
}

export type Sent = {
	read Request: Types.Request,
	read Items: { Item },
	Landed: boolean,
	Ran: { [number]: true },
	Note: Note?,
}

type WriterImpl = {
	__index: WriterImpl,
	New: (Id: number, TimedRoom: number) -> Writer,
	Transform: (Sent: Sent, Build: Types.Build, Clock: () -> number) -> (Current: unknown, Info: DataStoreKeyInfo?) -> unknown,
	Ack: (self: Writer) -> number,
	Push: (self: Writer, Asked: Asked) -> Item?,
	Send: (self: Writer, Clock: number, Id: string?, Create: string?) -> Sent?,
	Heard: (self: Writer, Clock: number) -> { Heard },
	Failed: (self: Writer) -> { Heard },
	Withdraw: (self: Writer, Item: Item) -> boolean,
}

type Data = {
	read Id: number,
	read TimedCap: number,
	Next: number,
	Items: { Item },
	Out: Sent?,
	Horizon: number,
}

export type Writer = setmetatable<Data, WriterImpl>

local Fate = Book.Fate
local Form = Types.Form
local Why = Types.Why

local FATES: { [number]: Reply } = {
	[Fate.Took] = true,
	[Fate.Full] = Answer.Full,
}

local ENDS: { [Types.Why]: Answer } = {
	[Why.NoRoom] = Answer.NoRoom,
	[Why.Missing] = Answer.Missing,
	[Why.Behind] = Answer.Behind,
	[Why.Worn] = Answer.Worn,
	[Why.Corrupt] = Answer.Unresolved,
}

local Writer = {} :: WriterImpl
Writer.__index = Writer

local function Width(Item: Item, Clock: number): number
	local Asked = Item.Asked
	local Name = Asked.Name
	if Item.Op or Asked.Form ~= Form.Timed or Name == nil then
		return 0
	end
	return Book.NamedWidth(Name, { Kind = Asked.Kind, Stamp = Asked.Stamp or Clock, Fate = Fate.Took, Print = Asked.Print }, Clock)
end

local function OpOf(Item: Item, Clock: number, Horizon: number, Id: string?, Create: string?): Op
	if Item.First == nil then
		Item.First, Item.Id, Item.Create = Clock, Id, Create
	end
	local Made = table.clone(Item.Asked) :: any
	Made.Seq, Made.Id, Made.Create = Item.Seq, Item.Id, Item.Create
	Made.Stamp = Item.Stamp or math.max(Clock, Horizon + 1)
	Item.Stamp, Item.Op = Made.Stamp, Made
	return Made
end

local function Say(Said: { Heard }, Item: Item, Reply: Reply, Code: number?)
	if not Item.Said then
		Item.Said = true
		table.insert(Said, { Item = Item, Reply = Reply, Code = Code })
	end
end

local function Settle(Said: { Heard }, Item: Item, Reply: Reply, Code: number?)
	Item.Done = true
	Say(Said, Item, Reply, Code)
end

local function Open(Items: { Item }): { Item }
	local Kept: { Item } = {}
	for _, Item in Items do
		if not Item.Done then
			table.insert(Kept, Item)
		end
	end
	return Kept
end

local function Minted(Item: Item): boolean
	local Of = Item.Asked.Form
	return Of == Form.Minted or Of == Form.Hopeful
end

local function Learn(Item: Item, Index: number, Note: Note, Clock: number, Said: { Heard })
	local Code = Note.Fates[Index]
	if Code ~= nil then
		return Settle(Said, Item, FATES[Code] or Answer.Refused, Code)
	end
	local Reason = Note.Whys[Index]
	local Clean = not Item.Dirty
	if Reason == nil or Reason == Why.Undecided then
		return
	elseif Reason == Why.Spent then
		return Settle(Said, Item, Answer.Spent)
	elseif (Reason == Why.Forgotten or Reason == Why.Ahead) and Clean and Minted(Item) then
		Item.Stamp, Item.Op = math.max(Clock, Note.Horizon + 1), nil
		return
	elseif Reason == Why.Ahead then
		return
	elseif Reason == Why.Forgotten then
		return Settle(Said, Item, if Clean then Answer.Expired else Answer.Unresolved)
	elseif Reason == Why.Missing and Clean and Item.Create and Note.Id then
		Item.Id, Item.Create, Item.Op = Note.Id, nil, nil
		return
	end
	return Settle(Said, Item, if Clean then ENDS[Reason] else Answer.Unresolved)
end

function Writer.New(Id: number, TimedRoom: number): Writer
	local Fresh: Data = { Id = Id, TimedCap = TimedRoom // 4, Next = 1, Items = {}, Horizon = 0 }
	return setmetatable(Fresh, Writer)
end

function Writer.Transform(Sent: Sent, Build: Types.Build, Clock: () -> number): (Current: unknown, Info: DataStoreKeyInfo?) -> unknown
	return function(Current: unknown, _: DataStoreKeyInfo?): unknown
		local Note = Step(Current, Sent.Request, Clock(), Build)
		for _, Seq in Note.Decided do
			Sent.Ran[Seq] = true
		end
		Sent.Note, Sent.Landed = Note, Note.Stored ~= nil
		return Note.Stored
	end
end

function Writer.Ack(self: Writer): number
	local First = self.Items[1]
	return if First then First.Seq - 1 else self.Next - 1
end

function Writer.Push(self: Writer, Asked: Asked): Item?
	if #self.Items >= Limits.QUEUE or self.Next > Limits.SEQ_MAX then
		return nil
	end
	local Item: Item = { Seq = self.Next, Asked = Asked, Stamp = Asked.Stamp, Dirty = false, Tries = 0, Said = false, Done = false }
	self.Next += 1
	table.insert(self.Items, Item)
	return Item
end

function Writer.Send(self: Writer, Clock: number, Id: string?, Create: string?): Sent?
	local First = self.Items[1]
	if self.Out or First == nil then
		return nil
	end
	local Ops: { Op } = {}
	local Carried: { Item } = {}
	local Bytes = 0
	for _, Item in self.Items do
		Bytes += Width(Item, Clock)
		if Bytes > self.TimedCap and #Ops > 0 then
			break
		end
		table.insert(Ops, Item.Op or OpOf(Item, Clock, self.Horizon, Id, Create))
		table.insert(Carried, Item)
	end
	local Request = { Writer = self.Id, Ack = self:Ack(), MustExist = First.Asked.MustExist, Ops = Ops }
	local Sent: Sent = { Request = Request, Items = Carried, Landed = false, Ran = {} }
	self.Out = Sent
	return Sent
end

function Writer.Heard(self: Writer, Clock: number): { Heard }
	local Sent = assert(self.Out, "Writer: Heard with no request out")
	local Note = assert(Sent.Note, "Writer: Heard for a request no run noted")
	self.Out = nil
	local Said: { Heard } = {}
	for Index, Item in Sent.Items do
		Item.Dirty = Item.Dirty or Sent.Ran[Item.Seq] ~= nil
		Item.Tries = 0
		Learn(Item, Index, Note, Clock, Said)
	end
	for _, Item in if Sent.Landed then self.Items else {} do
		local View = Item.Asked.View
		if not Item.Done and Item.Asked.Form == Form.Hopeful and View and View < Note.Cuts then
			Settle(Said, Item, Answer.Refused, Fate.Turned)
		end
	end
	self.Horizon = math.max(self.Horizon, Note.Horizon)
	self.Items = Open(self.Items)
	return Said
end

function Writer.Failed(self: Writer): { Heard }
	local Sent = assert(self.Out, "Writer: Failed with no request out")
	self.Out = nil
	local Said: { Heard } = {}
	for _, Item in Sent.Items do
		Item.Dirty = true
		Item.Tries += 1
		if Item.Tries >= Limits.TRIES then
			Say(Said, Item, Answer.Unresolved)
		end
	end
	return Said
end

function Writer.Withdraw(self: Writer, Item: Item): boolean
	if Item.First or Item.Done then
		return false
	end
	Item.Done = true
	self.Items = Open(self.Items)
	return true
end

return Writer
