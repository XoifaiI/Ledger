--!strict
--!optimize 2

--[=[
	Queue: Logic. The ops one server has for one key, and what each reply says of them.

	An op is numbered and stamped when it is first sent, and keeps both. A request carries every op
	whose fate is not heard, in order, and its new timed bytes stay within a quarter of the timed
	room. An op is clean until a failed request carried it or a run decided it. Only a clean op takes
	a no from a cancel or a horizon, and any other answers Unresolved. A clean minted op that is
	forgotten or ahead is stamped again. An op that a mark blocks or an overdue item holds up waits.
	A landing turns away each hopeful op judged before the key's last cut. A failed request answers
	its ops Unresolved, and the ops are still sent. Past SEQ_MAX the queue is spent until it takes a
	fresh writer id. A ride is an end for a mark in the way, one per mark, and it goes with every
	request until one lands.

	On an erasable store the queue keeps Seen, the key's id as this server last saw it, or false when
	it saw no key. An op takes that id, or a create of a fresh id, when it is first sent, and keeps
	it. Once a request that carried a create may have written, the op carries that id instead.

	Return type: The Queue module, and the Queue, Asked, Item, Fate and Reply types.
	Example usage:
		local Request = Queue.Build(Held, Now)
--]=]

local Answer = require("../Core/Answer")
local Book = require("./Book")
local Key = require("./Key")
local Pacing = require("./Pacing")
local Requests = require("./Requests")
local Types = require("./Types")
local Windows = require("../Core/Constants/Windows")

type Answer = Answer.Answer
type Note = Types.Note
type Op = Requests.Op

export type Reply = true | Answer

export type Asked = {
	read Form: Requests.Form,
	read Kind: number,
	read Name: string?,
	read Print: number?,
	read Stamp: number?,
	read View: number?,
	read MustExist: boolean,
	read Body: unknown,
}

export type Item = {
	Seq: number?,
	read Asked: Asked,
	read Tell: Tell?,
	Stamp: number?,
	Id: string?,
	Create: string?,
	Op: Op?,
	First: number?,
	Dirty: boolean,
	Said: boolean,
	Done: boolean,
}

export type Tell = (Asked: Asked, Reply: Reply, Code: number?) -> ()

export type Fate = {
	read Item: Item,
	read Reply: Reply,
	read Code: number?,
}

export type Queue = {
	read Ref: Book.Ref,
	read Build: Types.Build,
	read UserIds: { number }?,
	read TimedCap: number,
	Id: number,
	Next: number,
	Items: { Item },
	Out: { Item }?,
	Horizon: number,
	Rides: { Requests.End },
	Since: number,
	Running: boolean,
	Seen: (string | false)?,
	read Pace: Pacing.Pace?,
}

local Fate = Book.Fate
local Form = Requests.Form
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

local SEQ_MAX = 32767
local QUEUE = 4096
local REQUEST_SHARE = 4

local Queue = {
	SEQ_MAX = SEQ_MAX,
}

local function Width(Item: Item, Clock: number): number
	local Asked = Item.Asked
	local Name = Asked.Name
	if Item.Op or Asked.Form ~= Form.Timed or Name == nil then
		return 0
	end
	return Book.NamedWidth(Name, Book.OpName(Asked.Stamp or Clock, Asked.Print, Fate.Took, Asked.Kind), Clock)
end

local function OpOf(Held: Queue, Item: Item, Clock: number): Op
	if Item.First == nil then
		Item.First = Clock
		local Seen = Held.Seen
		if Held.Build.Erasable and Seen == false then
			Item.Create = Book.Incarnation(Held.Id, Item.Seq :: number)
		elseif Held.Build.Erasable and Seen and Seen ~= "" then
			Item.Id = Seen
		end
	end
	local Made = table.clone(Item.Asked) :: any
	Made.Seq = Item.Seq
	Made.Id = Item.Id
	Made.Create = Item.Create
	Made.Stamp = Item.Stamp or math.max(Clock, Held.Horizon + 1)
	Item.Stamp = Made.Stamp
	Item.Op = Made
	return Made
end

local function Say(Said: { Fate }, Item: Item, Reply: Reply, Code: number?)
	if not Item.Said then
		Item.Said = true
		table.insert(Said, { Item = Item, Reply = Reply, Code = Code })
	end
end

local function Settle(Said: { Fate }, Item: Item, Reply: Reply, Code: number?)
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

local function Taint(Item: Item)
	if Item.Dirty and Item.Create then
		Item.Id = Item.Create
		Item.Create = nil
		Item.Op = nil
	end
end

local function Judge(Item: Item, Index: number, Note: Note, Clock: number, Said: { Fate })
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
		Item.Stamp = math.max(Clock, Note.Horizon + 1)
		Item.Op = nil
		return
	elseif Reason == Why.Ahead or Reason == Why.Blocked or Reason == Why.Overdue then
		return
	elseif Reason == Why.Forgotten then
		return Settle(Said, Item, if Clean then Answer.Expired else Answer.Unresolved)
	elseif Reason == Why.Missing and Clean and Item.Create and Note.Id then
		Item.Id = Note.Id
		Item.Create = nil
		Item.Op = nil
		return
	end
	return Settle(Said, Item, if Clean then ENDS[Reason] else Answer.Unresolved)
end

