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
	Every method throws on a key that starts with $T: or $P:, which hold the shards of totals and
	the parts of split quantities. Open makes the parts of a split quantity the config declares, and
	Close shuts them and removes each one that is empty. Take takes units of a quantity on at most
	one part, with the game's legs when given. It answers true with the part, or SoldOut, or Short
	with a reason. With Once and OnceAt, a take walks the parts in the name's order and takes at
	most once for all time. Hold sets units aside on one part for at most Windows.HOLD_MAX seconds,
	and answers a ticket. Confirm sells a ticket's units, or free units when its hold ran out.
	Release gives a ticket's units back. Credit adds free units to this server's home part or to a
	given part, on a quantity with no serials. Given From, it takes them from a game key's money
	field. Move moves free units or proceeds out of a part, to a game key's money field or to
	another part. A take or a confirm may pay a Price into the quantity's proceeds. A take of an
	open quantity with Gather takes its units from as few parts as the view shows hold them. It
	takes them in one transaction into the legs that receive them. It answers Short when a part
	refused. Stock gives a quantity's free, held and sold units, no older than MaxAge, and whether
	every part is shut. Its sold units are exact once sold out, and the rest is advice. Its reads
	feed the view a walk picks parts by. A take of a quantity with serials answers its first serial,
	and a ticket lists its serials. A game op leg of such a take may name a Slot, the path where
	that serial is written in its state. Each method checks its arguments at the game's call and
	runs one call.

	Return type: The Store class, with New, Tx and CloseAll, and the methods Load, Get, Expect, Edit,
	DidApply, Peek, Fresh, Follow, Stale, Pending, Resettle, Reset, Erase, Losses, Bump, Total, Open,
	Close, Take, Hold, Confirm, Release, Credit, Move, Stock and Unload. The types are Store, Leg, Options,
	CutOptions, BumpOptions, Naming, TakeOptions, CreditOptions, MoveOptions, Ticket, Taken and Stock.
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
local Parts = require("../Record/Parts")
local Peek = require("../Calls/Peek")
local Queue = require("../Record/Queue")
local Resettle = require("../Calls/Resettle")
local Runner = require("../Machine/Runner")
local Runtime = require("./Runtime")
local Session = require("./Session")
local Sizes = require("../Core/Constants/Sizes")
local Split = require("../Calls/Split")
local Terms = require("./Terms")
local Total = require("../Calls/Total")
local Totals = require("../Record/Totals")
local Tx = require("../Calls/Tx")
local Types = require("../Record/Types")
local Value = require("../Encode/Value")
local View = require("../Record/View")
local Walk = require("../Calls/Walk")
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
	Open: (self: Store, Name: string) -> Future.Future<Reply>,
	Close: (self: Store, Name: string) -> Future.Future<Reply, Split.Closed?>,
	Take: (self: Store, Name: string, Count: number, Options: TakeOptions?) -> Future.Future<Reply, Taken>,
	Hold: (self: Store, Name: string, Count: number, Seconds: number) -> Future.Future<Reply, Ticket?>,
	Confirm: (self: Store, Held: Ticket, Options: TakeOptions?) -> Future.Future<Reply, Taken>,
	Release: (self: Store, Held: Ticket) -> Future.Future<Reply>,
	Credit: (self: Store, Name: string, Count: number, Options: CreditOptions?) -> Future.Future<Reply>,
	Move: (self: Store, Name: string, Part: number, Count: number, Options: MoveOptions) -> Future.Future<Reply>,
	Stock: (self: Store, Name: string, MaxAge: number?) -> Future.Future<Stock | Answer>,
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
	read Splits: { [string]: Quantity },
}

type Quantity = {
	read Declared: Parts.Declared,
	read View: { [number]: Walk.View },
	read Total: Totals.Held,
}

