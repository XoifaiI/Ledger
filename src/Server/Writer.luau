--!strict
--!optimize 2

--[=[

	Writer: One server's queue of ops for one key, and what it makes of each answer.

	Push numbers an op and queues it. Send makes the one request a writer may have out: every op whose
	fate is not heard, in number order, with at most a quarter of the timed room in new timed names.
	An op takes its stamp and its incarnation the first time it is sent, and keeps them. Transform runs
	Step for the request, and records whether any run gave back a value and every number a run
	decided. Heard and Failed take the answer, and give back each op whose fate is now known, once,
	with its reply and its fate code.

	An op is clean while no request that carried it failed and no run decided it. Only a clean op takes
	a no from a cancel or a horizon, and any other answers Unresolved. A clean minted or hopeful op that
	is forgotten or ahead gets a stamp past the horizon the note carried and is sent again. A clean op
	judged for no key is sent again for the key the note found. A landed write turns away every queued
	hopeful op judged before the key's last cut. After Limits.TRIES failed requests in a row an op
	answers Unresolved and is still sent. Overdue answers Unresolved for an op with no fate
	Windows.ANSWER seconds after it was first sent. Shed answers Busy for a durable op not sent within
	Windows.SHED seconds.

	Return type: A table with New, Push, Send, Transform, Heard, Failed, Overdue, Shed, Ack and Exhausted.
	Example usage:
		local Writer = require("./Writer")
		local Queue = Writer.New(Id, Build.TimedRoom)
		local Item = Writer.Push(Queue, Asked, Clock)
		local Sent = Writer.Send(Queue, Clock, Id, Create)
--]=]

local Answer = require("../Core/Answer")
local Book = require("../Record/Book")
local Limits = require("../Core/Constants/Limits")
local Step = require("../Record/Step")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

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
	read Pushed: number,
	Stamp: number?,
	Id: string?,
	Create: string?,
	Op: Op?,
	First: number?,
	Dirty: boolean,
	Tries: number,
	Said: boolean,
}

export type Heard = {
	read Item: Item,
	read Reply: Reply,
	read Code: number?,
}

export type Sent = {
	read Request: Types.Request,
	read Items: { Item },
	Wrote: boolean,
	Landed: boolean,
	Ran: { [number]: true },
	Note: Note?,
}

export type Writer = {
	read Id: number,
	read TimedCap: number,
	Next: number,
	Items: { Item },
	Out: Sent?,
	Horizon: number,
}

type Gone = { [Item]: true }

local Fate = Book.Fate
local Form = Types.Form
local Why = Types.Why

local ENDS: { [Types.Why]: Answer } = {
	[Why.NoRoom] = Answer.NoRoom,
	[Why.Missing] = Answer.Missing,
	[Why.Behind] = Answer.Behind,
	[Why.Worn] = Answer.Worn,
	[Why.Corrupt] = Answer.Unresolved,
}

