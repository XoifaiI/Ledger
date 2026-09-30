--!strict
--!optimize 2

--[=[

	Store: Object. The keys a config names, as a game holds them.

	New makes a store from a config. Load opens a session on a player's key and settles with true
	once it is loaded, or with why it could not be: Behind, Refused, Unresolved, or Missing when the
	store's keys must exist. A player whose load fails is kicked, unless the config's OnLoadFailed
	says it handled them. A player who leaves during their load is released once it ends. Get gives
	back a player's open session, and Expect gives it back or throws. Edit sends one durable op to any
	key and settles with its reply. An op named with Once takes effect at most once on its key: with
	OnceAt, the unix time it was first sent, for all time, and without it for its kind's window.
	DidApply says whether a name took effect: true, false only when given OnceAt, or why it cannot
	say. Peek shows a key's state, and Fresh shows it as it is now, at the cost of a write. Release
	closes a player's session and flushes it. A player who leaves is released from every store. Tx
	moves money and applies ops across keys of any stores, all or none, and settles with true or why
	not. With Once and OnceAt it takes effect at most once for all time. Without them Ledger draws the
	name, and draws it once more if the first one expires before anything was written. Pending shows
	the marks and pinned records on a key, and Resettle ends every one of them it can, now. Each
	method checks its arguments at the game's call and runs one call.

	Return type: The Store class, with New, Tx and CloseAll, and the methods Load, Get, Expect, Edit,
	DidApply, Peek, Fresh, Pending, Resettle and Release. The types are Store, Leg and Options.
	Example usage:
		local Gold = Ledger.New(Config)
		Gold:Load(Player):Wait()
		Gold:Expect(Player):Apply("SpendGold", { Amount = 25 })
--]=]

local Answer = require("../Core/Answer")
local Book = require("../Record/Book")
local Build = require("./Build")
local Clock = require("../Machine/Clock")
local DataStore = require("../Adapters/DataStore")
local DidApply = require("../Calls/DidApply")
local Errors = require("../Core/Errors")
local Future = require("../Util/Future")
local Ops = require("./Ops")
local Peek = require("../Calls/Peek")
local Queue = require("../Record/Queue")
local Resettle = require("../Calls/Resettle")
local Runner = require("../Machine/Runner")
local Runtime = require("./Runtime")
local Session = require("./Session")
local Terms = require("./Terms")
local Tx = require("../Calls/Tx")
local Types = require("../Record/Types")
local View = require("../Record/View")

type Answer = Answer.Answer
type Reply = Queue.Reply
type State = { [string]: any }
type Handler = (Player: Player, Why: Answer) -> boolean

type StoreImpl = {
	__index: StoreImpl,
	New: (Config: Build.Config) -> Store,
	Tx: (Legs: { Leg }, Options: Options?) -> Future.Future<Reply>,
	CloseAll: () -> (),
	Load: (self: Store, Player: Player) -> Future.Future<Reply>,
	Get: (self: Store, Player: Player) -> Session.Session?,
	Expect: (self: Store, Player: Player) -> Session.Session,
	Edit: (self: Store, Key: string | number, Kind: string, Fields: { [string]: any }?) -> Future.Future<Reply>,
	DidApply: (self: Store, Key: string | number, Once: string, OnceAt: number?) -> Future.Future<boolean | Answer>,
	Peek: (self: Store, Key: string | number) -> Future.Future<State | Answer>,
	Fresh: (self: Store, Key: string | number) -> Future.Future<State | Answer>,
	Pending: (self: Store, Key: string | number) -> Future.Future<{ [string]: Book.Work } | Answer>,
	Resettle: (self: Store, Key: string | number) -> Future.Future<Reply>,
	Release: (self: Store, Player: Player) -> Future.Future<boolean>,
}

type Data = {
	read Name: string,
	read Build: Types.Build,
	read Data: DataStore.Store,
	read MustExist: boolean,
	read OnLoadFailed: Handler?,
	read Sessions: { [Player]: Session.Session },
	read Loading: { [Player]: Future.Future<Reply> },
}

export type Store = setmetatable<Data, StoreImpl>

