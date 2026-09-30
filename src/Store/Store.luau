--!strict
--!optimize 2

--[=[

	Store: The keys a config names, as a game holds them.

	New makes a store from a config. Load opens a session on a player's key and settles with true
	once it is loaded, or with why it could not be: Behind, Refused, Unresolved, or Missing when the
	store's keys must exist. Get gives back a player's open session, and Expect gives it back or
	throws. Edit sends one durable op to any key and settles with its reply. Peek shows a key's state,
	and Fresh shows it as it is now, at the cost of a write. Release closes a player's session and
	flushes it. A player who leaves is released from every store.

	Return type: The Store class, with New and CloseAll, and the methods Load, Get, Expect, Edit, Peek,
	Fresh and Release.
	Example usage:
		local Gold = Ledger.New(Config)
		Gold:Load(Player):Wait()
		Gold:Expect(Player):Apply("SpendGold", { Amount = 25 })
--]=]

local Answer = require("../Core/Answer")
local Build = require("./Build")
local Clock = require("../Server/Clock")
local DataStore = require("../Adapters/DataStore")
local Driver = require("../Server/Driver")
local Errors = require("../Core/Errors")
local Future = require("../Util/Future")
local Peek = require("../Server/Peek")
local Runtime = require("./Runtime")
local Session = require("../Server/Session")
local Types = require("../Record/Types")
local View = require("../Record/View")
local Writer = require("../Server/Writer")

type Answer = Answer.Answer
type Reply = Writer.Reply
type State = { [string]: any }

type StoreImpl = {
	__index: StoreImpl,
	New: (Config: Build.Config) -> Store,
	CloseAll: () -> (),
	Load: (self: Store, Player: Player) -> Future.Future<Reply>,
	Get: (self: Store, Player: Player) -> Session.Session?,
	Expect: (self: Store, Player: Player) -> Session.Session,
	Edit: (self: Store, Key: string | number, Kind: string, Fields: { [string]: any }?) -> Future.Future<Reply>,
	Peek: (self: Store, Key: string | number) -> Future.Future<State | Answer>,
	Fresh: (self: Store, Key: string | number) -> Future.Future<State | Answer>,
	Release: (self: Store, Player: Player) -> Future.Future<boolean>,
}

type Data = {
	read Name: string,
	read Build: Types.Build,
	read Data: DataStore.Store,
	read MustExist: boolean,
	read Sessions: { [Player]: Session.Session },
}

export type Store = setmetatable<Data, StoreImpl>

local Form = Types.Form

local Store = {} :: StoreImpl
Store.__index = Store

local Stores: { Store } = {}
local Joined = false

local function Mark(Owner: Store, Key: string): string
	return `{Owner.Name}/{Key}`
end

local function Watch(Owner: Store, Key: string): Runtime.Watch
	return { Store = Owner.Data, Name = Key, Mark = Mark(Owner, Key), Build = Owner.Build }
end

local function Show(Owner: Store, Key: string, Machine: typeof(Peek.Cached)): State | Answer
	local Entry = Watch(Owner, Key)
	local Found = Driver.Run(Machine, Peek.Context(Entry.Store, Key, Entry.Mark, Owner.Build, Runtime.Shown)):Wait()
	if Found == nil then
		return Answer.Unresolved
	elseif type(Found) == "table" then
		return Found.State
	end
	return Found
end

local function Open(Owner: Store, Player: Player): Reply
	local Key = tostring(Player.UserId)
	local Entry = Watch(Owner, Key)
	local Start = if Runtime.Shown:Stale(Entry.Mark) then Peek.Fresh else Peek.Cached
	local Found = Driver.Run(Start, Peek.Context(Owner.Data, Key, Entry.Mark, Owner.Build, Runtime.Shown)):Wait()
	local Loaded: View.View? = nil
	if type(Found) == "table" then
		Loaded = Found
	elseif Found ~= Answer.Missing or Owner.MustExist then
		return Found or Answer.Unresolved
	end
	local Sender = Runtime.SenderFor(Owner.Data, Key, Entry.Mark, Owner.Build, { Player.UserId })
	local Opened = Session.New(Sender, Loaded, Owner.MustExist, Clock.Now())
	Owner.Sessions[Player] = Opened
	Runtime.Watch(Opened, Entry)
	return true
end

local function Leave(Player: Player)
	for _, Owner in Stores do
		if Owner.Sessions[Player] then
			Owner:Release(Player)
		end
	end
end

local function Join()
	if Joined then
		return
	end
	Joined = true
	game:GetService("Players").PlayerRemoving:Connect(Leave)
	game:BindToClose(Runtime.CloseAll)
end

function Store.New(Config: Build.Config): Store
	Errors.OnServer("Ledger.New")
	local Made = Build.New(Config)
	local Fresh: Data = {
		Name = Config.Name,
		Build = Made,
		Data = Config.DataStore or DataStore.Open(Config.Name),
		MustExist = Config.MustExist == true,
		Sessions = {},
	}
	local Owner = setmetatable(Fresh, Store)
	table.insert(Stores, Owner)
	Join()
	return Owner
end

function Store.CloseAll()
	Runtime.CloseAll()
end

function Store.Load(self: Store, Player: Player): Future.Future<Reply>
	Errors.OnServer("Load")
	if self.Sessions[Player] then
		return Future.Completed(true :: Reply)
	end
	local Job, Settle = Future.Pending()
	task.spawn(function()
		Settle(Open(self, Player))
	end)
	return Job
end

function Store.Get(self: Store, Player: Player): Session.Session?
	return self.Sessions[Player]
end

function Store.Expect(self: Store, Player: Player): Session.Session
	local Held = self.Sessions[Player]
	if Held == nil then
		Errors.Misuse(`{Player.Name} has no loaded session in {self.Name}. call Load first`)
	end
	return Held :: Session.Session
end

function Store.Edit(self: Store, Key: string | number, Kind: string, Fields: { [string]: any }?): Future.Future<Reply>
	Errors.OnServer("Edit")
	local Name = tostring(Key)
	local Job, Settle = Future.Pending()
	task.spawn(function()
		local Entry = Watch(self, Name)
		local Sender = Runtime.SenderFor(self.Data, Name, Entry.Mark, self.Build)
		local Item = Sender:Push({ Form = Form.Minted, Kind = 0, MustExist = self.MustExist, Body = Session.Op(Kind, Fields) })
		Settle((Sender:Wait(Item)))
	end)
	return Job
end

function Store.Peek(self: Store, Key: string | number): Future.Future<State | Answer>
	Errors.OnServer("Peek")
	local Job, Settle = Future.Pending()
	task.spawn(function()
		Settle(Show(self, tostring(Key), Peek.Cached))
	end)
	return Job
end

function Store.Fresh(self: Store, Key: string | number): Future.Future<State | Answer>
	Errors.OnServer("Fresh")
	local Job, Settle = Future.Pending()
	task.spawn(function()
		Settle(Show(self, tostring(Key), Peek.Fresh))
	end)
	return Job
end

function Store.Release(self: Store, Player: Player): Future.Future<boolean>
	local Held = self.Sessions[Player]
	if Held == nil then
		return Future.Completed(true)
	end
	self.Sessions[Player] = nil
	Runtime.Unwatch(Held)
	return Held:Release(Clock.Now())
end

return Store
