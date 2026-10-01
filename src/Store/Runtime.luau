--!strict
--!optimize 2

--[=[

	Runtime: Object. What one server holds for every store: its numbers, its shown table, one queue
	per key, and the heartbeat.

	A writer's id is a server number this server never used on its key. The server holds one number
	at a time, and a bit for each key a queue under it was made on. A queue for a key whose bit is
	set takes a fresh number, which clears every bit. SaveFor gives back the one queue of a key,
	made on first use. Flush runs Save on a queue from the next frame until the queue is empty, and
	a spent queue is renewed the same way. Every landing it hears goes to the queue's Landed, and is
	a touch. Send pushes one op and waits for its reply. An op still unsent after Windows.SHED
	seconds is withdrawn and answers Busy. An op with no fate after Windows.ANSWER answers
	Unresolved. On a paced queue both waits are Windows.GAP_MAX longer. A new paced queue first
	waits a random time up to Windows.GAP_MAX. Touch runs Touch on each item of a work room that
	Touches says this server may end. It also finishes a cut's gate as its helper once Touches
	allows it. Watch puts a session on the heartbeat, a thread that beats it every Windows.BEAT
	seconds and drops each quiet queue no session holds. CloseAll releases every session, stops the
	heartbeat and flushes every queue. Server gives a number this server holds, and Draw a name no
	other call draws. Places holds every store built here. Ids keeps, for the last Limits.SHOWN_MAX
	keys, the incarnation this server last saw on each, or false when it saw no key. A new queue
	starts from it, every landing updates it, and Learn puts in what a load or a read saw. Mint
	gives a fresh id for a key a call may make. First gives the first server number this server
	took. Landing hears the write count of every landing of every queue.

	Return type: The Runtime class, with New and the methods Server, First, Draw, Mint, SaveFor, Learn,
	Flush, Send, Landed, Touch, Watch, Unwatch and CloseAll. The types are Runtime, Beating and
	Landing.
	Example usage:
		local Reply = Shared:Send(Shared:SaveFor(Ref), Asked)
--]=]

local Answer = require("../Core/Answer")
local Backoff = require("../Machine/Backoff")
local Asks = require("../Machine/Asks")
local Bits = require("../Util/Bits")
local Book = require("../Record/Book")
local Clock = require("../Machine/Clock")
local Cut = require("../Calls/Cut")
local Future = require("../Util/Future")
local Key = require("../Record/Key")
local Limits = require("../Core/Constants/Limits")
local Lru = require("../Util/Lru")
local Number = require("../Calls/Number")
local Observer = require("../Util/Observer")
local Queue = require("../Record/Queue")
local Runner = require("../Machine/Runner")
local Save = require("../Calls/Save")
local Server = require("../Adapters/Server")
local Shown = require("../Record/Shown")
local Touch = require("../Calls/Touch")
local Touches = require("../Record/Touches")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

type Queue = Queue.Queue

export type Beating = {
	Beat: (self: any, Now: number) -> (),
	Unload: (self: any, Now: number) -> Future.Future<boolean>,
}

type RuntimeImpl = {
	__index: RuntimeImpl,
	New: () -> Runtime,
	Server: (self: Runtime) -> number,
	First: (self: Runtime) -> number,
	Draw: (self: Runtime) -> string,
	Mint: (self: Runtime) -> string,
	Learn: (self: Runtime, Ref: Book.Ref, Seen: string | false) -> (),
	SaveFor: (self: Runtime, Ref: Book.Ref, UserIds: { number }?) -> Queue,
	Flush: (self: Runtime, Kept: Queue) -> Future.Future<boolean>,
	Send: (self: Runtime, Kept: Queue, Asked: Queue.Asked) -> (Queue.Reply, number?),
	Landed: (self: Runtime, Kept: Queue) -> Observer.Observer<Types.Note>,
	Touch: (self: Runtime, Ref: Book.Ref, Work: { [string]: Book.Work }, Gate: Book.Gate?) -> (),
	Watch: (self: Runtime, Player: Beating, Ref: Book.Ref) -> (),
	Unwatch: (self: Runtime, Player: Beating) -> (),
	CloseAll: (self: Runtime) -> (),
}

export type Landing = {
	read Ref: Book.Ref,
	read Writes: number,
}

type Data = {
	read Shown: Shown.Shown,
	read Places: { [string]: Asks.Place },
	read Wrote: Bits.Bits,
	read Queues: { [string]: Queue },
	read Draining: { [Queue]: Future.Future<boolean> },
	read Landings: { [Queue]: Observer.Observer<Types.Note> },
	read Watched: { [Beating]: string },
	read Held: { [string]: true },
	read Touching: { [string]: true },
	read Seen: Lru.Lru<number>,
	read Ids: Lru.Lru<string | false>,
	read Landing: Observer.Observer<Landing>,
	Taking: Future.Future<number?>?,
	Current: number?,
	Owned: number?,
	Earliest: number?,
	Counter: number,
	Ticker: thread?,
}

