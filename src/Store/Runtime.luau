--!strict
--!optimize 2

--[=[

	Runtime: Object. What this server holds for every store: its numbers, its shown table, one queue per
	key, and the heartbeat.

	A writer's id is a server number this server never used on its key. The server holds one number
	at a time, and a bit for each key a queue under it was made on. A queue for a key whose bit is
	set takes a fresh number, which clears every bit. SaveFor gives back the one queue of a key, made
	on first use. Flush runs Save on a queue from the next frame until the queue is empty, and a
	spent queue is renewed the same way. Every landing it hears goes to the queue's Landed, and is a
	touch. Send pushes one op and waits for its reply: an op still unsent after Windows.SHED seconds
	is withdrawn and answers Busy, and one with no fate after Windows.ANSWER answers Unresolved.
	Touch runs Touch on each item of a work room that Touches says this server may end. Watch puts a
	session on the heartbeat, which beats it every Windows.BEAT seconds and drops each quiet queue no
	session holds. CloseAll releases every session and flushes every queue. Server gives a number
	this server holds, and Draw a name no other call draws. Places holds every store built here.

	Return type: A table with Shown, Places, Server, Draw, SaveFor, Flush, Send, Landed, Touch, Watch,
	Unwatch and CloseAll. The type is Beating.
	Example usage:
		local Reply = Runtime.Send(Runtime.SaveFor(Ref), Asked)
--]=]

local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Bits = require("../Util/Bits")
local Book = require("../Record/Book")
local Clock = require("../Machine/Clock")
local Future = require("../Util/Future")
local Key = require("../Record/Key")
local Limits = require("../Core/Constants/Limits")
local Lru = require("../Util/Lru")
local Number = require("../Calls/Number")
local Observer = require("../Util/Observer")
local Queue = require("../Record/Queue")
local Runner = require("../Machine/Runner")
local Save = require("../Calls/Save")
local Shown = require("../Record/Shown")
local Touch = require("../Calls/Touch")
local Touches = require("../Record/Touches")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

type Queue = Queue.Queue

export type Beating = {
	Beat: (self: any, Now: number) -> (),
	Release: (self: any, Now: number) -> Future.Future<boolean>,
}
-- TODO: OOP, move to setinterval?
local Runtime = {}

Runtime.Shown = Shown.New()
local Places: { [string]: Asks.Place } = {}
Runtime.Places = Places

local Taking: Future.Future<number?>? = nil
local Current: number? = nil
local Owned: number? = nil
local Counter = 0
local Wrote = Bits.New(Limits.WROTE_BITS)
local Queues: { [string]: Queue } = {}
local Draining: { [Queue]: Future.Future<boolean> } = {}
local Landings: { [Queue]: Observer.Observer<Types.Note> } = {}
local Watched: { [Beating]: string } = {}
local Held: { [string]: true } = {}
local Touching: { [string]: true } = {}
local Seen: Lru.Lru<number> = Lru.New(Limits.SHOWN_MAX)
local Ticking = false

local function Where(Ref: Book.Ref): string
	return `{Ref.Store}/{Ref.Key}`
end

local function Take(): Future.Future<number?>
	return Runner.Run(Number.Machine, Number.Context(game.JobId), Places)
end

local function NumberFor(Mark: string): number
	while true do
		local Asked = Taking or Take()
		Taking = Asked
		local Number = Asked:Wait() :: number
		Owned = Number
		if Asked ~= Taking then
			continue
		elseif Number ~= Current then
			Current = Number
			Wrote:Clear()
		end
		if not Wrote:Has(Mark) then
			Wrote:Set(Mark)
			return Number
		end
		Taking = Take()
	end
end

local function Clear(Name: string, Item: Book.Work, Ref: Book.Ref, Mark: string)
	local Start = if Item.Form == "Pinned" then Touch.Pinned else Touch.Mark
	Runner.Run(Start, Touch.Context(Name, Item, Ref, Windows.SETTLE), Places):Wait()
	Touching[Mark] = nil
end

function Runtime.Touch(Ref: Book.Ref, Work: { [string]: Book.Work })
	local Server = Owned
	if Server == nil or next(Work) == nil then
		return
	end
	local Now = Clock.Now()
	for Name, Item in Work do
		local Mark = `{Where(Ref)}/{Name}`
		if Touching[Mark] or not Touch.Known(Item, Places) then
			continue
		end
		local First = Seen:Get(Mark) or Now
		Seen:Put(Mark, First)
		if Touches.Due(Item, Touches.Level(Server, Name), Now, First) then
			Touching[Mark] = true
			task.spawn(Clear, Name, Item, Ref, Mark)
		end
	end
