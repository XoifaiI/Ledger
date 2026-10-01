--!strict
--!optimize 2

--[=[

	Store: Object. The keys a config names, as a game holds them.

	New makes a store from a config. Load opens a session on a player's key and settles with true
	once it is loaded. Else it settles with Behind, Refused, Unresolved, or Missing when the store's
	keys must exist. A player whose load fails is kicked, unless the config's OnLoadFailed says it
	handled them. A player who leaves during their load is released once it ends. Get gives back a
	player's open session, and Expect gives it back or throws. Edit sends one durable op to any key
	and settles with its reply. An op named with Once takes effect at most once on its key. With
	OnceAt, the unix time it was first sent, this holds for all time. Without OnceAt, it holds for
	its kind's window. DidApply says whether a name took effect: true, false only when given OnceAt,
	or why it cannot say. Peek shows a key's state, and Fresh shows it as it is now, at the cost of
	a write. Peek with a MaxAge answers from the state this server last showed of the key when that
	state is young enough. Else it reads the key's copy in MemoryStore. Follow calls a function with
	the key's state each time its copy shows a newer one. It calls it at once with the last state
	shown. It stops when the connection it gives back is disconnected. Stale calls a function with a
	followed key each time a write of this server lands on it past the state its copy shows. Unload
	closes a player's session and flushes it, and the game calls it when the player leaves. Tx moves
	money and applies ops across keys of any stores, all or none, and settles with true or why not.
	With Once and OnceAt it takes effect at most once for all time. Without them Ledger draws the
	name, and draws it once more if the first one expires before anything was written. Pending shows
	the marks and pinned records on a key, and Resettle ends every one of them it can, now. Reset
	puts a key back to its default, or to the state it is given, and names the money it destroyed on
	the key. Erase takes a key and its copy off, on a store whose keys may be erased. It answers
	true with the namings of what it destroyed, which Ledger keeps nowhere else. Losses gives back
	every naming a key holds. A cut with no name has one drawn, and drawn once more if it expires
	before anything was written. Bump adds a whole amount to a total the config declares, on this
	server's home shard. With Once and OnceAt, it goes to the shard its name hashes to, at most
	once. It answers as Edit does. Total gives a total's sum no older than MaxAge, or why it cannot.
	Every method but Bump and Total throws on a key that starts with $T:, which holds the shards of
	totals. Each method checks its arguments at the game's call and runs one call.

	Return type: The Store class, with New, Tx and CloseAll, and the methods Load, Get, Expect, Edit,
	DidApply, Peek, Fresh, Follow, Stale, Pending, Resettle, Reset, Erase, Losses, Bump, Total and
	Unload. The types are Store, Leg, Options, CutOptions, BumpOptions and Naming.
	Example usage:
		local Gold = Ledger.New(Config)
		Gold:Load(Player):Wait()
		Gold:Expect(Player):Apply("SpendGold", { Amount = 25 })
--]=]

