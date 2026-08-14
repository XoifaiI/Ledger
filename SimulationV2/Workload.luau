--!strict
--!optimize 2

--[=[
	Workload: Issues the operations of the catalogue against a real store.

	One handler for each catalogue entry, and the two lists are checked against each other when this
	file loads. The pools are what make the second half of a feature reachable: Confirm needs a
	reservation that Reserve made. A name binds to one thing for good, or a workload would put one
	delivery id on two keys and be right to.

	Return type: A table with New, Issue, Player, Handlers and the pool sizes.
	Example usage:
		local Ran, Answer = Workload.Issue(World, "Edit")
--]=]

local Catalogue = require("./Catalogue")
local Model = require("./Model")
local Swarm = require("./Swarm")

type Operation = Catalogue.Operation
type Reason = Catalogue.Reason

export type Outcome = {
	read Ok: boolean,
	read Why: Reason?,
	read Junk: boolean?
}

export type World = {
	Store: any,
	Keys: { any },
	Rng: Random,
	Hot: number,
	Cold: number,
	Open: (Key: any) -> any?,
	Sweep: () -> (),
	CloseAll: () -> (),
	Mode: string,
	Sessions: { [string]: any },
	Bookings: { { Key: any, Rid: string, Handed: boolean, Amount: number, Tried: boolean, To: any, Moved: boolean } },
	Transfers: { { From: any, To: any, Tid: string } },
	Routes: { [string]: { From: any, To: any, Amount: number, Moved: boolean } },
	Legs: { [string]: number },
	Pairs: { [string]: { From: any, To: any, Amount: number, Moved: boolean } },
	Grants: { [string]: number },
	Lied: { string },
	Fat: { Now: boolean },
	Model: Model.Model,
	Names: { { Once: string, Key: any } },
	Txids: { string },
	Versions: { { Key: any, Version: string } },
	Tallies: { string },
	Round: number
}

local SPLIT = " on key "

local MAX_POOL = 64

local FUNDS_MEAN = 400
local AMOUNT_MEAN = 40
local GREED = 0.15
local HOLD_LEAST = 5
local HOLD_MOST = 1200
local NAMES_IN_PLAY = 12

local Handlers: { [string]: (World) -> Outcome } = {}