end

function Runtime.Landed(Kept: Queue): Observer.Observer<Types.Note>
	local Found = Landings[Kept]
	if Found == nil then
		Found = Observer.New()
		Landings[Kept] = Found
	end
	return Found :: Observer.Observer<Types.Note>
end

local function Drain(Kept: Queue, Settle: (boolean) -> ())
	local Landed = Runtime.Landed(Kept)
	local function Land(Note: Types.Note)
		Landed:Push(Note)
		local Found = Key.Read(Note.Stored)
		if type(Found) == "table" then
			Runtime.Touch(Kept.Ref, Found.Book.Work)
		end
	end
	while Kept.Items[1] do
		local Said = Runner.Run(Save.Machine, Save.Context(Kept, Land), Places):Wait()
		if Said == Save.SAID.Spent then
			Queue.Renew(Kept, NumberFor(Where(Kept.Ref)))
		end
	end
	Kept.Running = false
	Draining[Kept] = nil
	Settle(true)
end

function Runtime.Flush(Kept: Queue): Future.Future<boolean>
	local Found = Draining[Kept]
	if Found then
		return Found
	elseif Kept.Items[1] == nil then
		return Future.Completed(true)
	end
	local Job, Settle = Future.Pending()
	Draining[Kept] = Job
	Kept.Running = true
	task.defer(Drain, Kept, Settle)
	return Job
end

function Runtime.Send(Kept: Queue, Asked: Queue.Asked): (Queue.Reply, number?)
	local Job: Future.Future<Queue.Reply?, number?>, Settle = Future.Pending()
	local function Tell(_: Queue.Asked, Reply: Queue.Reply, Code: number?)
		Settle(Reply, Code)
	end
	local Item = Queue.Push(Kept, Asked, Tell)
	if Item == nil then
		return Answer.Busy, nil
	end
	Runtime.Flush(Kept)
	local Reply, Code = Job:Wait(Windows.SHED)
	if Reply ~= nil then
		return Reply, Code
	elseif Queue.Withdraw(Kept, Item) then
		return Answer.Busy, nil
	end
	Reply, Code = Job:Wait(Windows.ANSWER - Windows.SHED)
	return Reply or Answer.Unresolved, Code
end

function Runtime.Server(): number
	local Asked = Taking or Take()
	Taking = Asked
	local Number = Asked:Wait() :: number
	Owned = Number
	return Number
end

function Runtime.Draw(): string
	local Number = Runtime.Server()
	Counter += 1
	return Book.Drawn(Number, Counter)
end

function Runtime.SaveFor(Ref: Book.Ref, UserIds: { number }?): Queue
	local Mark = Where(Ref)
	local Found = Queues[Mark]
	if Found then
		return Found
	end
	local Number = NumberFor(Mark)
	local Raced = Queues[Mark]
	if Raced then
		return Raced
	end
	local Place = assert(Places[Ref.Store], `Runtime: no store named {Ref.Store}`)
	local Made = Queue.New(Ref, Place.Build, Number, UserIds, Clock.Now())
	Queues[Mark] = Made
	return Made
end

local function Beat()
	local Now = Clock.Now()
	for Player in Watched do
		Player:Beat(Now)
	end
	for Mark, Kept in Queues do
		if not Held[Mark] and Queue.Quiet(Kept, Now) then
			Queues[Mark] = nil
			Landings[Kept] = nil
		end
	end
end

local function Heartbeat()
	while true do
		task.wait(Windows.BEAT)
		Beat()
	end
end

function Runtime.Watch(Player: Beating, Ref: Book.Ref)
	local Mark = Where(Ref)
	Watched[Player] = Mark
	Held[Mark] = true
	if not Ticking then
		Ticking = true
		task.spawn(Heartbeat)
	end
end

function Runtime.Unwatch(Player: Beating)
	local Mark = Watched[Player]
	if Mark then
		Watched[Player] = nil
		Held[Mark] = nil
	end
end

function Runtime.CloseAll()
	local Now = Clock.Now()
	for Player in Watched do
		Player:Release(Now)
		Runtime.Unwatch(Player)
	end
	local Waits: { Future.Future<boolean> } = {}
	for _, Kept in Queues do
		if Kept.Items[1] then
			table.insert(Waits, Runtime.Flush(Kept))
		end
	end
	for _, Job in Waits do
		Job:Wait(Windows.CLOSE)
	end
end

return Runtime
