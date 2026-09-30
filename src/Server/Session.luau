--!strict
--!optimize 2

--[=[

	Session: One key as this server shows it to a game, and the hopeful ops queued on it.

	Apply judges an op on the session's view and sends nothing. A closed session answers Closed, an op
	a datastore cannot hold Invalid, a full queue Backlog, and an op the reducer refuses Refused.
	Otherwise the op is queued in the key's Sender with the view's cut count, laid on the view, and
	answers true. Op builds the op a reducer sees: its Kind and its fields. Adopt takes a view with a
	higher write count and lays the queued ops on top, and every landed write of the key is adopted.
	Due says whether a push or an idle read is due. Fates gets one fate per hopeful op, and Changed
	the state after every change. Flush sends what is queued and settles once the key's writer runs
	empty, and Release closes the session and flushes.

	Return type: The Session class, with New, Op and DUE, and the methods Get, Apply, Adopt, Due,
	Pushed, Read, Flush, Release and Close.
	Example usage:
		local Reply = Player:Apply("SpendGold", { Amount = 25 })
--]=]

local Answer = require("../Core/Answer")
local Future = require("../Util/Future")
local Guard = require("../Record/Guard")
local Observer = require("../Util/Observer")
local Reduce = require("../Core/Reduce")
local Sender = require("./Sender")
local Sizes = require("../Core/Constants/Sizes")
local Types = require("../Record/Types")
local Value = require("../Encode/Value")
local View = require("../Record/View")
local Windows = require("../Core/Constants/Windows")
local Writer = require("./Writer")

type State = { [string]: any }

export type Due = "Push" | "Read"

type SessionImpl = {
	__index: SessionImpl,
	New: (Key: Sender.Sender, Loaded: View.View?, MustExist: boolean, Now: number) -> Session,
	DUE: { read Push: "Push", read Read: "Read" },
	Op: (Kind: string, Fields: { [string]: any }?) -> { [string]: any },
	Apply: (self: Session, Kind: string, Fields: { [string]: any }?) -> Writer.Reply,
	Adopt: (self: Session, Shown: View.View) -> (),
	Due: (self: Session, Now: number) -> Due?,
	Pushed: (self: Session, Now: number) -> (),
	Read: (self: Session, Now: number) -> (),
	Close: (self: Session) -> (),
	Get: (self: Session) -> State,
	Flush: (self: Session, Now: number) -> Future.Future<boolean>,
	Release: (self: Session, Now: number) -> Future.Future<boolean>,
}

type Data = {
	read Key: Sender.Sender,
	read MustExist: boolean,
	read Fates: Observer.Observer<Writer.Heard>,
	read Changed: Observer.Observer<State>,
	read Sizes: { [Writer.Item]: number },
	read Connections: { Observer.Connection },
	State: State,
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

local function Hopeful(Item: Writer.Item): boolean
	return Item.Asked.Form == Form.Hopeful
end

local function Heard(Player: Session, Each: Writer.Heard)
	if not Hopeful(Each.Item) then
		return
	end
	Player.Queued -= Player.Sizes[Each.Item] or 0
	Player.Sizes[Each.Item] = nil
	Player.Fates:Push(Each)
end

local function Landed(Player: Session, Note: Types.Note)
	local Shown = View.Read(Note.Stored, Player.Key.Build)
	if type(Shown) == "table" then
		Player:Adopt(Shown)
	end
end

function Session.New(Key: Sender.Sender, Loaded: View.View?, MustExist: boolean, Now: number): Session
	local Fresh: Data = {
		Key = Key,
		MustExist = MustExist,
		Fates = Observer.New(),
		Changed = Observer.New(),
		Sizes = {},
		Connections = {},
		State = if Loaded then Loaded.State else Reduce.Copy(Key.Build.Default),
		Writes = if Loaded then Loaded.Writes else 0,
		Cuts = if Loaded then Loaded.Cuts else 0,
		Horizon = if Loaded then Loaded.Horizon else 0,
		Id = if Loaded then Loaded.Id else nil,
		Queued = 0,
		LastPush = Now,
		LastRead = Now,
		Closed = false,
	}
	local Player = setmetatable(Fresh, Session)
	table.insert(
		Fresh.Connections,
		Key.Heard:Subscribe(function(Each: Writer.Heard)
			Heard(Player, Each)
		end)
	)
	table.insert(
		Fresh.Connections,
		Key.Landed:Subscribe(function(Note: Types.Note)
			Landed(Player, Note)
		end)
	)
	return Player
end

Session.DUE = { Push = "Push", Read = "Read" }

function Session.Op(Kind: string, Fields: { [string]: any }?): { [string]: any }
	local Body = if Fields then table.clone(Fields) else {}
	Body.Kind = Kind
	return Body
end

function Session.Apply(self: Session, Kind: string, Fields: { [string]: any }?): Writer.Reply
	local Body = Session.Op(Kind, Fields)
	if self.Closed then
		return Answer.Closed
	end
	local Bytes = Value.Check(Body)
	if Bytes == nil then
		return Answer.Invalid
	elseif self.Queued + Bytes > Sizes.QUEUE_BYTES then
		return Answer.Backlog
	end
	local Folding = Reduce.Start(self.State, Guard.Plain(self.Key.Build))
	if not (Reduce.Apply(Folding, Body)) then
		return Answer.Refused
	end
	local Item = self.Key:Queue({ Form = Form.Hopeful, Kind = 0, View = self.Cuts, MustExist = self.MustExist, Body = Body })
	if Item == nil then
		return Answer.Backlog
	end
	self.Sizes[Item] = Bytes
	self.Queued += Bytes
	self.State = Folding.State
	self.Changed:Push(self.State)
	return true
end

function Session.Adopt(self: Session, Shown: View.View)
	if Shown.Writes <= self.Writes then
		return
	end
	local Bodies: { unknown } = {}
	for _, Item in self.Key.Writer.Items do
		if Hopeful(Item) and not Item.Done then
			table.insert(Bodies, Item.Asked.Body)
		end
	end
	self.State = Reduce.Fold(Shown.State, Bodies, Guard.Plain(self.Key.Build))
	self.Writes, self.Cuts, self.Horizon, self.Id = Shown.Writes, Shown.Cuts, Shown.Horizon, Shown.Id
	self.Changed:Push(self.State)
end

function Session.Due(self: Session, Now: number): Due?
	if self.Closed or self.Key.Running then
		return nil
	end
	local Waiting = self.Key.Writer.Items[1] ~= nil
	if Waiting and Now - self.LastPush >= Windows.SAVE then
		return Session.DUE.Push
	elseif not Waiting and Now - self.LastRead >= Windows.IDLE then
		return Session.DUE.Read
	end
	return nil
end

function Session.Pushed(self: Session, Now: number)
	self.LastPush = Now
end

function Session.Read(self: Session, Now: number)
	self.LastRead = Now
end

function Session.Get(self: Session): State
	return self.State
end

function Session.Close(self: Session)
	self.Closed = true
	for _, Connection in self.Connections do
		Connection:Disconnect()
	end
end

function Session.Flush(self: Session, Now: number): Future.Future<boolean>
	self.LastPush = Now
	if self.Key.Writer.Items[1] == nil then
		return Future.Completed(true)
	end
	local Job, Settle = Future.Pending()
	local Connection: Observer.Connection
	Connection = self.Key.Emptied:Subscribe(function()
		Connection:Disconnect()
		Settle(true)
	end)
	self.Key:Flush()
	return Job
end

function Session.Release(self: Session, Now: number): Future.Future<boolean>
	self:Close()
	return self:Flush(Now)
end

return Session