local Answer = require("../Core/Answer")
local Backoff = require("../Machine/Backoff")
local Book = require("../Record/Book")
local Alphabet = require("../Encode/Alphabet")
local Build = require("./Build")
local Clock = require("../Machine/Clock")
local Copies = require("../Record/Copies")
local Copy = require("../Calls/Copy")
local Cut = require("../Calls/Cut")
local DataStore = require("../Adapters/DataStore")
local DidApply = require("../Calls/DidApply")
local Errors = require("../Core/Errors")
local Future = require("../Util/Future")
local Guard = require("../Record/Guard")
local Limits = require("../Core/Constants/Limits")
local Lru = require("../Util/Lru")
local Observer = require("../Util/Observer")
local Ops = require("./Ops")
local Peek = require("../Calls/Peek")
local Queue = require("../Record/Queue")
local Resettle = require("../Calls/Resettle")
local Runner = require("../Machine/Runner")
local Runtime = require("./Runtime")
local Session = require("./Session")
local Sizes = require("../Core/Constants/Sizes")
local Terms = require("./Terms")
local Total = require("../Calls/Total")
local Totals = require("../Record/Totals")
local Tx = require("../Calls/Tx")
local Types = require("../Record/Types")
local Value = require("../Encode/Value")
local View = require("../Record/View")
local Windows = require("../Core/Constants/Windows")

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
	Peek: (self: Store, Key: string | number, MaxAge: number?) -> Future.Future<State | Answer>,
	Follow: (self: Store, Key: string | number, Listener: (State: State) -> ()) -> Observer.Connection,
	Stale: (self: Store, Listener: (Key: string) -> ()) -> Observer.Connection,
	Fresh: (self: Store, Key: string | number) -> Future.Future<State | Answer>,
	Pending: (self: Store, Key: string | number) -> Future.Future<{ [string]: Book.Work } | Answer>,
	Resettle: (self: Store, Key: string | number) -> Future.Future<Reply>,
	Reset: (self: Store, Key: string | number, Options: CutOptions?) -> Future.Future<Reply>,
	Erase: (self: Store, Key: string | number, Options: CutOptions?) -> Future.Future<Reply, { Naming }?>,
	Losses: (self: Store, Key: string | number) -> Future.Future<{ Naming } | Answer>,
	Bump: (self: Store, Total: string, Amount: number, Options: BumpOptions?) -> Future.Future<Reply>,
	Total: (self: Store, Total: string, MaxAge: number?) -> Future.Future<number | Answer>,
	Unload: (self: Store, Player: Player) -> Future.Future<boolean>,
}

type Data = {
	read Name: string,
	read Build: Types.Build,
	read Data: DataStore.Store,
	read MustExist: boolean,
	read OnLoadFailed: Handler?,
	read Sessions: { [Player]: Session.Session },
	read Loading: { [Player]: Future.Future<Reply> },
	read Totals: { [string]: Totals.Held },
	read Copies: Lru.Lru<Kept>,
}