export type Leg = {
	read Store: Store,
	read Key: string | number,
	read Field: string?,
	read Amount: number?,
	read Kind: string?,
	read Fields: { [string]: any }?,
	read MustExist: boolean?,
}

export type Options = {
	read Once: string?,
	read OnceAt: number?,
	read Hot: number?,
}

local KICKED = "Your data could not load. Please rejoin."

-- TODO: is oop cleaner here over the module table? Should any funcs with self be methods? -> Join func
local Store = {} :: StoreImpl
Store.__index = Store

local Stores: { Store } = {}
local Joined = false

local function Ref(Owner: Store, Key: string | number): Book.Ref
	return { Store = Owner.Name, Key = tostring(Key) }
end

local function Read(Owner: Store, Key: string | number, Machine: typeof(Peek.Cached)): View.View | Answer
	local At = Ref(Owner, Key)
	local Found = Runner.Run(Machine, Peek.Context(At, Owner.Build, Runtime.Shown), Runtime.Places):Wait()
	if type(Found) == "table" then
		Runtime.Touch(At, Found.Work)
	end
	return Found or Answer.Unresolved
end

local function Show(Owner: Store, Key: string | number, Machine: typeof(Peek.Cached)): State | Answer
	local Found = Read(Owner, Key, Machine)
	return if type(Found) == "table" then Found.State else Found
end

local function Work(Owner: Store, Key: string | number): { [string]: Book.Work } | Answer
	local Found = Read(Owner, Key, Peek.Cached)
	return if type(Found) == "table" then Found.Work else Found
end

local function Settle(Owner: Store, Key: string | number): Reply
	local Context = Resettle.Context(Ref(Owner, Key), Owner.Build, Runtime.Shown, Clock.Now())
	return Runner.Run(Resettle.Machine, Context, Runtime.Places):Wait() or Answer.Unresolved
end

local function Ask(Of: typeof(DidApply.Reading), Context: DidApply.Context): boolean | Answer
	local Said = Runner.Run(Of, Context, Runtime.Places):Wait()
	return if Said == nil then Answer.Unresolved else Said
end

local function Send(Owner: Store, Key: string | number, Asked: Queue.Asked): Reply
	return (Runtime.Send(Runtime.SaveFor(Ref(Owner, Key)), Asked))
end

local function Transact(Made: Terms.Made, Name: string?, Stamp: number?): Reply
	local Server = Runtime.Server()
	for _ = 1, if Name then 1 else 2 do
		local Use: Tx.Use = { Name = Name or Runtime.Draw(), Stamp = Stamp or Clock.Now(), Print = Made.Print }
		local Of = if Name then Tx.Retry else Tx.Run
		local Reply = Runner.Run(Of, Tx.Context(Use, Made.Legs, Made.Decider, Server), Runtime.Places):Wait()
		if Reply ~= Answer.Expired then
			return Reply or Answer.Unresolved
		end
	end
	return Answer.Expired
end

local function Open(Owner: Store, Player: Player): Reply
	local Key = tostring(Player.UserId)
	local At = Ref(Owner, Key)
	local Found = Read(Owner, Key, if Runtime.Shown:Stale(`{At.Store}/{At.Key}`) then Peek.Fresh else Peek.Cached)
	local Loaded: View.View? = nil
	if type(Found) == "table" then
		Loaded = Found
	elseif Found ~= Answer.Missing or Owner.MustExist then
		return Found
	end
	local Opened = Session.New(Runtime.SaveFor(At, { Player.UserId }), Loaded, Owner.MustExist, Clock.Now())
	Owner.Sessions[Player] = Opened
	Runtime.Watch(Opened, At)
	return true
end

local function Failed(Owner: Store, Player: Player, Why: Answer)
	local Handle = Owner.OnLoadFailed
	if Handle then
		local Ok, Handled = pcall(Handle, Player, Why)
		if Ok and Handled == true then
			return
		elseif not Ok then
			warn(`Ledger: OnLoadFailed of {Owner.Name} threw for {Player.Name}, so they are kicked: {Handled}`)
		end
	end
	Player:Kick(KICKED)
end