export type Runtime = setmetatable<Data, RuntimeImpl>

local Runtime = {} :: RuntimeImpl
Runtime.__index = Runtime

local function Where(Ref: Book.Ref): string
	return `{Ref.Store}/{Ref.Key}`
end

local function Take(Shared: Runtime): Future.Future<number?>
	return Runner.Run(Number.Machine, Number.Context(Server.JobId()), Shared.Places)
end

local function NumberFor(Shared: Runtime, Mark: string): number
	while true do
		local Asked = Shared.Taking or Take(Shared)
		Shared.Taking = Asked
		local Number = Asked:Wait() :: number
		Shared.Owned = Number
		Shared.Earliest = Shared.Earliest or Number
		if Asked ~= Shared.Taking then
			continue
		elseif Number ~= Shared.Current then
			Shared.Current = Number
			Shared.Wrote:Clear()
		end
		if not Shared.Wrote:Has(Mark) then
			Shared.Wrote:Set(Mark)
			return Number
		end
		Shared.Taking = Take(Shared)
	end
end

local function Clear(Shared: Runtime, Name: string, Item: Book.Work, Ref: Book.Ref, Mark: string)
	local Start = if Item.Form == "Pinned" then Touch.Pinned else Touch.Mark
	Runner.Run(Start, Touch.Context(Name, Item, Ref, Windows.SETTLE), Shared.Places):Wait()
	Shared.Touching[Mark] = nil
end

local function Finish(Shared: Runtime, Gate: Book.Gate, Ref: Book.Ref, Mark: string, Server: number)
	local Place = Shared.Places[Ref.Store]
	local Helper: Types.Cut = { Name = Gate.Name, Stamp = Gate.Stamp, Kind = Gate.Kind, Print = Gate.Print, Helper = true, Server = Server }
	local Context = Cut.Context(Ref, Helper, Place ~= nil and Place.Build.Erasable)
	Context.Seen = Shared.Ids:Get(Where(Ref))
	Runner.Run(Cut.Machine, Context, Shared.Places):Wait()
	Shared.Touching[Mark] = nil
end

local function Drain(Shared: Runtime, Kept: Queue, Settle: (boolean) -> ())
	local Landed = Shared:Landed(Kept)
	local function Land(Note: Types.Note)
		Landed:Push(Note)
		Shared.Landing:Push({ Ref = Kept.Ref, Writes = Note.Writes })
		if Kept.Seen ~= nil then
			Shared.Ids:Put(Where(Kept.Ref), Kept.Seen)
		end
		local Found = Key.Read(Note.Stored)
		if type(Found) == "table" then
			Shared:Touch(Kept.Ref, Found.Book.Work, Found.Book.Gate)
		end
	end
	while Kept.Items[1] do
		local Said = Runner.Run(Save.Machine, Save.Context(Kept, Land), Shared.Places):Wait()
		if Said == Save.SAID.Spent then
			Queue.Renew(Kept, NumberFor(Shared, Where(Kept.Ref)))
		end
	end
	Kept.Running = false
	Shared.Draining[Kept] = nil
	Settle(true)
end

local function Beat(Shared: Runtime)
	local Now = Clock.Now()
	for Player in Shared.Watched do
		Player:Beat(Now)
	end
	for Mark, Kept in Shared.Queues do
		if not Shared.Held[Mark] and Queue.Quiet(Kept, Now) then
			Shared.Queues[Mark] = nil
			Shared.Landings[Kept] = nil
		end
	end
end

local function Heartbeat(Shared: Runtime)
	while true do
		task.wait(Windows.BEAT)
		Beat(Shared)
	end
end

function Runtime.New(): Runtime
	local Fresh: Data = {
		Shown = Shown.New(),
		Places = {},
		Wrote = Bits.New(Limits.WROTE_BITS),
		Queues = {},
		Draining = {},
		Landings = {},
		Watched = {},
		Held = {},
		Touching = {},
		Seen = Lru.New(Limits.SHOWN_MAX),
		Ids = Lru.New(Limits.SHOWN_MAX),
		Landing = Observer.New(),
		Counter = 0,
	}
	return setmetatable(Fresh, Runtime)
end

function Runtime.Server(self: Runtime): number
	local Asked = self.Taking or Take(self)
	self.Taking = Asked
	local Number = Asked:Wait() :: number
	self.Owned = Number
	self.Earliest = self.Earliest or Number
	return Number
end

function Runtime.First(self: Runtime): number
	return self.Earliest or self:Server()
end

function Runtime.Draw(self: Runtime): string
	local Number = self:Server()
	self.Counter += 1
	return Book.Drawn(Number, self.Counter)
end

function Runtime.Mint(self: Runtime): string
	local Number = self:Server()
	self.Counter += 1
	return Book.Incarnation(Number, self.Counter)
end