export type Stock = {
	read Free: number,
	read Held: number,
	read Sold: number,
	read SoldOut: boolean,
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
	read Slot: { string }?,
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

export type TakeOptions = {
	read Once: string?,
	read OnceAt: number?,
	read Legs: { Leg }?,
	read Price: { [string]: number }?,
	read Gather: boolean?,
}

export type CreditOptions = {
	read Part: number?,
	read From: Leg?,
}

export type MoveOptions = {
	read Field: string?,
	read To: Leg?,
	read Part: number?,
}

export type Ticket = {
	read Quantity: string,
	read Id: string,
	read Part: number,
	read Count: number,
	read Ends: number,
	read Serials: { number }?,
}

export type Taken = Walk.Result

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

local RESERVED = { Totals.PREFIX, Parts.PREFIX }
local SLOT = Parts.SLOT
local SUB_BYTES = 2
local SENDER, RECEIVER = 1, 2

local function Keyed(Key: string | number, Depth: number?)
	for _, Prefix in RESERVED do
		if type(Key) == "string" and string.sub(Key, 1, #Prefix) == Prefix then
			Errors.Misuse(`the key {Key} starts with {Prefix}, which Ledger keeps for itself`, 1 + (Depth or 0))
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

local function Transact(Made: Terms.Made, Name: string?, Stamp: number?): (Reply, Tx.Context?)
	local Number = Shared:Server()
	local Context: Tx.Context? = nil
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
		local Running = Tx.Context(Use, Made.Legs, Made.Decider, Number, Ids, Shared:Mint())
		local Reply = Runner.Run(Of, Running, Shared.Places):Wait()
		Context = Running
		for Index, Seen in Running.Ids do
			if Seen then
				Shared:Learn(Made.Legs[Index].Ref, Seen)
			end
		end
		if Reply ~= Answer.Expired then
			return Reply or Answer.Unresolved, Context
		end
	end
	return Answer.Expired, Context
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
			Totals.Take(Held, Index, Totals.Noted(Note, Held.Kind))
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

local function Gather(Legs: { Leg }, Depth: number, Serial: boolean): { Terms.Given }
	local Given: { Terms.Given } = {}
	for Index, Leg in Legs do
		local Owner = Leg.Store
		local Slot = Leg.Slot
		if type(Owner) ~= "table" or getmetatable(Owner :: any) ~= Store then
			Errors.Misuse(`leg {Index} needs Store, a store from Ledger.New`, 1 + Depth)
		elseif Slot ~= nil and not Serial then
			Errors.Misuse(`leg {Index} names a Slot, which only a take of a quantity with serials fills`, 1 + Depth)
		elseif Slot ~= nil and (type(Slot) ~= "table" or Slot[1] == nil or Leg.Kind == nil or not Owner.Build.Fields[Slot[1]]) then
			Errors.Misuse(`the Slot of leg {Index} has to be a path of keys from a declared field, on a game op leg`, 1 + Depth)
		end
		Keyed(Leg.Key, 1 + Depth)
		Given[Index] = {
			Ref = Ref(Owner, Leg.Key),
			Place = Shared.Places[Owner.Name],
			MustExist = if Leg.MustExist == nil then Owner.MustExist else Leg.MustExist == true,
			Field = Leg.Field,
			Amount = Leg.Amount,
			Kind = Leg.Kind,
			Fields = Leg.Fields,
			Slot = Slot,
		}
	end
	return Given
end

local function Quantity(Owner: Store, Name: string): Quantity
	local Found = Owner.Splits[Name]
	if Found == nil then
		Errors.Misuse(`{Owner.Name} declares no split quantity named {Name}`, 1)
	end
	return Found :: Quantity
end

local function Units(Count: unknown)
	if not (type(Count) == "number" and Count % 1 == 0 and Count >= 1 and Count < Limits.MONEY_LIMIT) then
		Errors.Misuse("Count has to be a whole number of 1 or more", 1)
	end
end

local function Legged(Held: Quantity, Given: { Leg }?, Body: State, Name: string?): ({ Tx.Leg }, number?)
	local Declared = Held.Declared
	if Given == nil or Given[1] == nil then
		return {}, if Name then Ops.Print({ Quantity = Declared.Name, Op = Body }) else nil
	end
	local Gathered = Gather(Given, 1, Declared.First ~= nil)
	local Part: Book.Ref = { Store = Declared.Place, Key = Parts.Key(Declared.Name, Declared.Parts, 0) }
	table.insert(Gathered, { Ref = Part, Place = Shared.Places[Declared.Place], MustExist = true, Kind = Body.Kind, Fields = Body })
	local Made = Terms.Make(Gathered, Name, #Gathered, 1)
	local Legs = table.clone(Made.Legs)
	table.remove(Legs)
	return Legs, Made.Print
end

local function Walking(Held: Quantity, Body: State, Legs: { Tx.Leg }, Only: number?, Name: string?, Stamp: number?, Print: number?): Taken
	local Declared = Held.Declared
	local Home = Totals.Home(Declared.Name, Shared:First(), Declared.Parts)
	local Context = Walk.Context(Declared, Body, Legs, Shared:Server(), Home)
	Context.Only, Context.Name, Context.Stamp, Context.Print, Context.View = Only, Name, Stamp or Clock.Now(), Print, Held.View
	for _ = 1, if Name then 0 else Limits.PROBES do
		table.insert(Context.Names, Shared:Draw())
	end
	local Found = Runner.Run(Walk.Machine, Context, Shared.Places):Wait()
	return Found or { Reply = Answer.Unresolved }
end

local function Taking(Held: Quantity, Body: State, Legs: { Tx.Leg }, Only: number?, Name: string?, Stamp: number?, Print: number?): (Reply, Taken)
	local Found = Walking(Held, Body, Legs, Only, Name, Stamp, Print)
	return Found.Reply, Found
end

local function Holding(Held: Quantity, Count: number, Seconds: number): (Reply, Ticket?)
	local Declared = Held.Declared
	local Id, Now = Shared:Draw(), Clock.Now()
	local Body = Ops.Body("Hold", { Id = Id, Count = Count, End = Now + Seconds, Print = Declared.Print })
	local Found = Walking(Held, Body, {}, nil, nil, Now, nil)
	local Part = Found.Part
	if Found.Reply ~= true or Part == nil then
		return Found.Reply, nil
	end
	local Serials: { number }? = nil
	local Kept = Found.State :: Parts.Part?
	for _, Each in if type(Kept) == "table" then Kept.Holds else {} do
		Serials = if Each.Id == Id then Each.Serials else Serials
	end
	return true, { Quantity = Declared.Name, Id = Id, Part = Part, Count = Count, Ends = Now + Seconds + Limits.EPOCH, Serials = Serials }
end

local function Confirming(Held: Quantity, Body: State, Legs: { Tx.Leg }, Part: number): (Reply, Taken)
	local Found = Walking(Held, Body, Legs, Part)
	return if Found.Reply == Answer.SoldOut then Answer.Short else Found.Reply, Found
end

local function Crediting(Held: Quantity, Body: State, Part: number?): Reply
	local Declared = Held.Declared
	local Only = Part or Totals.Home(Declared.Name, Shared:First(), Declared.Parts)
	local Found = Walking(Held, Body, {}, Only)
	return if Found.Reply == Answer.SoldOut or Found.Reply == Answer.Short then Answer.Refused else Found.Reply
end

local function Splitting(Held: Quantity, Of: typeof(Split.Open), Suffix: string): (Reply, Split.Closed?)
	local Declared = Held.Declared
	local Context = Split.Context(Declared, `{Declared.Name}:{Suffix}`, Clock.Now(), Shared:Server())
	local Found = Runner.Run(Of, Context, Shared.Places):Wait()
	if type(Found) == "table" then
		local Closed = Found :: Split.Closed
		return Closed.Reply, Closed
	end
	return if Found == nil then Answer.Unresolved else Found, nil
end

local function PartLeg(Held: Quantity, Index: number, Field: string, Amount: number): Terms.Given
	local Declared = Held.Declared
	local Part: Book.Ref = { Store = Declared.Place, Key = Parts.Key(Declared.Name, Declared.Parts, Index) }
	return { Ref = Part, Place = Shared.Places[Declared.Place], MustExist = true, Field = Field, Amount = Amount }
end

local function Toward(Given: Terms.Given, Amount: number): Terms.Given
	return { Ref = Given.Ref, Place = Given.Place, MustExist = Given.MustExist, Field = Given.Field, Amount = Amount }
end

local function Moving(Made: Terms.Made, Held: Quantity, Index: number?, Slot: number): Reply
	local Legs = Made.Legs
	if Index == nil then
		local Declared = Held.Declared
		local Home = Totals.Home(Declared.Name, Shared:First(), Declared.Parts)
		local Old = Legs[Slot]
		Legs = table.clone(Legs)
		Legs[Slot] = { Ref = { Store = Declared.Place, Key = Parts.Key(Declared.Name, Declared.Parts, Home) }, MustExist = Old.MustExist, Erasable = Old.Erasable, Change = Old.Change }
	end
	return (Transact({ Legs = Legs, Decider = Made.Decider, Print = Made.Print }, nil, nil))
end

local function Indexed(Held: Quantity, Part: unknown, What: string)
	local Count = Held.Declared.Parts
	if not (type(Part) == "number" and Part % 1 == 0 and Part >= 0 and Part < Count) then
		Errors.Misuse(`{What} has to be a part of {Held.Declared.Name}, from 0 to {Count - 1}`, 1)
	end
end

local function Priced(Held: Quantity, Price: unknown): { [string]: number }?
	if Price == nil then
		return nil
	elseif type(Price) ~= "table" then
		Errors.Misuse("Price has to be a table of proceeds fields and amounts", 1)
	end
	local Made: { [string]: number } = {}
	for Field, Amount in Price :: { [any]: any } do
		if not table.find(Held.Declared.Proceeds, Field) then
			Errors.Misuse(`{Field} is not a proceeds field of {Held.Declared.Name}`, 1)
		elseif not (type(Amount) == "number" and Amount % 1 == 0 and Amount >= 1 and Amount < Limits.MONEY_LIMIT) then
			Errors.Misuse(`the price of {Field} has to be a whole number of 1 or more`, 1)
		end
		Made[Field] = Amount
	end
	return Made
end

local function Ticketed(Owner: Store, Held: Ticket): Quantity
	local Found = if type(Held) == "table" and type(Held.Quantity) == "string" then Owner.Splits[Held.Quantity] else nil
	if Found == nil or type(Held.Id) ~= "string" or type(Held.Part) ~= "number" or type(Held.Count) ~= "number" then
		Errors.Misuse("a ticket has to be one Hold gave back", 1)
	end
	return Found :: Quantity
end

local function Summing(Held: Totals.Held, MaxAge: number): { number } | Answer
	local Found = Runner.Run(Total.Machine, Total.Context(Held, MaxAge, Shared:Server(), Lapse()), Shared.Places):Wait()
	return if Found == nil then Answer.Unresolved else Found
end

local function Summed(Held: Totals.Held, MaxAge: number): number | Answer
	local Found = Summing(Held, MaxAge)
	return if type(Found) == "table" then Found[1] else Found
end

local function Stocked(Held: Quantity, MaxAge: number): Stock | Answer
	local Found = Summing(Held.Total, MaxAge)
	if type(Found) ~= "table" then
		return Found
	end
	local Now = Clock.Now()
	for Index, Pair in Held.Total.Pairs do
		local Values = Pair.Values
		local Free = Values[SLOT.Free]
		Held.View[Index] = { Free = Free, Shut = Values[SLOT.Shut] == 1, Short = Free == 0, At = Now }
	end
	return { Free = Found[SLOT.Free], Held = Found[SLOT.Held], Sold = Found[SLOT.Sold], SoldOut = Found[SLOT.Shut] == Held.Declared.Parts }
end

local function Gathering(Held: Quantity, Count: number, Given: { Terms.Given }, Room: number): (Reply, Taken)
	Stocked(Held, Windows.VIEW_AGE)
	local Free: { [number]: number } = {}
	for Index, Seen in Held.View do
		Free[Index] = Seen.Free
	end
	local Plan = Parts.Plan(Free, Held.Declared.Parts, Count, Room)
	if Plan == nil then
		return Answer.Short, { Reply = Answer.Short, Reason = "Free" }
	end
	local Legs: { Terms.Given } = {}
	for _, Step in Plan do
		table.insert(Legs, PartLeg(Held, Step.Index, "Free", -Step.Count))
	end
	local Parted = #Legs
	table.move(Given, 1, #Given, Parted + 1, Legs)
	local Reply, Context = Transact(Terms.Make(Legs, nil, nil), nil, nil)
	local Refuser = if Context then Context.Refuser else nil
	if Reply ~= true and Refuser and Refuser <= Parted then
		return Answer.Short, { Reply = Answer.Short, Reason = "Free" }
	end
	return Reply, { Reply = Reply }
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
		Splits = {},
	}
	local Owner = setmetatable(Fresh, Store)
	Shared.Places[Owner.Name] = { Store = Owner.Data, Build = Made }
	for Name, Shards in Build.Totals(Config) do
		local Held = Totals.New(Owner.Name, Name, Shards)
		Owner.Totals[Name] = Held
		Shared.Places[Held.Place] = { Store = Owner.Data, Build = Totals.Build(Shards, Made) }
	end
	for Name, Declared in Build.Splits(Config) do
		Owner.Splits[Name] = { Declared = Declared, View = {}, Total = Totals.New(Owner.Name, Name, Declared.Parts, Parts.KIND) }
		Shared.Places[Declared.Place] = { Store = Owner.Data, Build = Parts.Build(Made, Declared) }
	end
	return Owner
end

function Store.Tx(Legs: { Leg }, Options: Options?): Future.Future<Reply>
	Errors.OnServer("Tx")
	local Asked: Options = Options or {}
	local Given = Gather(Legs, 0, false)
	local Name = if Asked.Once == nil then nil else Ops.Name(Asked.Once)
	if Name and Asked.OnceAt == nil then
		Errors.Misuse("a transaction named with Once needs OnceAt, the unix time it was first sent")
	end
	local Stamp = if Name then Ops.Stamp(Asked.OnceAt) else nil
	local Made = Terms.Make(Given, Name, Asked.Hot)
	return Future.Spawn(function(): Reply
		return (Transact(Made, Name, Stamp))
	end)
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

function Store.Stock(self: Store, Name: string, MaxAge: number?): Future.Future<Stock | Answer>
	Errors.OnServer("Stock")
	local Held = Quantity(self, Name)
	local Age = if MaxAge == nil then Windows.MAX_AGE else MaxAge
	if not (type(Age) == "number" and Age >= 0) then
		Errors.Misuse("MaxAge has to be a number of seconds, 0 or more")
	end
	return Future.Spawn(Stocked, Held, Age)
end

function Store.Open(self: Store, Name: string): Future.Future<Reply>
	Errors.OnServer("Open")
	local Held = Quantity(self, Name)
	return Future.Spawn(function(): Reply
		return (Splitting(Held, Split.Open, "open"))
	end)
end

function Store.Close(self: Store, Name: string): Future.Future<Reply, Split.Closed?>
	Errors.OnServer("Close")
	return Future.Spawn(Splitting, Quantity(self, Name), Split.Close, "close")
end

function Store.Take(self: Store, Name: string, Count: number, Options: TakeOptions?): Future.Future<Reply, Taken>
	Errors.OnServer("Take")
	local Held = Quantity(self, Name)
	Units(Count)
	local Asked: TakeOptions = Options or {}
	local Once = if Asked.Once == nil then nil else Ops.Name(Asked.Once)
	if Once and Asked.OnceAt == nil then
		Errors.Misuse("a take named with Once needs OnceAt, the unix time it was first sent")
	elseif Once and #Once > Limits.NAME_BYTES - SUB_BYTES then
		Errors.Misuse(`the Once of a take has at most {Limits.NAME_BYTES - SUB_BYTES} bytes`)
	end
	local Stamp = if Once then Ops.Stamp(Asked.OnceAt) else nil
	if Asked.Gather then
		local Declared = Held.Declared
		local Given = Gather(Asked.Legs or {}, 0, false)
		local Room = math.min(Declared.Parts, Shared.Places[Declared.Place].Build.LegLimit - #Given)
		for _, Leg in Given do
			Room = math.min(Room, Leg.Place.Build.LegLimit - #Given)
		end
		if Declared.Mode ~= Parts.MODE.Open or Once or Asked.Price ~= nil then
			Errors.Misuse(`a gather takes from an open quantity, with no Once and no Price, and {Name} is not one`)
		elseif Given[1] == nil or Room < 1 then
			Errors.Misuse("a gather needs the legs that receive it, and room for at least one part beside them")
		end
		local Widest = table.clone(Given)
		for Index = Room - 1, 0, -1 do
			table.insert(Widest, 1, PartLeg(Held, Index, "Free", -1))
		end
		Terms.Make(Widest, nil, nil)
		return Future.Spawn(Gathering, Held, Count, Given, Room)
	end
	local Body = Ops.Body("Take", { Count = Count, Print = Held.Declared.Print, Price = Priced(Held, Asked.Price) })
	local Legs, Print = Legged(Held, Asked.Legs, Body, Once)
	return Future.Spawn(Taking, Held, Body, Legs, nil, Once, Stamp, Print)
end

function Store.Hold(self: Store, Name: string, Count: number, Seconds: number): Future.Future<Reply, Ticket?>
	Errors.OnServer("Hold")
	local Held = Quantity(self, Name)
	Units(Count)
	if not (type(Seconds) == "number" and Seconds > 0 and Seconds <= Windows.HOLD_MAX) then
		Errors.Misuse(`a hold lasts more than 0 and at most {Windows.HOLD_MAX} seconds`)
	end
	return Future.Spawn(Holding, Held, Count, Seconds)
end

function Store.Confirm(self: Store, Held: Ticket, Options: TakeOptions?): Future.Future<Reply, Taken>
	Errors.OnServer("Confirm")
	local Found = Ticketed(self, Held)
	local Asked: TakeOptions = Options or {}
	if Asked.Once ~= nil or Asked.OnceAt ~= nil then
		Errors.Misuse("a confirm takes no Once. its ticket names it")
	end
	local Body = Ops.Body("Confirm", { Id = Held.Id, Count = Held.Count, Print = Found.Declared.Print, Price = Priced(Found, Asked.Price) })
	local Legs = Legged(Found, Asked.Legs, Body, nil)
	return Future.Spawn(Confirming, Found, Body, Legs, Held.Part)
end

function Store.Release(self: Store, Held: Ticket): Future.Future<Reply>
	Errors.OnServer("Release")
	local Found = Ticketed(self, Held)
	local Body = Ops.Body("Release", { Id = Held.Id, Print = Found.Declared.Print })
	return Future.Spawn(function(): Reply
		return (Taking(Found, Body, {}, Held.Part))
	end)
end

function Store.Credit(self: Store, Name: string, Count: number, Options: CreditOptions?): Future.Future<Reply>
	Errors.OnServer("Credit")
	local Held = Quantity(self, Name)
	local Asked: CreditOptions = Options or {}
	local Part = Asked.Part
	Units(Count)
	if Held.Declared.First ~= nil then
		Errors.Misuse(`{Name} has serials, which a credit cannot give back in pieces`)
	elseif Part ~= nil then
		Indexed(Held, Part, "Part")
	end
	if Asked.From == nil then
		local Body = Ops.Body("Credit", { Count = Count, Print = Held.Declared.Print })
		return Future.Spawn(Crediting, Held, Body, Part)
	end
	local From = Gather({ Asked.From :: Leg }, 0, false)[1]
	local Made = Terms.Make({ Toward(From, -Count), PartLeg(Held, Part or 0, "Free", Count) }, nil, RECEIVER)
	return Future.Spawn(Moving, Made, Held, Part, RECEIVER)
end

function Store.Move(self: Store, Name: string, Part: number, Count: number, Options: MoveOptions): Future.Future<Reply>
	Errors.OnServer("Move")
	local Held = Quantity(self, Name)
	local Asked: MoveOptions = Options or {}
	local Field = Asked.Field or "Free"
	Units(Count)
	Indexed(Held, Part, "Part")
	if Field ~= "Free" and not table.find(Held.Declared.Proceeds, Field) then
		Errors.Misuse(`{Field} is neither Free nor a proceeds field of {Name}`)
	elseif Field == "Free" and Held.Declared.First ~= nil then
		Errors.Misuse(`{Name} has serials, which cannot move between keys`)
	elseif (Asked.To == nil) == (Asked.Part == nil) then
		Errors.Misuse("a move goes To a game key's money field or to another Part, and only one")
	end
	local Target: Terms.Given
	if Asked.To then
		Target = Toward(Gather({ Asked.To :: Leg }, 0, false)[1], Count)
	else
		Indexed(Held, Asked.Part, "the Part a move goes to")
		Target = PartLeg(Held, Asked.Part :: number, Field, Count)
	end
	local Made = Terms.Make({ PartLeg(Held, Part, Field, -Count), Target }, nil, RECEIVER)
	return Future.Spawn(Moving, Made, Held, Part, SENDER)
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
