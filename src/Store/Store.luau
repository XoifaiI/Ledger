--!strict
--!optimize 2

--[=[
	Store: Object. The keys a config names, as a game holds them.

	Each method checks its arguments at the game's call, so a throw names the game's line. It then
	runs one call of the feature that owns it: Sessions, Keys, Follows, Cuts, Totals, Quantities or
	Transactions. A method that takes a key throws on one that starts with $T: or $P:, which hold the
	shards of totals and the parts of split quantities. A name is Once with OnceAt, the unix time it
	was first sent. Only Edit and DidApply take Once alone, as an untimed name. A take named with
	Once keeps SUB_BYTES of its name for the part each step is sent under. A gather is checked with
	the most parts it may take from, so a call that cannot fit throws before anything is sent. In a
	credit and a move, SENDER and RECEIVER are the places of the two legs, and the receiver decides.

	Return type: The Store class, and the types of its options and answers.
	Example usage:
		local Gold = Ledger.New(Config)
		Gold:Load(Player):Wait()
		Gold:Expect(Player):Apply("SpendGold", { Amount = 25 })
--]=]

local Answer = require("../Core/Answer")
local Book = require("../Record/Book")
local Build = require("./Build")
local Cuts = require("./Cuts")
local DataStore = require("../Adapters/DataStore")
local DidApply = require("../Calls/DidApply")
local Errors = require("../Core/Errors")
local Follows = require("./Follows")
local Future = require("../Util/Future")
local Keys = require("./Keys")
local Limits = require("../Core/Constants/Limits")
local Observer = require("../Util/Observer")
local Ops = require("./Ops")
local Parts = require("../Record/Parts")
local Quantities = require("./Quantities")
local Queue = require("../Record/Queue")
local Runtime = require("./Runtime")
local Session = require("./Session")
local Sessions = require("./Sessions")
local Shards = require("../Record/Shards")
local Split = require("../Calls/Split")
local Terms = require("./Terms")
local Totals = require("./Totals")
local Transactions = require("./Transactions")
local Types = require("../Record/Types")

type Answer = Answer.Answer
type Reply = Queue.Reply
type State = { [string]: any }

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
	read Sessions: Sessions.Held,
	read Follows: Follows.Followed,
	read Totals: Totals.Declared,
	read Splits: Quantities.Splits,
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

export type CutOptions = Cuts.Options

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

export type BumpOptions = {
	read Once: string?,
	read OnceAt: number?,
}

export type Ticket = Quantities.Ticket
export type Taken = Quantities.Taken
export type Stock = Quantities.Stock
export type Naming = Keys.Naming

local SUB_BYTES = 2
local SENDER = 1
local RECEIVER = 2

local Shared = Runtime.Shared

local Store = {} :: StoreImpl
Store.__index = Store

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
		Sessions = Sessions.New(Config.OnLoadFailed),
		Follows = Follows.New(),
		Totals = {},
		Splits = {},
	}
	local Owner = setmetatable(Fresh, Store)
	Shared.Places[Owner.Name] = { Store = Owner.Data, Build = Made }
	Totals.Declare(Owner.Totals, Owner.Name, Owner.Data, Made, Build.Totals(Config))
	Quantities.Declare(Owner.Splits, Owner.Name, Owner.Data, Made, Build.Splits(Config))
	Transactions.Add(Owner)
	return Owner
end

function Store.Tx(Legs: { Leg }, Options: Options?): Future.Future<Reply>
	Errors.OnServer("Tx")
	local Asked: Options = Options or {}
	local Given = Transactions.Gather(Legs, 0, false)
	local Name = if Asked.Once == nil then nil else Ops.Name(Asked.Once)
	if Name and Asked.OnceAt == nil then
		Errors.Misuse("a transaction named with Once needs OnceAt, the unix time it was first sent")
	end
	local Stamp = if Name then Ops.Stamp(Asked.OnceAt) else nil
	local Made = Terms.Make(Given, Name, Asked.Hot)
	return Future.Spawn(function(): Reply
		return (Transactions.Run(Made, Name, Stamp))
	end)
