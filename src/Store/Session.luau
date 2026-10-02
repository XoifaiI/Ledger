--!strict
--!optimize 2

--[=[
	Session: Object. One key as this server shows it to a game, and the hopeful ops queued on it.

	Spec: record 5.2 and 6. Model: Rec.tla, the session sv[s].

	Apply judges an op on the session's view and sends nothing. A closed session answers Closed, an
	op a datastore cannot hold Invalid, and a full queue Backlog. An op whose verdict a transaction
	mark on the view could change answers Busy. An op the reducer refuses answers Refused, and one
	that takes the state past its cap answers Full. Otherwise the op joins the key's queue with the
	view's cut count, is laid on the view, and answers true. Commit sends one durable op with the
	queued ones. A view with a higher write count is adopted with the queued ops laid on top, and
	every landing of the key is adopted. The key stays pinned in the shown table until the session
	closes. A push is due SAVE seconds after the last one while ops wait. A read is due IDLE seconds
	after the last one while none do.

	Return type: The Session class, and the Session, Due and Fate types.
	Example usage:
		local Reply = Player:Apply("SpendGold", { Amount = 25 })
--]=]

local Answer = require("../Core/Answer")
local Book = require("../Record/Book")
local Errors = require("../Core/Errors")
local Future = require("../Util/Future")
local Guard = require("../Record/Guard")
local Marks = require("../Record/Marks")
local Observer = require("../Util/Observer")
local Ops = require("../Store/Ops")
local Peek = require("../Calls/Peek")
local Queue = require("../Record/Queue")
local Reduce = require("../Core/Reduce")
local Requests = require("../Record/Requests")
local Runner = require("../Machine/Runner")
local Runtime = require("./Runtime")
local Shown = require("../Record/Shown")
local Types = require("../Record/Types")
local Value = require("../Encode/Value")
local View = require("../Record/View")

type State = { [string]: any }
type Reply = Queue.Reply

local DUE = {
	Push = "Push" :: "Push",
	Read = "Read" :: "Read",
}

export type Due = keyof<typeof(DUE)>

export type Fate = {
	read Asked: Queue.Asked,
	read Reply: Reply,
	read Code: number?,
}

type SessionImpl = {
	__index: SessionImpl,
	New: (Shared: Runtime.Runtime, Held: Queue.Queue, Loaded: View.View?, MustExist: boolean, Now: number) -> Session,
	DUE: typeof(DUE),
	SAVE: number,
	IDLE: number,
	Apply: (self: Session, Kind: string, Fields: { [string]: any }?) -> Reply,
	Commit: (self: Session, Kind: string, Fields: { [string]: any }?) -> Future.Future<Reply>,
	Adopt: (self: Session, Found: View.View) -> (),
	Due: (self: Session, Now: number) -> Due?,
	Beat: (self: Session, Now: number) -> (),
	Read: (self: Session, Now: number) -> (),
	Close: (self: Session) -> (),
	Get: (self: Session) -> State,
	Flush: (self: Session, Now: number) -> Future.Future<boolean>,
	Unload: (self: Session, Now: number) -> Future.Future<boolean>,
}

type Data = {
	read Runtime: Runtime.Runtime,
	read Queue: Queue.Queue,
	read Mark: string,
	read Shown: Shown.Shown,
	read MustExist: boolean,
	read Fates: Observer.Observer<Fate>,
	read Changed: Observer.Observer<State>,
	read Sizes: { [Queue.Asked]: number },
	read Connections: { Observer.Connection },
	read Tell: Queue.Tell,
	State: State,
	Work: { [string]: Book.Work },
	Writes: number,
	Cuts: number,
	Horizon: number,
	Id: string?,
	Queued: number,
	LastPush: number,
	LastRead: number,
	Closed: boolean,
}

export type Session = setmetatable<Data, SessionImpl>

local Form = Requests.Form

local QUEUE_BYTES = 1.5 * 1024 * 1024
local SAVE = 30
local IDLE = 120

local Session = {} :: SessionImpl
Session.__index = Session
Session.DUE = DUE
Session.SAVE = SAVE
Session.IDLE = IDLE

local function Hopeful(Item: Queue.Item): boolean
	return Item.Asked.Form == Form.Hopeful
end

local function Settled(Player: Session, Asked: Queue.Asked, Reply: Reply, Code: number?)
	Player.Queued -= Player.Sizes[Asked] or 0
	Player.Sizes[Asked] = nil
	Player.Fates:Push({ Asked = Asked, Reply = Reply, Code = Code })
end

local function Landed(Player: Session, Note: Types.Note)
	local Found = View.Read(Note.Stored, Player.Queue.Build)
	if type(Found) == "table" then
		Player:Adopt(Found)
	end
end

local function Send(Shared: Runtime.Runtime, Held: Queue.Queue, Asked: Queue.Asked): Reply
	return (Shared:Send(Held, Asked))
end

local function Refresh(Player: Session)
	local Held = Player.Queue
	local Found = Runner.Run(Peek.Cached, Peek.Context(Held.Ref, Held.Build, Player.Shown), Player.Runtime.Places):Wait()
	if type(Found) == "table" then
		Player:Adopt(Found)
		Player.Runtime:Touch(Held.Ref, Found.Work, Found.Gate)
	end
end

