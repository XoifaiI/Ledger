--!strict
--!optimize 2

--[=[

	Queue: Logic. The ops one server has for one key, and what each reply says of them.

	Spec: record 3.1 to 3.4. Model: Rec.tla, the writer ws[s] in Send and Hear.

	Push adds an op, with the function its reply goes to, which hears the op as it was asked.
	Withdraw takes back an op never sent. Ride keeps an end for a mark in the way, one per mark.
	Build makes the next request from every op whose fate is not heard, in order, with every ride.
	Its new timed bytes stay within a quarter of the timed room. An op is numbered and stamped when
	it is first sent, and keeps both. Learn reads a reply: each fate the note gives, and for an op
	with none, why. Only a clean op, which no failed request carried and no run decided, takes a no
	from a cancel or a horizon. A clean minted op that is forgotten or ahead is stamped again. An op
	a mark blocks or an overdue item holds up waits. A landing turns away each hopeful op judged
	before the key's last cut, and drops the rides it carried. Failed marks every op a request
	carried as not clean and answers it Unresolved. The op is still sent. Past Limits.SEQ_MAX the
	queue is Spent, and Renew starts the numbers again under a fresh id once no numbered op is left
	unheard. Quiet says whether the queue has been empty for the minted window and twice
	Windows.SIGMA. On an erasable store the queue keeps Seen, the key's id as this server last saw
	it, or false when it saw no key. Unknown says it must read the key before it sends, and Know
	takes what that read found. An op takes Seen when it is first sent and keeps it. It carries the
	id, or a create of a fresh id made from the writer and the op's number. A note that names the
	key's id, or finds no key, updates Seen. Once a request that carried a create may have written,
	the op carries that id instead.

	Spec: extras 2.3, for a paced key. A queue whose build is Paced keeps a gap. Wait gives how long
	the queue must still wait before it sends, which is the gap past its last send. Paced reads each
	landing. Once it has two landings, it measures the key's writes a minute from the change in the
	write count over its own clock. It multiplies the gap by the rate over its target, at least by
	one half, and keeps it within Windows.GAP_MIN and Windows.GAP_MAX. The target is the key's write
	ceiling at the bytes of the last landing, over Paced. A failed request waits no gap.

	Return type: A table with New, Push, Withdraw, Ride, Build, Learn, Failed, Spent, Renew, Ack,
	Quiet, Unknown, Know, Wait and Paced. The types are Queue, Asked, Item, Fate and Reply.
	Example usage:
		local Request = Queue.Build(Held, Now)
--]=]

local Answer = require("../Core/Answer")
local Book = require("./Book")
local Key = require("./Key")
local Limits = require("../Core/Constants/Limits")
local Sizes = require("../Core/Constants/Sizes")
local Types = require("./Types")
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
	Rides: { Types.End },
	Since: number,
	Running: boolean,
	Seen: (string | false)?,
	read Pace: number?,
	Gap: number,
	Sent: number?,
	Landing: { read Writes: number, read At: number }?,
}

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

local Queue = {}

local function Width(Item: Item, Clock: number): number
	local Asked = Item.Asked
	local Name = Asked.Name
	if Item.Op or Asked.Form ~= Form.Timed or Name == nil then
		return 0
	end
	return Book.NamedWidth(Name, { Kind = Asked.Kind, Stamp = Asked.Stamp or Clock, Fate = Fate.Took, Print = Asked.Print }, Clock)
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
	Made.Seq, Made.Id, Made.Create = Item.Seq, Item.Id, Item.Create
	Made.Stamp = Item.Stamp or math.max(Clock, Held.Horizon + 1)
	Item.Stamp, Item.Op = Made.Stamp, Made
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
		Item.Id, Item.Create, Item.Op = Item.Create, nil, nil
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
		Item.Stamp, Item.Op = math.max(Clock, Note.Horizon + 1), nil
		return
	elseif Reason == Why.Ahead or Reason == Why.Blocked or Reason == Why.Overdue then
		return
	elseif Reason == Why.Forgotten then
		return Settle(Said, Item, if Clean then Answer.Expired else Answer.Unresolved)
	elseif Reason == Why.Missing and Clean and Item.Create and Note.Id then
		Item.Id, Item.Create, Item.Op = Note.Id, nil, nil
		return
	end
	return Settle(Said, Item, if Clean then ENDS[Reason] else Answer.Unresolved)