local function Key(self: World): any
	return self.Keys[Swarm.Index(self.Rng, #self.Keys, self.Hot, self.Cold)]
end

local function Pair(self: World): (any, any?)
	local From = Key(self)
	for _ = 1, 8 do
		local To = Key(self)
		if To ~= From then
			return From, To
		end
	end
	return From, nil
end

local function Amount(self: World): number
	if self.Rng:NextNumber() < GREED then
		return math.floor(Swarm.Exponential(self.Rng, FUNDS_MEAN * 4)) + 1
	end
	return math.floor(Swarm.Exponential(self.Rng, AMOUNT_MEAN)) + 1
end

local function Name(self: World, Tag: string): string
	return `{Tag}{self.Rng:NextInteger(1, NAMES_IN_PLAY)}`
end

local function Keep<T>(Held: { T }, Value: T)
	table.insert(Held, Value)
	if #Held > MAX_POOL then
		table.remove(Held, 1)
	end
end

local function Draw<T>(self: World, Held: { T }): T?
	if #Held == 0 then
		return nil
	end
	return Held[self.Rng:NextInteger(1, #Held)]
end

local function Answered(Ok: any, Why: any, Junk: boolean?): Outcome
	return { Ok = Ok == true, Why = if type(Why) == "string" then Why :: Reason else nil, Junk = Junk }
end

local function Asked(self: World, Tag: string, Id: string, From: any, To: any, Amount: number)
	self.Model:Note(Tag, Id, From, To, Amount)
end

local function Returned(Value: any, Why: any): Outcome
	return { Ok = Why == nil, Why = if type(Why) == "string" then Why :: Reason else nil }
end

local function Player(Named: any): any
	return {
		UserId = tonumber(Named) or 1,
		Name = `player{Named}`,
		Parent = game,
		Kick = function() end
	}
end

local BLOB_CHANCE = 0.04
local BLOB_BYTES = 262144

local function Blob(self: World): string
	return string.rep("b", BLOB_BYTES)
end

local function Written(self: World, Once: string?): (string, { [string]: any }, boolean)
	local Roll = self.Rng:NextNumber()
	if Roll < 0.05 then
		return "Touch", { Note = self.Round, Once = Once, Bad = 0 / 0 }, true
	end
	if Roll < 0.2 then
		return "Give", { Note = self.Round, Once = Once, Amount = -(10 ^ 9) }, false
	end
	if Roll < 0.2 + BLOB_CHANCE then
		self.Fat.Now = true
		return "Stash", { Note = self.Round, Once = Once, Slot = `s{self.Rng:NextInteger(1, 12)}`, Blob = Blob(self) }, false
	end
	return "Touch", { Note = self.Round, Once = Once }, false
end

function Handlers.Load(self: World): Outcome
	local Named = Key(self)
	if self.Sessions[tostring(Named)] ~= nil then
		return { Ok = false, Why = nil }
	end

	self.Store:Load(Player(Named))
	local Active = self.Store:Get(Player(Named))
	if Active ~= nil then
		self.Sessions[tostring(Named)] = Active
	end
	return { Ok = Active ~= nil, Why = if Active == nil then "Unresolved" else nil }
end

function Handlers.Unload(self: World): Outcome
	local Named = Key(self)
	self.Store:Unload(Player(Named))
	self.Sessions[tostring(Named)] = nil
	return { Ok = true, Why = nil }
end

function Handlers.WaitForLoaded(self: World): Outcome
	local Named = Key(self)
	local Held = tostring(Named)

	if self.Sessions[Held] ~= nil then
		return { Ok = self.Store:WaitForLoaded(Player(Named)) ~= nil, Why = nil }
	end

	local Woke = false
	local Answered = false
	task.spawn(function()
		Woke = self.Store:WaitForLoaded(Player(Named)) ~= nil
		Answered = true
	end)

	local Active = self.Open(Named)
	if Active ~= nil then
		self.Sessions[Held] = Active
	end

	return { Ok = Answered and Woke, Why = nil }
end

function Handlers.Read(self: World): Outcome
	return { Ok = self.Store:Read(Player(Key(self))) ~= nil, Why = nil }
end

local function Live(self: World): (string?, any)
	if self.Rng:NextNumber() < 0.1 then
		for Named, Active in self.Sessions do
			if Active.Released then
				return Named, Active
			end
		end
	end

	for Named, Active in self.Sessions do
		if not Active.Released then
			return Named, Active
		end
	end

	local Named = tostring(Key(self))
	if self.Sessions[Named] ~= nil then
		return nil, nil
	end

	local Active = self.Open(Named)
	if Active == nil then
		return nil, nil
	end
	self.Sessions[Named] = Active
	return Named, Active
end

function Handlers.Apply(self: World): Outcome
	local Named, Active = Live(self)
	if Active == nil or Named == nil then
		return { Ok = false, Why = nil }
	end

	local Once = if self.Rng:NextNumber() < 0.3 then Name(self, "once") else nil
	local Kind, Fields, Junk = Written(self, Once)
	local Ok, Why = Active:Apply(Kind, Fields)
	return Answered(Ok, Why, Junk)
end

function Handlers.Commit(self: World): Outcome
	local _, Active = Live(self)
	if Active == nil then
		return { Ok = false, Why = nil }
	end
	local Kind, Fields, Junk = Written(self, nil)
	local Ok, Why = Active:Commit(Kind, Fields):Wait()
	return Answered(Ok, Why, Junk)
end

function Handlers.CommitOp(self: World): Outcome
	local Named, Active = Live(self)
	if Active == nil or Named == nil then
		return { Ok = false, Why = nil }
	end

	local Forged = if self.Rng:NextNumber() < 0.25 then self.Rng:NextInteger(1, 2) else 0
	local Kind, Fields, Junk = Written(self, Name(self, "once"))
	local Op: any = table.clone(Fields)
	Op.Id = `w{self.Round}n{self.Rng:NextInteger(1, 1000)}`
	Op.Kind = Kind
	Op.OnceAt = if Forged == 1 then 4 * 10 ^ 12 elseif Forged == 2 then 0 / 0 else nil
	local Sent, Cause = Active:CommitOp(Op):Wait()
	if Sent and type(Op.Once) == "string" then
		local Mark = Op.Once .. SPLIT .. Named
		self.Grants[Mark] = (self.Grants[Mark] or 0) + 1
	end
	return Answered(Sent, Cause, Junk)
end

function Handlers.Flush(self: World): Outcome
	local _, Active = Live(self)
	if Active == nil then
		return { Ok = false, Why = nil }
	end
	return Answered(Active:Flush():Wait())
end

function Handlers.SessionCompact(self: World): Outcome
	local _, Active = Live(self)
	if Active == nil then
		return { Ok = false, Why = nil }
	end
	return Answered(Active:Compact():Wait())
end

function Handlers.SessionRelease(self: World): Outcome
	local Named, Active = Live(self)
	if Active == nil or Named == nil then
		return { Ok = false, Why = nil }
	end

	local Ok, Why = Active:Release():Wait()
	self.Sessions[Named] = nil
	return Answered(Ok, Why)
end

function Handlers.Observe(self: World): Outcome
	local _, Active = Live(self)
	if Active == nil then
		return { Ok = false, Why = nil }
	end
	Active:Observe()
	return { Ok = true, Why = nil }
end

function Handlers.SessionDidApply(self: World): Outcome
	local _, Active = Live(self)
	local Held = Draw(self, self.Names)
	if Active == nil or Held == nil then
		return { Ok = false, Why = nil }
	end
	return { Ok = Active:DidApply(Held.Once), Why = nil }
end

function Handlers.Peek(self: World): Outcome
	return Returned(self.Store:Peek(Key(self)):Wait())
end

function Handlers.Inspect(self: World): Outcome
	return Returned(self.Store:Inspect(Key(self)):Wait())
end

function Handlers.DidApply(self: World): Outcome
	local Held = Draw(self, self.Names)
	if Held == nil then
		return { Ok = false, Why = nil }
	end

	local Applied, Why = self.Store:DidApply(Held.Key, Held.Once):Wait()
	if Applied == false then
		table.insert(self.Lied, `DidApply says '{Held.Once}' never went on '{tostring(Held.Key)}' and it did`)
	end
	return Returned(Applied, Why)
end

function Handlers.History(self: World): Outcome
	local Named = Key(self)
	local Rows, Why = self.Store:History(Named, self.Rng:NextInteger(1, 100)):Wait()
	if type(Rows) == "table" then
		for _, Row in Rows :: { any } do
			Keep(self.Versions, { Key = Named, Version = Row.Version })
		end
	end
	return Returned(Rows, Why)
end

function Handlers.PeekVersion(self: World): Outcome
	local Held = Draw(self, self.Versions)
	if Held == nil then
		local Named = Key(self)
		local Rows = self.Store:History(Named, 10):Wait()
		if type(Rows) ~= "table" or #(Rows :: { any }) == 0 then
			return { Ok = false, Why = nil }
		end
		for _, Row in Rows :: { any } do
			Keep(self.Versions, { Key = Named, Version = Row.Version })
		end
		Held = Draw(self, self.Versions)
	end

	if Held == nil then
		return { Ok = false, Why = nil }
	end
	return Returned(self.Store:PeekVersion(Held.Key, Held.Version):Wait())
end

function Handlers.Edit(self: World): Outcome
	local Once: string? = if self.Rng:NextNumber() < 0.3 then Name(self, "once") else nil
	local Kind, Fields, Junk = Written(self, Once)
	local Named = Key(self)

	local Ok, Why = self.Store:Edit(Named, Kind, Fields):Wait()
	if Ok and Once ~= nil then
		Keep(self.Names, { Once = Once, Key = Named })
		local Mark = Once .. SPLIT .. tostring(Named)
		self.Grants[Mark] = (self.Grants[Mark] or 0) + 1
	end
	return Answered(Ok, Why, Junk)
end

function Handlers.Transfer(self: World): Outcome
	local From, To = Pair(self)
	if To == nil then
		return { Ok = false, Why = nil }
	end

	local Tid = Name(self, "tid")
	local Route = self.Routes[Tid]
	if Route == nil then
		Route = { From = From, To = To, Amount = Amount(self), Moved = false }
		self.Routes[Tid] = Route
	end

	Asked(self, Model.TRANSFER, Tid, Route.From, Route.To, Route.Amount)
	local Ok, Why = self.Store:Transfer(Route.From, Route.To, Route.Amount, Tid):Wait()
	Keep(self.Transfers, { From = Route.From, To = Route.To, Tid = Tid })
	return Answered(Ok, Why)
end

function Handlers.Reserve(self: World): Outcome
	local Named = Key(self)
	local Rid = Name(self, "rid")
	local Options: { [string]: any } = {}

	if self.Rng:NextNumber() < 0.5 then
		Options.Hold = self.Rng:NextInteger(HOLD_LEAST, HOLD_MOST)
	end
	local Handed = false
	if self.Rng:NextNumber() < 0.5 then
		local _, To = Pair(self)
		if To ~= nil and To ~= Named then
			Options.To = To
			Handed = true
		end
	end

	local Units = Amount(self)
	local Ok, Why = self.Store:Reserve(Named, "Gold", Units, Rid, Options):Wait()
	if Ok and Options.To ~= nil then
		self.Model:Booked(Rid :: string, Named, Options.To, Units)
	end
	if Ok then
		Keep(self.Bookings, { Key = Named, Rid = Rid, Handed = Handed, Amount = Units, Tried = false, To = Options.To, Moved = false })
	end
	return Answered(Ok, Why)
end

function Handlers.Confirm(self: World): Outcome
	local Held = Draw(self, self.Bookings)
	if Held == nil then
		return { Ok = false, Why = nil }
	end

	local Ok, Why = self.Store:Confirm(Held.Key, Held.Rid):Wait()
	if Ok then
		self.Model:Spend(Held.Key, "Gold", Held.Amount)
	end
	return Answered(Ok, Why)
end

function Handlers.Release(self: World): Outcome
	local Held = Draw(self, self.Bookings)
	if Held == nil then
		return { Ok = false, Why = nil }
	end
	return Answered(self.Store:Release(Held.Key, Held.Rid):Wait())
end

function Handlers.Grant(self: World): Outcome
	local Held = Draw(self, self.Bookings)
	if self.Rng:NextNumber() < 0.8 then
		for _, Booking in self.Bookings do
			if Booking.Handed then
				Held = Booking
				break
			end
		end
	end
	if Held == nil then
		return { Ok = false, Why = nil }
	end

	Held.Tried = true
	return Answered(self.Store:Grant(Held.Key, Held.Rid):Wait())
end

function Handlers.Bump(self: World): Outcome
	local Named = Draw(self, self.Tallies) or "tally1"
	return Answered(self.Store:Bump(Named, "Gold", Amount(self)):Wait())
end

function Handlers.Total(self: World): Outcome
	local Named = Draw(self, self.Tallies) or "tally1"
	return Returned(self.Store:Total(Named, "Gold"):Wait())
end

function Handlers.Tx(self: World): Outcome
	local From, To = Pair(self)
	if To == nil then
		return { Ok = false, Why = nil }
	end

	local Id = Name(self, "tx")
	local Bound = self.Pairs[Id]
	if Bound == nil then
		Bound = { From = From, To = To, Amount = Amount(self), Moved = false }
		self.Pairs[Id] = Bound
	end
	From, To = Bound.From, Bound.To

	local Sent = Bound.Amount
	local Player = self.Mode == "Player"
	self.Legs[Id] = 2
	Asked(self, Model.TX, Id, From, To, Sent)
	local Ok, Why = self.Store:Tx(Id, {
		{ UserId = if Player then From else nil, Key = if Player then nil else From, Kind = "Give", Fields = { Amount = -Sent } },
		{ UserId = if Player then To else nil, Key = if Player then nil else To, Kind = "Give", Fields = { Amount = Sent } }
	}):Wait()
	Keep(self.Txids, Id)
	return Answered(Ok, Why)
end

function Handlers.Resettle(self: World): Outcome
	return Answered(self.Store:Resettle(Key(self)):Wait())
end

function Handlers.RecoverTransfers(self: World): Outcome
	return Answered(self.Store:RecoverTransfers(Key(self)):Wait())
end

function Handlers.ClearDelivered(self: World): Outcome
	return Answered(self.Store:ClearDelivered(Key(self)):Wait())
end

function Handlers.Sweep(self: World): Outcome
	self.Sweep()
	return { Ok = true, Why = nil }
end

function Handlers.Reset(self: World): Outcome
	return Answered(self.Store:Reset(Key(self)):Wait())
end

function Handlers.Erase(self: World): Outcome
	return Answered(self.Store:Erase(Key(self)):Wait())
end

function Handlers.CloseAll(self: World): Outcome
	self.CloseAll()
	table.clear(self.Sessions)
	return { Ok = true, Why = nil }
end

function Handlers.Destroy(self: World): Outcome
	self.Store:Destroy()
	return { Ok = true, Why = nil }
end

for _, Operation in Catalogue.CATALOGUE do
	assert(Handlers[Operation.Name] ~= nil, `the catalogue names '{Operation.Name}' and the workload has no handler for it`)
end
for Named in Handlers do
	local Known = pcall(Catalogue.Find, Named)
	assert(Known, `the workload handles '{Named}' and the catalogue does not name it`)
end

local function New(Store: any, Keys: { any }, Rng: Random, Mode: string, Open: (Key: any) -> any?, Sweep: () -> (), CloseAll: () -> (), Shared: { Routes: any, Legs: any, Grants: any, Pairs: any, Fat: any, Model: any, Lied: any }?): World
	assert(#Keys > 0, "a workload needs at least one key to work on")
	return {
		Store = Store,
		Keys = Keys,
		Rng = Rng,
		Hot = 2,
		Cold = math.max(3, #Keys // 2),
		Open = Open,
		Sweep = Sweep,
		CloseAll = CloseAll,
		Mode = Mode,
		Sessions = {},
		Bookings = {},
		Transfers = {},
		Routes = Shared and Shared.Routes or {},
		Legs = Shared and Shared.Legs or {},
		Pairs = Shared and Shared.Pairs or {},
		Grants = Shared and Shared.Grants or {},
		Lied = Shared and Shared.Lied or {},
		Fat = Shared and Shared.Fat or { Now = false },
		Model = Shared and Shared.Model or Model.New(Keys, { Gold = 0 }),
		Names = {},
		Txids = {},
		Versions = {},
		Tallies = { "tally1", "tally2" },
		Round = 0
	}
end

local function Issue(self: World, Named: string): (boolean, Outcome | string)
	local Handler = Handlers[Named]
	assert(Handler ~= nil, `nothing issues '{Named}'`)

	self.Round += 1
	local Fine, Held = pcall(Handler, self)
	if not Fine then
		return false, tostring(Held)
	end
	return true, Held :: Outcome
end

return table.freeze({
	New = New,
	Issue = Issue,
	Player = Player,
	Handlers = Handlers,
	MAX_POOL = MAX_POOL,
	NAMES_IN_PLAY = NAMES_IN_PLAY
})