function Runtime.Learn(self: Runtime, Ref: Book.Ref, Seen: string | false)
	local Mark = Where(Ref)
	self.Ids:Put(Mark, Seen)
	local Kept = self.Queues[Mark]
	if Kept then
		Kept.Seen = Seen
	end
end

function Runtime.SaveFor(self: Runtime, Ref: Book.Ref, UserIds: { number }?): Queue
	local Mark = Where(Ref)
	local Found = self.Queues[Mark]
	if Found then
		return Found
	end
	local Number = NumberFor(self, Mark)
	local Raced = self.Queues[Mark]
	if Raced then
		return Raced
	end
	local Place = assert(self.Places[Ref.Store], `Runtime: no store named {Ref.Store}`)
	local Made = Queue.New(Ref, Place.Build, Number, UserIds, Clock.Now())
	Made.Seen = self.Ids:Get(Mark)
	if Made.Pace then
		Made.Sent = Clock.Now() + Backoff.Jitter(Windows.GAP_MAX) - Made.Gap
	end
	self.Queues[Mark] = Made
	return Made
end

function Runtime.Flush(self: Runtime, Kept: Queue): Future.Future<boolean>
	local Found = self.Draining[Kept]
	if Found then
		return Found
	elseif Kept.Items[1] == nil then
		return Future.Completed(true)
	end
	local Job, Settle = Future.Pending()
	self.Draining[Kept] = Job
	Kept.Running = true
	task.defer(Drain, self, Kept, Settle)
	return Job
end

function Runtime.Send(self: Runtime, Kept: Queue, Asked: Queue.Asked): (Queue.Reply, number?)
	local Job: Future.Future<Queue.Reply?, number?>, Settle = Future.Pending()
	local function Tell(_: Queue.Asked, Reply: Queue.Reply, Code: number?)
		Settle(Reply, Code)
	end
	local Item = Queue.Push(Kept, Asked, Tell)
	if Item == nil then
		return Answer.Busy, nil
	end
	self:Flush(Kept)
	local Extra = if Kept.Pace then Windows.GAP_MAX else 0
	local Reply, Code = Job:Wait(Windows.SHED + Extra)
	if Reply ~= nil then
		return Reply, Code
	elseif Queue.Withdraw(Kept, Item) then
		return Answer.Busy, nil
	end
	Reply, Code = Job:Wait(Windows.ANSWER - Windows.SHED)
	return Reply or Answer.Unresolved, Code
end

function Runtime.Landed(self: Runtime, Kept: Queue): Observer.Observer<Types.Note>
	local Found = self.Landings[Kept]
	if Found == nil then
		Found = Observer.New()
		self.Landings[Kept] = Found
	end
	return Found
end

function Runtime.Touch(self: Runtime, Ref: Book.Ref, Work: { [string]: Book.Work }, Gate: Book.Gate?)
	local Owned = self.Owned
	if Owned == nil or (next(Work) == nil and Gate == nil) then
		return
	end
	local Now = Clock.Now()
	if Gate and self.Places[Ref.Store] then
		local Mark = `{Where(Ref)}/gate/{Gate.Name}`
		local First = self.Seen:Get(Mark) or Now
		self.Seen:Put(Mark, First)
		if not self.Touching[Mark] and Touches.Gated(Gate, Touches.Level(Owned, Gate.Name), Now, First) then
			self.Touching[Mark] = true
			task.spawn(Finish, self, Gate, Ref, Mark, Owned)
		end
	end
	for Name, Item in Work do
		local Mark = `{Where(Ref)}/{Name}`
		if self.Touching[Mark] or not Touch.Known(Item, self.Places) then
			continue
		end
		local First = self.Seen:Get(Mark) or Now
		self.Seen:Put(Mark, First)
		if Touches.Due(Item, Touches.Level(Owned, Name), Now, First) then
			self.Touching[Mark] = true
			task.spawn(Clear, self, Name, Item, Ref, Mark)
		end
	end
end

function Runtime.Watch(self: Runtime, Player: Beating, Ref: Book.Ref)
	local Mark = Where(Ref)
	self.Watched[Player] = Mark
	self.Held[Mark] = true
	if self.Ticker == nil then
		self.Ticker = task.spawn(Heartbeat, self)
	end
end

function Runtime.Unwatch(self: Runtime, Player: Beating)
	local Mark = self.Watched[Player]
	if Mark then
		self.Watched[Player] = nil
		self.Held[Mark] = nil
	end
end

function Runtime.CloseAll(self: Runtime)
	local Now = Clock.Now()
	for Player in self.Watched do
		Player:Unload(Now)
		self:Unwatch(Player)
	end
	local Ticker = self.Ticker
	if Ticker then
		self.Ticker = nil
		task.cancel(Ticker)
	end
	local Waits: { Future.Future<boolean> } = {}
	for _, Kept in self.Queues do
		if Kept.Items[1] then
			table.insert(Waits, self:Flush(Kept))
		end
	end
	for _, Job in Waits do
		Job:Wait(Windows.CLOSE)
	end
end

return Runtime