end

function Store.CloseAll()
	Shared:CloseAll()
end

function Store.Load(self: Store, Player: Player): Future.Future<Reply>
	Errors.OnServer("Load")
	return Sessions.Load(self.Sessions, self, Player)
end

function Store.Get(self: Store, Player: Player): Session.Session?
	return Sessions.Get(self.Sessions, Player)
end

function Store.Expect(self: Store, Player: Player): Session.Session
	local Held = Sessions.Get(self.Sessions, Player)
	if Held == nil then
		Errors.Misuse(`{Player.Name} has no loaded session in {self.Name}. call Load first`)
	end
	return Held :: Session.Session
end

function Store.Edit(self: Store, Key: string | number, Kind: string, Fields: { [string]: any }?): Future.Future<Reply>
	Errors.OnServer("Edit")
	Keys.Reserved(Key)
	local Asked = Ops.Durable(Kind, Fields, self.MustExist)
	if Asked == nil then
		return Future.Completed(Answer.Invalid :: Reply)
	end
	return Future.Spawn(Keys.Edit, self, Key, Asked)
end

function Store.DidApply(self: Store, Key: string | number, Once: string, OnceAt: number?): Future.Future<boolean | Answer>
	Errors.OnServer("DidApply")
	Keys.Reserved(Key)
	local Name = Ops.Name(Once)
	local Stamp = if OnceAt == nil then nil else Ops.Stamp(OnceAt)
	local Of = if Stamp == nil then DidApply.Reading else DidApply.Probing
	return Future.Spawn(Keys.DidApply, Of, DidApply.Context(Keys.Ref(self, Key), Name, Stamp))
end

function Store.Peek(self: Store, Key: string | number, MaxAge: number?): Future.Future<State | Answer>
	Errors.OnServer("Peek")
	Keys.Reserved(Key)
	if MaxAge == nil then
		return Future.Spawn(Keys.Peek, self, Key)
	elseif not (type(MaxAge) == "number" and MaxAge >= 0) then
		Errors.Misuse("MaxAge has to be a number of seconds, 0 or more")
	end
	return Future.Spawn(Follows.Peek, self.Follows, self, Key, MaxAge)
end

function Store.Follow(self: Store, Key: string | number, Listener: (State: State) -> ()): Observer.Connection
	Errors.OnServer("Follow")
	Keys.Reserved(Key)
	if type(Listener) ~= "function" then
		Errors.Misuse("Follow needs a function to call with each state")
	end
	return Follows.Follow(self.Follows, self, Key, Listener)
end

function Store.Stale(self: Store, Listener: (Key: string) -> ()): Observer.Connection
	Errors.OnServer("Stale")
	if type(Listener) ~= "function" then
		Errors.Misuse("Stale needs a function to call with each key")
	end
	return Follows.Stale(self.Follows, self, Listener)
end

function Store.Fresh(self: Store, Key: string | number): Future.Future<State | Answer>
	Errors.OnServer("Fresh")
	Keys.Reserved(Key)
	return Future.Spawn(Keys.Fresh, self, Key)
end

function Store.Pending(self: Store, Key: string | number): Future.Future<{ [string]: Book.Work } | Answer>
	Errors.OnServer("Pending")
	Keys.Reserved(Key)
	return Future.Spawn(Keys.Pending, self, Key)
end

function Store.Resettle(self: Store, Key: string | number): Future.Future<Reply>
	Errors.OnServer("Resettle")
	Keys.Reserved(Key)
	return Future.Spawn(Keys.Resettle, self, Key)
end

function Store.Reset(self: Store, Key: string | number, Options: CutOptions?): Future.Future<Reply>
	Errors.OnServer("Reset")
	Keys.Reserved(Key)
	local Name, Stamp = Cuts.Once(Options)
	local State = Cuts.Given(self, if Options then Options.State else nil)
	return Future.Spawn(Cuts.Reset, self, Key, Name, Stamp, State)
end