function Session.New(Shared: Runtime.Runtime, Held: Queue.Queue, Loaded: View.View?, MustExist: boolean, Now: number): Session
	local Player: Session
	local function Tell(Asked: Queue.Asked, Reply: Reply, Code: number?)
		Settled(Player, Asked, Reply, Code)
	end
	local Fresh: Data = {
		Runtime = Shared,
		Queue = Held,
		Mark = Book.Address(Held.Ref),
		Shown = Shared.Shown,
		MustExist = MustExist,
		Fates = Observer.New(),
		Changed = Observer.New(),
		Sizes = {},
		Connections = {},
		Tell = Tell,
		State = if Loaded then Loaded.State else Reduce.Copy(Held.Build.Default),
		Work = if Loaded then Loaded.Work else {},
		Writes = if Loaded then Loaded.Writes else 0,
		Cuts = if Loaded then Loaded.Cuts else 0,
		Horizon = if Loaded then Loaded.Horizon else 0,
		Id = if Loaded then Loaded.Id else nil,
		Queued = 0,
		LastPush = Now,
		LastRead = Now,
		Closed = false,
	}
	Player = setmetatable(Fresh, Session)
	Fresh.Shown:Pin(Fresh.Mark, Fresh.Writes)
	table.insert(
		Fresh.Connections,
		Shared:Landed(Held):Subscribe(function(Note: Types.Note)
			Landed(Player, Note)
		end)
	)
	return Player
end

function Session.Apply(self: Session, Kind: string, Fields: { [string]: any }?): Reply
	if Fields and (Fields.Once ~= nil or Fields.OnceAt ~= nil) then
		Errors.Misuse("an op with Once needs a durable call, so use Commit")
	end
	local Body = Ops.Body(Kind, Fields)
	if self.Closed then
		return Answer.Closed
	end
	local Bytes = Value.Check(Body)
	if Bytes == nil then
		return Answer.Invalid
	elseif self.Queued + Bytes > QUEUE_BYTES then
		return Answer.Backlog
	end
	local Build = self.Queue.Build
	if Marks.Order(self.Work, Build, Guard.Plain(Build), self.State, Body) then
		return Answer.Busy
	end
	local Folding = Reduce.Start(self.State, Guard.Capped(Build))
	local Took, Reason = Reduce.Apply(Folding, Body)
	if not Took then
		return if Reason == Book.Fate.Full then Answer.Full else Answer.Refused
	end
	local Asked: Queue.Asked = { Form = Form.Hopeful, Kind = 0, View = self.Cuts, MustExist = self.MustExist, Body = Body }
	if Queue.Push(self.Queue, Asked, self.Tell) == nil then
		return Answer.Backlog
	end
	self.Sizes[Asked] = Bytes
	self.Queued += Bytes
	self.State = Folding.State
	self.Changed:Push(self.State)
	return true
end

function Session.Commit(self: Session, Kind: string, Fields: { [string]: any }?): Future.Future<Reply>
	local Asked = Ops.Durable(Kind, Fields, self.MustExist)
	if self.Closed then
		return Future.Completed(Answer.Closed :: Reply)
	elseif Asked == nil then
		return Future.Completed(Answer.Invalid :: Reply)
	end
	return Future.Spawn(Send, self.Runtime, self.Queue, Asked)
end

function Session.Adopt(self: Session, Found: View.View)
	if Found.Writes <= self.Writes then
		return
	end
	local Bodies: { unknown } = {}
	for _, Item in self.Queue.Items do
		if Hopeful(Item) and not Item.Done then
			table.insert(Bodies, Item.Asked.Body)
		end
	end
	self.State = Reduce.Fold(Found.State, Bodies, Guard.Plain(self.Queue.Build))
	self.Writes = Found.Writes
	self.Cuts = Found.Cuts
	self.Horizon = Found.Horizon
	self.Id = Found.Id
	self.Work = Found.Work
	self.Shown:Show(self.Mark, Found.Writes)
	self.Changed:Push(self.State)
end

function Session.Due(self: Session, Now: number): Due?
	if self.Closed or self.Queue.Running then
		return nil
	end
	local Waiting = self.Queue.Items[1] ~= nil
	if Waiting and Now - self.LastPush >= SAVE then
		return Session.DUE.Push
	elseif not Waiting and Now - self.LastRead >= IDLE then
		return Session.DUE.Read
	end
	return nil
end

function Session.Beat(self: Session, Now: number)
	local Due = self:Due(Now)
	if Due == Session.DUE.Push then
		self:Flush(Now)
	elseif Due == Session.DUE.Read then
		self:Read(Now)
		task.spawn(Refresh, self)
	end
end

function Session.Read(self: Session, Now: number)
	self.LastRead = Now
end

function Session.Get(self: Session): State
	return self.State
end

function Session.Close(self: Session)
	if self.Closed then
		return
	end
	self.Closed = true
	self.Shown:Unpin(self.Mark)
	for _, Connection in self.Connections do
		Connection:Disconnect()
	end
end

function Session.Flush(self: Session, Now: number): Future.Future<boolean>
	self.LastPush = Now
	return self.Runtime:Flush(self.Queue)
end

function Session.Unload(self: Session, Now: number): Future.Future<boolean>
	self:Close()
	return self:Flush(Now)
end

return Session
