--!strict
--!optimize 2

--[=[

	Session: Object. One key as this server shows it to a game, and the hopeful ops queued on it.

	Spec: record 5.2 and 6. Model: Rec.tla, the session sv[s].

	Apply judges an op on the session's view and sends nothing. A closed session answers Closed, an op
	a datastore cannot hold Invalid, a full queue Backlog, an op whose verdict a transaction mark on
	the view could change Busy, and an op the reducer refuses Refused. Otherwise the op joins the
	key's queue with the view's cut count, is laid on the view, and answers true. Commit sends one
	durable op with the queued ones and settles with its reply. Adopt takes a view with a higher
	write count, lays the queued ops on top and shows it, and every landing of the key is adopted.
	The key stays pinned in the shown table until the session closes. Due says whether a push or an
	idle read is due, and Beat does it. Fates gets one fate per hopeful op, and Changed the state
	after every change. Flush sends what is queued and settles once the queue is empty, and Release
	closes the session and flushes.

	Return type: The Session class, with New and DUE, and the methods Get, Apply, Commit, Adopt, Due,
	Beat, Read, Flush, Release and Close. The types are Session, Due and Fate.
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
local Runner = require("../Machine/Runner")
local Runtime = require("./Runtime")
local Shown = require("../Record/Shown")
local Sizes = require("../Core/Constants/Sizes")
local Types = require("../Record/Types")
local Value = require("../Encode/Value")
local View = require("../Record/View")
local Windows = require("../Core/Constants/Windows")

type State = { [string]: any }
type Reply = Queue.Reply

export type Due = "Push" | "Read"

export type Fate = {
	read Asked: Queue.Asked,
	read Reply: Reply,
	read Code: number?,
}

type SessionImpl = {
	__index: SessionImpl,
	New: (Held: Queue.Queue, Loaded: View.View?, MustExist: boolean, Now: number) -> Session,
	DUE: { read Push: "Push", read Read: "Read" },
	Apply: (self: Session, Kind: string, Fields: { [string]: any }?) -> Reply,
	Commit: (self: Session, Kind: string, Fields: { [string]: any }?) -> Future.Future<Reply>,
	Adopt: (self: Session, Found: View.View) -> (),
	Due: (self: Session, Now: number) -> Due?,
	Beat: (self: Session, Now: number) -> (),
	Read: (self: Session, Now: number) -> (),
	Close: (self: Session) -> (),
	Get: (self: Session) -> State,
	Flush: (self: Session, Now: number) -> Future.Future<boolean>,
	Release: (self: Session, Now: number) -> Future.Future<boolean>,
}

type Data = {
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

local Form = Types.Form

local Session = {} :: SessionImpl
Session.__index = Session

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

local function Refresh(Player: Session)
	local Held = Player.Queue
	local Found = Runner.Run(Peek.Cached, Peek.Context(Held.Ref, Held.Build, Player.Shown), Runtime.Places):Wait()
	if type(Found) == "table" then
		Player:Adopt(Found)
		Runtime.Touch(Held.Ref, Found.Work)
	end
end

function Session.New(Held: Queue.Queue, Loaded: View.View?, MustExist: boolean, Now: number): Session
	local Player: Session
	local function Tell(Asked: Queue.Asked, Reply: Reply, Code: number?)
		Settled(Player, Asked, Reply, Code)
	end
	local Fresh: Data = {
		Queue = Held,
		Mark = `{Held.Ref.Store}/{Held.Ref.Key}`,
		Shown = Runtime.Shown,
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
		Runtime.Landed(Held):Subscribe(function(Note: Types.Note)
			Landed(Player, Note)
		end)
	)
	return Player
end

Session.DUE = { Push = "Push", Read = "Read" }

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
	elseif self.Queued + Bytes > Sizes.QUEUE_BYTES then
		return Answer.Backlog
	end
	local Build = self.Queue.Build
	if Marks.Order(self.Work, Build, Guard.Plain(Build), self.State, Body) then
		return Answer.Busy
	end
	local Folding = Reduce.Start(self.State, Guard.Plain(Build))
	if not (Reduce.Apply(Folding, Body)) then
		return Answer.Refused
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
	local Held = self.Queue
	local Job, Settle = Future.Pending()
	task.spawn(function() -- TODO: Use future here?
		Settle((Runtime.Send(Held, Asked)))
	end)
	return Job
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
	self.Writes, self.Cuts, self.Horizon, self.Id = Found.Writes, Found.Cuts, Found.Horizon, Found.Id
	self.Work = Found.Work
	self.Shown:Show(self.Mark, Found.Writes)
	self.Changed:Push(self.State)
end

function Session.Due(self: Session, Now: number): Due?
	if self.Closed or self.Queue.Running then
		return nil
	end
	local Waiting = self.Queue.Items[1] ~= nil
	if Waiting and Now - self.LastPush >= Windows.SAVE then
		return Session.DUE.Push
	elseif not Waiting and Now - self.LastRead >= Windows.IDLE then
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
	return Runtime.Flush(self.Queue)
end

function Session.Release(self: Session, Now: number): Future.Future<boolean>
	self:Close()
	return self:Flush(Now)
end

return Session