end

function Queue.New(Ref: Book.Ref, Build: Types.Build, Id: number, UserIds: { number }?, Now: number): Queue
	return {
		Ref = Ref,
		Build = Build,
		UserIds = UserIds,
		TimedCap = Build.TimedRoom // Sizes.REQUEST_SHARE,
		Id = Id,
		Next = 1,
		Items = {},
		Horizon = 0,
		Rides = {},
		Since = Now,
		Running = false,
		Pace = Build.Paced,
		Gap = Windows.GAP_MAX,
	}
end

function Queue.Ack(Held: Queue): number
	local First = Held.Items[1]
	local Seq = if First then First.Seq else nil
	return if Seq then Seq - 1 else Held.Next - 1
end

function Queue.Push(Held: Queue, Asked: Asked, Tell: Tell?): Item?
	if #Held.Items >= Limits.QUEUE then
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

function Queue.Ride(Held: Queue, End: Types.End)
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
	return Held.Next > Limits.SEQ_MAX and Held.Out == nil and First ~= nil and First.Seq == nil
end

function Queue.Renew(Held: Queue, Id: number)
	local First = Held.Items[1]
	assert(Held.Out == nil and (First == nil or First.Seq == nil), "Queue: Renew with a numbered op unheard")
	Held.Id, Held.Next = Id, 1
end

function Queue.Build(Held: Queue, Clock: number): Types.Request?
	local First = Held.Items[1]
	if Held.Out or First == nil or Queue.Spent(Held) then
		return nil
	end
	local Ops: { Op } = {}
	local Carried: { Item } = {}
	local Bytes = 0
	for _, Item in Held.Items do
		Bytes += Width(Item, Clock)
		if (Bytes > Held.TimedCap and #Ops > 0) or (Item.Seq == nil and Held.Next > Limits.SEQ_MAX) then
			break
		elseif Item.Seq == nil then
			Item.Seq = Held.Next
			Held.Next += 1
		end
		table.insert(Ops, Item.Op or OpOf(Held, Item, Clock))
		table.insert(Carried, Item)
	end
	Held.Out = Carried
	Held.Sent = if Held.Pace then Clock else nil
	local Ends = if Held.Rides[1] then table.clone(Held.Rides) else nil
	return { Writer = Held.Id, Ack = Queue.Ack(Held), MustExist = First.Asked.MustExist, Ops = Ops, Ends = Ends }
end

function Queue.Learn(Held: Queue, Request: Types.Request, Note: Note, Ran: { [number]: true }, Clock: number): { Fate }
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
	Held.Out, Held.Sent = nil, nil
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

function Queue.Wait(Held: Queue, Clock: number): number
	local Sent = Held.Sent
	return if Held.Pace and Sent then math.max(Sent + Held.Gap - Clock, 0) else 0
end

function Queue.Paced(Held: Queue, Writes: number, Bytes: number, Clock: number)
	local Pace, Before = Held.Pace, Held.Landing
	if Pace == nil or (Before and Clock <= Before.At) then
		return
	end
	Held.Landing = { Writes = Writes, At = Clock }
	if Before == nil then
		return
	end
	local Rate = (Writes - Before.Writes) * Windows.MINUTE / (Clock - Before.At)
	local Target = (Sizes.KEY_CEILING // math.max(math.ceil(Bytes / Sizes.KB), 1)) / Pace
	Held.Gap = math.clamp(Held.Gap * math.max(Rate / Target, Limits.GAP_FALL), Windows.GAP_MIN, Windows.GAP_MAX)
end

function Queue.Quiet(Held: Queue, Now: number): boolean
	return not Held.Running and Held.Items[1] == nil and Now - Held.Since >= Held.Build.Minted + Windows.SKEW
end

return Queue