type Kept = {
	read Held: Copies.Held,
	read Watch: Observer.Observer<State>,
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

export type CutOptions = {
	read Once: string?,
	read OnceAt: number?,
	read State: State?,
}

export type BumpOptions = {
	read Once: string?,
	read OnceAt: number?,
}

export type Naming = {
	read Cause: "Reset" | "Erase" | "Returned" | "Orphan" | "Folded",
	read Name: string?,
	read At: number,
	read Amounts: { [string]: number },
	read Count: number?,
	read Key: string?,
}

type Cause = "Reset" | "Erase" | "Returned" | "Orphan"

local CAUSES: { [number]: Cause } = {
	[Book.Cause.Reset] = "Reset",
	[Book.Cause.Erase] = "Erase",
	[Book.Cause.Returned] = "Returned",
	[Book.Cause.Orphan] = "Orphan",
}

local KICKED = "Your data could not load. Please rejoin."

local Store = {} :: StoreImpl
Store.__index = Store

local Shared = Runtime.New()
local Hooked: { [Queue.Queue]: true } = setmetatable({}, { __mode = "k" }) :: any

local RESERVED = { Totals.PREFIX }

local function Keyed(Key: string | number)
	for _, Prefix in RESERVED do
		if type(Key) == "string" and string.sub(Key, 1, #Prefix) == Prefix then
			Errors.Misuse(`the key {Key} starts with {Prefix}, which Ledger keeps for itself`, 1)
		end
	end
end

local function Ref(Owner: Store, Key: string | number): Book.Ref
	return { Store = Owner.Name, Key = tostring(Key) }
end

local function Read(Owner: Store, Key: string | number, Machine: typeof(Peek.Cached)): View.View | Answer
	local At = Ref(Owner, Key)
	local Found = Runner.Run(Machine, Peek.Context(At, Owner.Build, Shared.Shown), Shared.Places):Wait()
	if type(Found) == "table" then
		Shared:Touch(At, Found.Work, Found.Gate)
		Shared:Learn(At, Found.Id or "")
	elseif Found == Answer.Missing then
		Shared:Learn(At, false)
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
	local Context = Resettle.Context(Ref(Owner, Key), Owner.Build, Shared.Shown, Clock.Now())
	return Runner.Run(Resettle.Machine, Context, Shared.Places):Wait() or Answer.Unresolved
end

local function Ask(Of: typeof(DidApply.Reading), Context: DidApply.Context): boolean | Answer
	local Said = Runner.Run(Of, Context, Shared.Places):Wait()
	return if Said == nil then Answer.Unresolved else Said
end

local function Send(Owner: Store, Key: string | number, Asked: Queue.Asked): Reply
	return (Shared:Send(Shared:SaveFor(Ref(Owner, Key)), Asked))
end

local function Transact(Made: Terms.Made, Name: string?, Stamp: number?): Reply
	local Number = Shared:Server()
	for _ = 1, if Name then 1 else Limits.DRAWS do
		local Use: Tx.Use = { Name = Name or Shared:Draw(), Stamp = Stamp or Clock.Now(), Print = Made.Print }
		local Of = if Name then Tx.Retry else Tx.Run
		local Ids: { [number]: string | false } = {}
		for Index, Leg in Made.Legs do
			local Seen = if Leg.Erasable then Shared.Ids:Get(`{Leg.Ref.Store}/{Leg.Ref.Key}`) else nil
			if Seen ~= nil then
				Ids[Index] = Seen
			end
		end
		local Context = Tx.Context(Use, Made.Legs, Made.Decider, Number, Ids, Shared:Mint())
		local Reply = Runner.Run(Of, Context, Shared.Places):Wait()
		for Index, Seen in Context.Ids do
			if Seen then
				Shared:Learn(Made.Legs[Index].Ref, Seen)
			end
		end
		if Reply ~= Answer.Expired then
			return Reply or Answer.Unresolved
		end
	end
	return Answer.Expired
end

local function Field(Owner: Store, Index: number): string
	return Owner.Build.Money[Index] or `#{Index}`
end

local function Named(Owner: Store, Events: { Book.Event }, Slots: { Book.Slot }): { Naming }
	local Found: { Naming } = {}
	for _, Event in Events do
		local Amounts: { [string]: number } = {}
		for Index, Amount in Event.Amounts do
			Amounts[Field(Owner, Index)] = Amount
		end
		local Other = Event.Ref
		table.insert(Found, {
			Cause = CAUSES[Event.Cause],
			Name = if string.sub(Event.Name, 1, 1) == Book.DRAWN then nil else Event.Name,
			At = Event.Stamp + Limits.EPOCH,
			Amounts = Amounts,
			Key = if Other then `{Other.Store}/{Other.Key}` else nil,
		})
	end
	for _, Slot in Slots do
		local Amounts: { [string]: number } = {}
		for Index, Sum in Slot.Sums do
			Amounts[Field(Owner, Index)] = Sum.High * Alphabet.LIMB + Sum.Low
		end
		local Folded: Naming = { Cause = "Folded", At = Slot.Period * Windows.FOLD_SPAN + Limits.EPOCH, Amounts = Amounts, Count = Slot.Count }
		table.insert(Found, Folded)
	end
	return Found
end

local function Losses(Owner: Store, Key: string | number): { Naming } | Answer
	local Found = Read(Owner, Key, Peek.Cached)
	if type(Found) ~= "table" then
		return Found
	end
	return Named(Owner, Found.Events or {}, Found.Slots or {})
end

local function Cutting(Owner: Store, Key: string | number, Kind: number, Name: string?, Stamp: number?, Given: State?): (Reply, { Naming }?)
	local At = Ref(Owner, Key)
	local Mark = `{At.Store}/{At.Key}`
	local Erasable = Owner.Build.Erasable
	local Print = if Name then Ops.Print({ Kind = Kind, State = Given }) else nil
	local Number = Shared:Server()
	for _ = 1, if Name then 1 else Limits.DRAWS do
		local Asked: Types.Cut = { Name = Name or Shared:Draw(), Stamp = Stamp or Clock.Now(), Kind = Kind, Print = Print, Helper = false, Server = Number, State = Given }
		local Context = Cut.Context(At, Asked, Erasable)
		Context.Seen = if Erasable then Shared.Ids:Get(Mark) else nil
		local Result = Runner.Run(Cut.Machine, Context, Shared.Places):Wait()
		local Seen = Context.Seen
		if Seen then
			Shared:Learn(At, Seen)
		end
		if Result == nil then
			return Answer.Unresolved, nil
		elseif Result.Reply ~= Answer.Expired then
			local Seal = Result.Seal
			if Kind == Book.Cause.Erase and Result.Reply == true then
				Shared:Learn(At, false)
				Runner.Run(Copy.Clear, Copies.New(At), Shared.Places):Wait()
			end
			return Result.Reply, if Seal then Named(Owner, Seal.Events, Seal.Slots) else nil
		end
	end
	return Answer.Expired, nil
end

local function Bumped(Held: Totals.Held, Amount: number, Name: string?, Stamp: number?): Reply
	local Index = if Name then Totals.Named(Name, Held.Shards) else Totals.Home(Held.Name, Shared:First(), Held.Shards)
	local Kept = Shared:SaveFor({ Store = Held.Place, Key = Totals.Key(Held.Name, Held.Shards, Index) })
	if not Hooked[Kept] then
		Hooked[Kept] = true
		Shared:Landed(Kept):Subscribe(function(Note: Types.Note)
			Totals.Take(Held, Index, Totals.Noted(Note))
		end)
	end
	local Body = { Add = Amount }
	local Asked: Queue.Asked = if Name
		then {
			Form = Types.Form.Timed,
			Kind = 0,
			Name = Name,
			Print = Ops.Print({ Total = Held.Name, Amount = Amount }),
			Stamp = Stamp,
			MustExist = false,
			Body = Body,
		}
		else { Form = Types.Form.Minted, Kind = 0, MustExist = false, Body = Body }
	return (Shared:Send(Kept, Asked))
end

local function Lapse(): number
	return Windows.LAPSE + Backoff.Jitter(Windows.JITTER)
end

local function Copied(Owner: Store, Key: string | number): Kept
	local Name = tostring(Key)
	local Found = Owner.Copies:Get(Name)
	if Found == nil then
		Found = { Held = Copies.New(Ref(Owner, Key)), Watch = Observer.New() }
		Owner.Copies:Put(Name, Found)
	end
	return Found :: Kept
end

local function Following(Owner: Store, Found: Kept)
	local Watch = Found.Watch
	local Context = Copy.Context(Found.Held, Owner.Build, Shared.Shown, Shared:Server(), Lapse())
	Context.Followed = function(): boolean
		return Watch:Count() > 0
	end
	Context.Show = function(State: State)
		Watch:Push(State)
	end
	Runner.Run(Copy.Follow, Context, Shared.Places)
end

local function Glance(Owner: Store, Key: string | number, MaxAge: number): State | Answer
	local Found = Copied(Owner, Key)
	local Context = Copy.Context(Found.Held, Owner.Build, Shared.Shown, Shared:Server(), Lapse())
	Context.Once, Context.MaxAge = true, MaxAge
	Context.Show = function(State: State)
		Found.Watch:Push(State)
	end
	local Shown = Runner.Run(Copy.Follow, Context, Shared.Places):Wait()
	return if Shown == nil then Answer.Unresolved else Shown
end

local function Summed(Held: Totals.Held, MaxAge: number): number | Answer
	local Found = Runner.Run(Total.Machine, Total.Context(Held, MaxAge, Shared:Server(), Lapse()), Shared.Places):Wait()
	return if Found == nil then Answer.Unresolved else Found
end

local function Checked(Owner: Store, State: unknown): State?
	if State == nil then
		return nil
	end
	local Bytes = if type(State) == "table" then Value.Check(State) else nil
	if type(State) ~= "table" or Bytes == nil or Bytes > math.min(Owner.Build.StateCap, Sizes.RESET_MAX) then
		Errors.Misuse(`the State of a Reset of {Owner.Name} is not a table a datastore can hold within {Sizes.RESET_MAX} bytes`, 1)
	elseif not Guard.Admits(Owner.Build, {}, State :: State) then
		Errors.Misuse(`the State of a Reset of {Owner.Name} holds a field the store does not declare, or a money field that is not a whole number`, 1)
	end
	return State :: State
end

local function CutName(Options: CutOptions?): (string?, number?)
	local Asked: CutOptions = Options or {}
	local Name = if Asked.Once == nil then nil else Ops.Name(Asked.Once)
	if Name and Asked.OnceAt == nil then
		Errors.Misuse("a cut named with Once needs OnceAt, the unix time it was first sent", 1)
	end
	return Name, if Name then Ops.Stamp(Asked.OnceAt) else nil
end

local function Open(Owner: Store, Player: Player): Reply
	local Key = tostring(Player.UserId)
	local At = Ref(Owner, Key)
	local Found = Read(Owner, Key, if Shared.Shown:Stale(`{At.Store}/{At.Key}`) then Peek.Fresh else Peek.Cached)
	local Loaded: View.View? = nil
	if type(Found) == "table" then
		Loaded = Found
	elseif Found ~= Answer.Missing or Owner.MustExist then
		return Found
	end
	local Opened = Session.New(Shared, Shared:SaveFor(At, { Player.UserId }), Loaded, Owner.MustExist, Clock.Now())
	Owner.Sessions[Player] = Opened
	Shared:Watch(Opened, At)
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
		Owner:Unload(Player)
	elseif Reply ~= true then
		Failed(Owner, Player, Reply)
	end
	return Reply
end

function Store.New(Config: Build.Config): Store
	Errors.OnServer("Ledger.New")
	local Made = Build.New(Config)
	if Shared.Places[Config.Name] then
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
		Totals = {},
		Copies = Lru.New(Limits.SHOWN_MAX),
	}
	local Owner = setmetatable(Fresh, Store)
	Shared.Places[Owner.Name] = { Store = Owner.Data, Build = Made }
	for Name, Shards in Build.Totals(Config) do
		local Held = Totals.New(Owner.Name, Name, Shards)
		Owner.Totals[Name] = Held
		Shared.Places[Held.Place] = { Store = Owner.Data, Build = Totals.Build(Shards, Made) }
	end
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
		Keyed(Leg.Key)
		Given[Index] = {
			Ref = Ref(Owner, Leg.Key),
			Place = Shared.Places[Owner.Name],
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
	Shared:CloseAll()
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
	Keyed(Key)
	local Asked = Ops.Durable(Kind, Fields, self.MustExist)
	if Asked == nil then
		return Future.Completed(Answer.Invalid :: Reply)
	end
	return Future.Spawn(Send, self, Key, Asked)
end

function Store.DidApply(self: Store, Key: string | number, Once: string, OnceAt: number?): Future.Future<boolean | Answer>
	Errors.OnServer("DidApply")
	Keyed(Key)
	local Name = Ops.Name(Once)
	local Stamp = if OnceAt == nil then nil else Ops.Stamp(OnceAt)
	local Of = if Stamp == nil then DidApply.Reading else DidApply.Probing
	return Future.Spawn(Ask, Of, DidApply.Context(Ref(self, Key), Name, Stamp))
end

function Store.Peek(self: Store, Key: string | number, MaxAge: number?): Future.Future<State | Answer>
	Errors.OnServer("Peek")
	Keyed(Key)
	if MaxAge == nil then
		return Future.Spawn(Show, self, Key, Peek.Cached)
	elseif not (type(MaxAge) == "number" and MaxAge >= 0) then
		Errors.Misuse("MaxAge has to be a number of seconds, 0 or more")
	end
	return Future.Spawn(Glance, self, Key, MaxAge)
end

function Store.Follow(self: Store, Key: string | number, Listener: (State: State) -> ()): Observer.Connection
	Errors.OnServer("Follow")
	Keyed(Key)
	if type(Listener) ~= "function" then
		Errors.Misuse("Follow needs a function to call with each state")
	end
	local Found = Copied(self, Key)
	local Made = Found.Watch:Subscribe(Listener)
	local Last = Found.Held.State
	if Last then
		task.spawn(Listener, Last)
	end
	if not Found.Held.Running then
		Found.Held.Running = true
		task.spawn(Following, self, Found)
	end
	return Made
end

function Store.Stale(self: Store, Listener: (Key: string) -> ()): Observer.Connection
	Errors.OnServer("Stale")
	if type(Listener) ~= "function" then
		Errors.Misuse("Stale needs a function to call with each key")
	end
	return Shared.Landing:Subscribe(function(Landed: Runtime.Landing)
		local Found = if Landed.Ref.Store == self.Name then self.Copies:Get(Landed.Ref.Key) else nil
		if Found and Found.Held.State and Landed.Writes > Found.Held.Writes then
			Listener(Landed.Ref.Key)
		end
	end)
end

function Store.Fresh(self: Store, Key: string | number): Future.Future<State | Answer>
	Errors.OnServer("Fresh")
	Keyed(Key)
	return Future.Spawn(Show, self, Key, Peek.Fresh)
end

function Store.Pending(self: Store, Key: string | number): Future.Future<{ [string]: Book.Work } | Answer>
	Errors.OnServer("Pending")
	Keyed(Key)
	return Future.Spawn(Work, self, Key)
end

function Store.Resettle(self: Store, Key: string | number): Future.Future<Reply>
	Errors.OnServer("Resettle")
	Keyed(Key)
	return Future.Spawn(Settle, self, Key)
end

function Store.Reset(self: Store, Key: string | number, Options: CutOptions?): Future.Future<Reply>
	Errors.OnServer("Reset")
	Keyed(Key)
	local Name, Stamp = CutName(Options)
	local State = Checked(self, if Options then Options.State else nil)
	return Future.Spawn(function(): Reply
		return (Cutting(self, Key, Book.Cause.Reset, Name, Stamp, State))
	end)
end

function Store.Erase(self: Store, Key: string | number, Options: CutOptions?): Future.Future<Reply, { Naming }?>
	Errors.OnServer("Erase")
	Keyed(Key)
	if not self.Build.Erasable then
		Errors.Misuse(`{self.Name} does not let its keys be erased. set Erasable = true in its config`)
	elseif Options and Options.State ~= nil then
		Errors.Misuse("an Erase takes no State. a Reset does")
	end
	local Name, Stamp = CutName(Options)
	return Future.Spawn(Cutting, self, Key, Book.Cause.Erase, Name, Stamp, nil)
end

function Store.Losses(self: Store, Key: string | number): Future.Future<{ Naming } | Answer>
	Errors.OnServer("Losses")
	Keyed(Key)
	return Future.Spawn(Losses, self, Key)
end

function Store.Bump(self: Store, Name: string, Amount: number, Options: BumpOptions?): Future.Future<Reply>
	Errors.OnServer("Bump")
	local Held = self.Totals[Name]
	if Held == nil then
		Errors.Misuse(`{self.Name} declares no total named {Name}`)
	end
	local Max = Totals.Max(Held.Shards)
	if not (type(Amount) == "number" and Amount % 1 == 0 and math.abs(Amount) >= 1 and math.abs(Amount) <= Max) then
		Errors.Misuse(`the Amount of a Bump of {Name} has to be a whole number from 1 to {Max}, or from -{Max} to -1`)
	end
	local Asked: BumpOptions = Options or {}
	local Once = if Asked.Once == nil then nil else Ops.Name(Asked.Once)
	if Once and Asked.OnceAt == nil then
		Errors.Misuse("a bump named with Once needs OnceAt, the unix time it was first sent")
	elseif Asked.OnceAt ~= nil and Once == nil then
		Errors.Misuse("OnceAt needs a Once")
	end
	local Stamp = if Once then Ops.Stamp(Asked.OnceAt) else nil
	return Future.Spawn(Bumped, Held, Amount, Once, Stamp)
end

function Store.Total(self: Store, Name: string, MaxAge: number?): Future.Future<number | Answer>
	Errors.OnServer("Total")
	local Held = self.Totals[Name]
	local Age = if MaxAge == nil then Windows.MAX_AGE else MaxAge
	if Held == nil then
		Errors.Misuse(`{self.Name} declares no total named {Name}`)
	elseif not (type(Age) == "number" and Age >= 0) then
		Errors.Misuse("MaxAge has to be a number of seconds, 0 or more")
	end
	return Future.Spawn(Summed, Held, Age)
end

function Store.Unload(self: Store, Player: Player): Future.Future<boolean>
	local Held = self.Sessions[Player]
	if Held == nil then
		return Future.Completed(true)
	end
	self.Sessions[Player] = nil
	Shared:Unwatch(Held)
	return Held:Unload(Clock.Now())
end

return Store