function Store.Erase(self: Store, Key: string | number, Options: CutOptions?): Future.Future<Reply, { Naming }?>
	Errors.OnServer("Erase")
	Keys.Reserved(Key)
	if not self.Build.Erasable then
		Errors.Misuse(`{self.Name} does not let its keys be erased. set Erasable = true in its config`)
	elseif Options and Options.State ~= nil then
		Errors.Misuse("an Erase takes no State. a Reset does")
	end
	local Name, Stamp = Cuts.Once(Options)
	return Future.Spawn(Cuts.Erase, self, Key, Name, Stamp)
end

function Store.Losses(self: Store, Key: string | number): Future.Future<{ Naming } | Answer>
	Errors.OnServer("Losses")
	Keys.Reserved(Key)
	return Future.Spawn(Keys.Losses, self, Key)
end

function Store.Bump(self: Store, Name: string, Amount: number, Options: BumpOptions?): Future.Future<Reply>
	Errors.OnServer("Bump")
	local Held = self.Totals[Name]
	if Held == nil then
		Errors.Misuse(`{self.Name} declares no total named {Name}`)
	end
	local Max = Shards.Max(Held.Shards)
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
	return Future.Spawn(Totals.Bump, Held, Amount, Once, Stamp)
end

function Store.Total(self: Store, Name: string, MaxAge: number?): Future.Future<number | Answer>
	Errors.OnServer("Total")
	local Held = self.Totals[Name]
	local Age = if MaxAge == nil then Shards.MAX_AGE else MaxAge
	if Held == nil then
		Errors.Misuse(`{self.Name} declares no total named {Name}`)
	elseif not (type(Age) == "number" and Age >= 0) then
		Errors.Misuse("MaxAge has to be a number of seconds, 0 or more")
	end
	return Future.Spawn(Totals.Total, Held, Age)
end

function Store.Stock(self: Store, Name: string, MaxAge: number?): Future.Future<Stock | Answer>
	Errors.OnServer("Stock")
	local Held = Quantities.Find(self.Splits, self.Name, Name)
	local Age = if MaxAge == nil then Shards.MAX_AGE else MaxAge
	if not (type(Age) == "number" and Age >= 0) then
		Errors.Misuse("MaxAge has to be a number of seconds, 0 or more")
	end
	return Future.Spawn(Quantities.Stock, Held, Age)
end

function Store.Open(self: Store, Name: string): Future.Future<Reply>
	Errors.OnServer("Open")
	local Held = Quantities.Find(self.Splits, self.Name, Name)
	return Future.Spawn(Quantities.Open, Held)
end

function Store.Close(self: Store, Name: string): Future.Future<Reply, Split.Closed?>
	Errors.OnServer("Close")
	return Future.Spawn(Quantities.Close, Quantities.Find(self.Splits, self.Name, Name))
end

function Store.Take(self: Store, Name: string, Count: number, Options: TakeOptions?): Future.Future<Reply, Taken>
	Errors.OnServer("Take")
	local Held = Quantities.Find(self.Splits, self.Name, Name)
	Quantities.Units(Count)
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
		local Given = Transactions.Gather(Asked.Legs or {}, 0, false)
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
			table.insert(Widest, 1, Quantities.PartLeg(Held, Index, "Free", -1))
		end
		Terms.Make(Widest, nil, nil)
		return Future.Spawn(Quantities.Gather, Held, Count, Given, Room)
	end
	local Body = Ops.Body("Take", { Count = Count, Print = Held.Declared.Print, Price = Quantities.Priced(Held, Asked.Price) })
	local Legs, Print = Quantities.Legs(Held, Asked.Legs, Body, Once)
	return Future.Spawn(Quantities.Take, Held, Body, Legs, nil, Once, Stamp, Print)
end

function Store.Hold(self: Store, Name: string, Count: number, Seconds: number): Future.Future<Reply, Ticket?>
	Errors.OnServer("Hold")
	local Held = Quantities.Find(self.Splits, self.Name, Name)
	Quantities.Units(Count)
	if not (type(Seconds) == "number" and Seconds > 0 and Seconds <= Parts.HOLD_MAX) then
		Errors.Misuse(`a hold lasts more than 0 and at most {Parts.HOLD_MAX} seconds`)
	end
	return Future.Spawn(Quantities.Hold, Held, Count, Seconds)