function Queue.New(Ref: Book.Ref, Build: Types.Build, Id: number, UserIds: { number }?, Now: number): Queue
	return {
		Ref = Ref,
		Build = Build,
		UserIds = UserIds,
		TimedCap = Build.TimedRoom // REQUEST_SHARE,
		Id = Id,
		Next = 1,
		Items = {},
		Horizon = 0,
		Rides = {},
		Since = Now,
		Running = false,
		Pace = if Build.Paced then Pacing.New(Build.Paced) else nil,
	}
end

function Queue.Ack(Held: Queue): number
	local First = Held.Items[1]
	local Seq = if First then First.Seq else nil
	return if Seq then Seq - 1 else Held.Next - 1
end

function Queue.Push(Held: Queue, Asked: Asked, Tell: Tell?): Item?
	if #Held.Items >= QUEUE then
		return nil
	end
	local Item: Item = { Asked = Asked, Tell = Tell, Stamp = Asked.Stamp, Dirty = false, Said = false, Done = false }
	table.insert(Held.Items, Item)
	return Item
end

function Queue.Withdraw(Held: Queue, Item: Item): boolean
	if Item.First or Item.Done then
		return false
	end
	Item.Done = true
	Held.Items = Open(Held.Items)
	return true
end

function Queue.Ride(Held: Queue, End: Requests.End)
	for Index, Riding in Held.Rides do
		if Riding.Name == End.Name then
			Held.Rides[Index] = End
			return
		end
	end
	table.insert(Held.Rides, End)
end

function Queue.Spent(Held: Queue): boolean
	local First = Held.Items[1]
	return Held.Next > SEQ_MAX and Held.Out == nil and First ~= nil and First.Seq == nil
end

function Queue.Renew(Held: Queue, Id: number)
	local First = Held.Items[1]
	assert(Held.Out == nil and (First == nil or First.Seq == nil), "Queue: Renew with a numbered op unheard")
	Held.Id = Id
	Held.Next = 1
end

function Queue.Build(Held: Queue, Clock: number): Requests.Request?
	local First = Held.Items[1]
	if Held.Out or First == nil or Queue.Spent(Held) then
		return nil
	end
	local Ops: { Op } = {}
	local Carried: { Item } = {}
	local Bytes = 0
	for _, Item in Held.Items do
		Bytes += Width(Item, Clock)
		if (Bytes > Held.TimedCap and #Ops > 0) or (Item.Seq == nil and Held.Next > SEQ_MAX) then
			break
		elseif Item.Seq == nil then
			Item.Seq = Held.Next
			Held.Next += 1
		end
		table.insert(Ops, Item.Op or OpOf(Held, Item, Clock))
		table.insert(Carried, Item)
	end
	Held.Out = Carried
	Pacing.Sent(Held.Pace, Clock)
	local Ends = if Held.Rides[1] then table.clone(Held.Rides) else nil
	return Requests.Batch(Held.Id, Queue.Ack(Held), First.Asked.MustExist, Ops, Ends)
end

function Queue.Learn(Held: Queue, Request: Requests.Request, Note: Note, Ran: { [number]: true }, Clock: number): { Fate }
	local Carried = assert(Held.Out, "Queue: Learn with no request out")
	Held.Out = nil
	local Said: { Fate } = {}
	for Index, Item in Carried do
		Item.Dirty = Item.Dirty or Ran[Request.Ops[Index].Seq] ~= nil
		Judge(Item, Index, Note, Clock, Said)
		Taint(Item)
	end
	if Note.Id then
		Held.Seen = Note.Id
	elseif Note.Why == Why.Missing and Note.Writes == 0 then
		Held.Seen = false
	end
	local Landed = Note.Stored ~= nil
	for _, Item in if Landed then Held.Items else {} do
		local View = Item.Asked.View
		if not Item.Done and Item.Asked.Form == Form.Hopeful and View and View < Note.Cuts then
			Settle(Said, Item, Answer.Refused, Fate.Turned)
		end
	end
	Held.Horizon = math.max(Held.Horizon, Note.Horizon)
	Held.Items = Open(Held.Items)
	for _, Riding in if Landed then Request.Ends or {} else {} do
		local At = table.find(Held.Rides, Riding)
		if At then
			table.remove(Held.Rides, At)
		end
	end
	return Said
end

function Queue.Failed(Held: Queue): { Fate }
	local Carried = assert(Held.Out, "Queue: Failed with no request out")
	Held.Out = nil
	Pacing.Failed(Held.Pace)
	local Said: { Fate } = {}
	for _, Item in Carried do
		Item.Dirty = true
		Taint(Item)
		Say(Said, Item, Answer.Unresolved)
	end
	return Said
end

function Queue.Unknown(Held: Queue): boolean
	return Held.Build.Erasable and Held.Seen == nil
end

function Queue.Know(Held: Queue, Value: unknown)
	local Found = Key.Read(Value)
	if Found == nil or Found == Types.Why.Missing then
		Held.Seen = false
	elseif type(Found) == "table" then
		Held.Seen = Found.Book.Id or ""
	else
		Held.Seen = ""
	end
end

function Queue.Quiet(Held: Queue, Now: number): boolean
	return not Held.Running and Held.Items[1] == nil and Now - Held.Since >= Held.Build.Minted + Windows.SKEW
end

return Queue