local function New(Id: number, TimedRoom: number): Writer
	return { Id = Id, TimedCap = TimedRoom // 4, Next = 1, Items = {}, Out = nil, Horizon = 0 }
end

local function Ack(Writer: Writer): number
	local First = Writer.Items[1]
	return if First then First.Seq - 1 else Writer.Next - 1
end

local function Exhausted(Writer: Writer): boolean
	return Writer.Next > Limits.SEQ_MAX
end

local function Push(Writer: Writer, Asked: Asked, Clock: number): Item?
	if #Writer.Items >= Limits.QUEUE or Writer.Next > Limits.SEQ_MAX then
		return nil
	end
	local Item: Item = {
		Seq = Writer.Next,
		Asked = Asked,
		Pushed = Clock,
		Stamp = Asked.Stamp,
		Id = nil,
		Create = nil,
		Op = nil,
		First = nil,
		Dirty = false,
		Tries = 0,
		Said = false,
	}
	Writer.Next += 1
	table.insert(Writer.Items, Item)
	return Item
end

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
	local Stamp = Item.Stamp or math.max(Clock, Horizon + 1)
	local Asked = Item.Asked
	local Made: Op = {
		Form = Asked.Form,
		Seq = Item.Seq,
		Stamp = Stamp,
		Kind = Asked.Kind,
		Name = Asked.Name,
		Print = Asked.Print,
		View = Asked.View,
		Id = Item.Id,
		Create = Item.Create,
		Body = Asked.Body,
	}
	Item.Stamp, Item.Op = Stamp, Made
	return Made
end

local function Send(Writer: Writer, Clock: number, Id: string?, Create: string?): Sent?
	local First = Writer.Items[1]
	if Writer.Out or First == nil then
		return nil
	end
	local Ops: { Op } = {}
	local Carried: { Item } = {}
	local Bytes = 0
	for _, Item in Writer.Items do
		Bytes += Width(Item, Clock)
		if Bytes > Writer.TimedCap and #Ops > 0 then
			break
		end
		table.insert(Ops, Item.Op or OpOf(Item, Clock, Writer.Horizon, Id, Create))
		table.insert(Carried, Item)
	end
	local Sent: Sent = {
		Request = { Writer = Writer.Id, Ack = Ack(Writer), MustExist = First.Asked.MustExist, Ops = Ops },
		Items = Carried,
		Wrote = false,
		Landed = false,
		Ran = {},
		Note = nil,
	}
	Writer.Out = Sent
	return Sent
end

local function Transform(Sent: Sent, Build: Types.Build, Clock: () -> number): (Current: unknown) -> unknown
	return function(Current: unknown): unknown
		local Value, Note = Step(Current, Sent.Request, Clock(), Build)
		for _, Seq in Note.Decided do
			Sent.Ran[Seq] = true
		end
		Sent.Note, Sent.Landed = Note, Value ~= nil
		Sent.Wrote = Sent.Wrote or Value ~= nil
		return Value
	end
end

local function Say(Heard: { Heard }, Item: Item, Reply: Reply, Code: number?)
	if Item.Said then
		return
	end
	Item.Said = true
	table.insert(Heard, { Item = Item, Reply = Reply, Code = Code })
end

local function Settle(Heard: { Heard }, Gone: Gone, Item: Item, Reply: Reply, Code: number?)
	Gone[Item] = true
	Say(Heard, Item, Reply, Code)
end

local function Drop(Writer: Writer, Gone: Gone)
	if next(Gone) == nil then
		return
	end
	local Kept: { Item } = {}
	for _, Item in Writer.Items do
		if not Gone[Item] then
			table.insert(Kept, Item)
		end
	end
	Writer.Items = Kept
end

local function Minted(Item: Item): boolean
	local Of = Item.Asked.Form
	return Of == Form.Minted or Of == Form.Hopeful
end

local function Restamp(Item: Item, Clock: number, Note: Note)
	Item.Stamp, Item.Op = math.max(Clock, Note.Horizon + 1), nil
end

local function Fated(Code: number): Reply
	if Code == Fate.Took then
		return true
	elseif Code == Fate.Full then
		return Answer.Full
	end
	return Answer.Refused
end

local function Learn(Item: Item, Index: number, Note: Note, Clock: number, Heard: { Heard }, Gone: Gone)
	local Code = Note.Fates[Index]
	if Code ~= nil then
		return Settle(Heard, Gone, Item, Fated(Code), Code)
	end
	local Reason = Note.Whys[Index]
	local Clean = not Item.Dirty
	if Reason == nil or Reason == Why.Undecided then
		return
	elseif Reason == Why.Spent then
		return Settle(Heard, Gone, Item, Answer.Spent)
	elseif (Reason == Why.Forgotten or Reason == Why.Ahead) and Clean and Minted(Item) then
		return Restamp(Item, Clock, Note)
	elseif Reason == Why.Ahead then
		return
	elseif Reason == Why.Forgotten then
		return Settle(Heard, Gone, Item, if Clean then Answer.Expired else Answer.Unresolved)
	elseif Reason == Why.Missing and Clean and Item.Create and Note.Id then
		Item.Id, Item.Create, Item.Op = Note.Id, nil, nil
		return
	end
	return Settle(Heard, Gone, Item, if Clean then ENDS[Reason] else Answer.Unresolved)
end

local function TurnAway(Writer: Writer, Note: Note, Heard: { Heard }, Gone: Gone)
	for _, Item in Writer.Items do
		local View = Item.Asked.View
		if not Gone[Item] and Item.Asked.Form == Form.Hopeful and View and View < Note.Cuts then
			Settle(Heard, Gone, Item, Answer.Refused, Fate.Turned)
		end
	end
end

local function Heard(Writer: Writer, Clock: number): { Heard }
	local Sent = assert(Writer.Out, "Writer: Heard with no request out")
	local Note = assert(Sent.Note, "Writer: Heard for a request no run noted")
	Writer.Out = nil
	local Said: { Heard } = {}
	local Gone: Gone = {}
	for Index, Item in Sent.Items do
		Item.Dirty = Item.Dirty or Sent.Ran[Item.Seq] ~= nil
		Item.Tries = 0
		Learn(Item, Index, Note, Clock, Said, Gone)
	end
	if Sent.Landed then
		TurnAway(Writer, Note, Said, Gone)
	end
	Writer.Horizon = math.max(Writer.Horizon, Note.Horizon)
	Drop(Writer, Gone)
	return Said
end

local function Failed(Writer: Writer): { Heard }
	local Sent = assert(Writer.Out, "Writer: Failed with no request out")
	Writer.Out = nil
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

local function Overdue(Writer: Writer, Clock: number): { Heard }
	local Said: { Heard } = {}
	for _, Item in Writer.Items do
		local First = Item.First
		if First and Clock - First >= Windows.ANSWER then
			Say(Said, Item, Answer.Unresolved)
		end
	end
	return Said
end

local function Shed(Writer: Writer, Clock: number): { Heard }
	local Said: { Heard } = {}
	local Gone: Gone = {}
	for _, Item in Writer.Items do
		if Item.First == nil and Item.Asked.Form ~= Form.Hopeful and Clock - Item.Pushed >= Windows.SHED then
			Settle(Said, Gone, Item, Answer.Busy)
		end
	end
	Drop(Writer, Gone)
	return Said
end

return table.freeze({
	New = New,
	Push = Push,
	Send = Send,
	Transform = Transform,
	Heard = Heard,
	Failed = Failed,
	Overdue = Overdue,
	Shed = Shed,
	Ack = Ack,
	Exhausted = Exhausted,
})