end

function Store.Confirm(self: Store, Held: Ticket, Options: TakeOptions?): Future.Future<Reply, Taken>
	Errors.OnServer("Confirm")
	local Found = Quantities.Ticketed(self.Splits, Held)
	local Asked: TakeOptions = Options or {}
	if Asked.Once ~= nil or Asked.OnceAt ~= nil then
		Errors.Misuse("a confirm takes no Once. its ticket names it")
	end
	local Body = Ops.Body("Confirm", { Id = Held.Id, Count = Held.Count, Print = Found.Declared.Print, Price = Quantities.Priced(Found, Asked.Price) })
	local Legs = Quantities.Legs(Found, Asked.Legs, Body, nil)
	return Future.Spawn(Quantities.Confirm, Found, Body, Legs, Held.Part)
end

function Store.Release(self: Store, Held: Ticket): Future.Future<Reply>
	Errors.OnServer("Release")
	local Found = Quantities.Ticketed(self.Splits, Held)
	local Body = Ops.Body("Release", { Id = Held.Id, Print = Found.Declared.Print })
	return Future.Spawn(Quantities.Release, Found, Body, Held.Part)
end

function Store.Credit(self: Store, Name: string, Count: number, Options: CreditOptions?): Future.Future<Reply>
	Errors.OnServer("Credit")
	local Held = Quantities.Find(self.Splits, self.Name, Name)
	local Asked: CreditOptions = Options or {}
	local Part = Asked.Part
	Quantities.Units(Count)
	if Held.Declared.First ~= nil then
		Errors.Misuse(`{Name} has serials, which a credit cannot give back in pieces`)
	elseif Part ~= nil then
		Quantities.Indexed(Held, Part, "Part")
	end
	if Asked.From == nil then
		local Body = Ops.Body("Credit", { Count = Count, Print = Held.Declared.Print })
		return Future.Spawn(Quantities.Credit, Held, Body, Part)
	end
	local From = Transactions.Gather({ Asked.From :: Leg }, 0, false)[1]
	local Made = Terms.Make({ Quantities.Toward(From, -Count), Quantities.PartLeg(Held, Part or 0, "Free", Count) }, nil, RECEIVER)
	return Future.Spawn(Quantities.Move, Made, Held, Part, RECEIVER)
end

function Store.Move(self: Store, Name: string, Part: number, Count: number, Options: MoveOptions): Future.Future<Reply>
	Errors.OnServer("Move")
	local Held = Quantities.Find(self.Splits, self.Name, Name)
	local Asked: MoveOptions = Options or {}
	local Field = Asked.Field or "Free"
	Quantities.Units(Count)
	Quantities.Indexed(Held, Part, "Part")
	if Field ~= "Free" and not table.find(Held.Declared.Proceeds, Field) then
		Errors.Misuse(`{Field} is neither Free nor a proceeds field of {Name}`)
	elseif Field == "Free" and Held.Declared.First ~= nil then
		Errors.Misuse(`{Name} has serials, which cannot move between keys`)
	elseif (Asked.To == nil) == (Asked.Part == nil) then
		Errors.Misuse("a move goes To a game key's money field or to another Part, and only one")
	end
	local Target: Terms.Given
	if Asked.To then
		Target = Quantities.Toward(Transactions.Gather({ Asked.To :: Leg }, 0, false)[1], Count)
	else
		Quantities.Indexed(Held, Asked.Part, "the Part a move goes to")
		Target = Quantities.PartLeg(Held, Asked.Part :: number, Field, Count)
	end
	local Made = Terms.Make({ Quantities.PartLeg(Held, Part, Field, -Count), Target }, nil, RECEIVER)
	return Future.Spawn(Quantities.Move, Made, Held, Part, SENDER)
end

function Store.Unload(self: Store, Player: Player): Future.Future<boolean>
	return Sessions.Unload(self.Sessions, Player)
end

return Store