local function Load(Owner: Store, Player: Player): Reply
	local Reply = Open(Owner, Player)
	Owner.Loading[Player] = nil
	if Player.Parent == nil then
		Owner:Release(Player)
	elseif Reply ~= true then
		Failed(Owner, Player, Reply)
	end
	return Reply
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
	game:GetService("Players").PlayerRemoving:Connect(Leave) -- TODO: Move services
	game:BindToClose(Runtime.CloseAll)
end

function Store.New(Config: Build.Config): Store
	Errors.OnServer("Ledger.New")
	local Made = Build.New(Config)
	if Runtime.Places[Config.Name] then
		Errors.Misuse(`a store named {Config.Name} exists already`)
	end
	local Fresh: Data = {
		Name = Config.Name,
		Build = Made,
		Data = Config.DataStore or DataStore.Open(Config.Name),
		MustExist = Config.MustExist == true,
		OnLoadFailed = Config.OnLoadFailed,
		Sessions = {},
		Loading = {},
	}
	local Owner = setmetatable(Fresh, Store)
	table.insert(Stores, Owner)
	Runtime.Places[Owner.Name] = { Store = Owner.Data, Build = Made }
	Join()
	return Owner
end

function Store.Tx(Legs: { Leg }, Options: Options?): Future.Future<Reply>
	Errors.OnServer("Tx")
	local Asked: Options = Options or {}
	local Given: { Terms.Given } = {}
	for Index, Leg in Legs do
		local Owner = Leg.Store
		if type(Owner) ~= "table" or getmetatable(Owner :: any) ~= Store then
			Errors.Misuse(`leg {Index} needs Store, a store from Ledger.New`)
		end
		Given[Index] = {
			Ref = Ref(Owner, Leg.Key),
			Place = Runtime.Places[Owner.Name],
			MustExist = if Leg.MustExist == nil then Owner.MustExist else Leg.MustExist == true,
			Field = Leg.Field,
			Amount = Leg.Amount,
			Kind = Leg.Kind,
			Fields = Leg.Fields,
		}
	end
	local Name = if Asked.Once == nil then nil else Ops.Name(Asked.Once)
	if Name and Asked.OnceAt == nil then
		Errors.Misuse("a transaction named with Once needs OnceAt, the unix time it was first sent")
	end
	local Stamp = if Name then Ops.Stamp(Asked.OnceAt) else nil
	return Future.Spawn(Transact, Terms.Make(Given, Name, Asked.Hot), Name, Stamp)
end

function Store.CloseAll()
	Runtime.CloseAll()
end

function Store.Load(self: Store, Player: Player): Future.Future<Reply>
	Errors.OnServer("Load")
	if self.Sessions[Player] then
		return Future.Completed(true :: Reply)
	end
	local Held = self.Loading[Player] or Future.Spawn(Load, self, Player)
	self.Loading[Player] = Held
	return Held
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
	local Asked = Ops.Durable(Kind, Fields, self.MustExist)
	if Asked == nil then
		return Future.Completed(Answer.Invalid :: Reply)
	end
	return Future.Spawn(Send, self, Key, Asked)
end

function Store.DidApply(self: Store, Key: string | number, Once: string, OnceAt: number?): Future.Future<boolean | Answer>
	Errors.OnServer("DidApply")
	local Name = Ops.Name(Once)
	local Stamp = if OnceAt == nil then nil else Ops.Stamp(OnceAt)
	local Of = if Stamp == nil then DidApply.Reading else DidApply.Probing
	return Future.Spawn(Ask, Of, DidApply.Context(Ref(self, Key), Name, Stamp))
end

function Store.Peek(self: Store, Key: string | number): Future.Future<State | Answer>
	Errors.OnServer("Peek")
	return Future.Spawn(Show, self, Key, Peek.Cached)
end

function Store.Fresh(self: Store, Key: string | number): Future.Future<State | Answer>
	Errors.OnServer("Fresh")
	return Future.Spawn(Show, self, Key, Peek.Fresh)
end

function Store.Pending(self: Store, Key: string | number): Future.Future<{ [string]: Book.Work } | Answer>
	Errors.OnServer("Pending")
	return Future.Spawn(Work, self, Key)
end

function Store.Resettle(self: Store, Key: string | number): Future.Future<Reply>
	Errors.OnServer("Resettle")
	return Future.Spawn(Settle, self, Key)
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
