--!strict
--!optimize 2

--[=[

	Ops: The writes a game asks for by name.

	Edit, Reserve, Confirm, Release and Bump each check their arguments, build one op and hand it to
	Written. Transfer, Grant and Tx are the ones that touch more than one key, so they run a protocol
	instead and add the keys to the sweep if they cannot finish. A total is read from the MemoryStore
	cache while the sum there is inside its window. Once it is stale, one server claims the refill
	and reads the shards while every other server answers the stale sum, so the minute never turns
	into every server reading every shard at once. A bump writes nothing to MemoryStore: this server
	lays its own bumps over whatever sum it answers, and other servers see them at the next refill.

	Return type: An empty table. It writes Edit, Transfer, Reserve, Confirm, Release, Grant, Handed, TallyName, Kept, Bump, Total and Tx onto the class.
	Example usage:
		local Ops = require("./Ops")
		local Ok, Why = self:Edit(1, "Add", { Amount = 5 }):Wait()
--]=]

local Future = require("../../Util/Future")
local Clock = require("../../Util/Clock")
local Windows = require("../../Core/Constants/Windows")
local Errors = require("../../Core/Errors")
local Reasons = require("../../Core/Constants/Reasons")
local Shapes = require("../../Core/Shapes")
local Api = require("../../Core/Api")
local Storable = require("../../Encode/Storable")
local Tags = require("../../Core/Constants/Tags")
local Log = require("../../Record/Log")
local NewOp = require("../../Record/NewOp")
local TxStamp = require("../../Record/TxStamp")
local Kinds = require("../../Core/Constants/Kinds")
local Booking = require("../../Layers/Booking")
local Shards = require("../../Core/Constants/Shards")
local Datastore = require("../../Core/Constants/Datastore")
local Tally = require("../../Layers/Tally")
local Transfer = require("../../Protocol/Transfer")
local Transactions = require("../../Core/Constants/Transactions")
local Tx = require("../../Protocol/Tx")
local Validate = require("../../Core/Validate")
local Write = require("./Write")
local Store = require("../Class")
local Types = require("../Types")

type Future<T...> = Future.Future<T...>
type Op = Shapes.Op
type Record = Shapes.Record<any>
type KeyLike = Shapes.KeyLike
type TxLeg = Api.TxLeg
type HoldOptions = Api.HoldOptions
type Reason = Reasons.Reason
type Store = Types.Store<any>
type LegTarget = { Store: Store, Key: string }

local MAX_TRANSFER_ID = 64
local MAX_TX_ID = 50
local MAX_BOOKING_ID = 64

local REFUSED = Reasons.Refused
local INVALID = Reasons.Invalid
local UNRESOLVED = Reasons.Unresolved
local BUSY = Reasons.Busy
local HELD = Reasons.Held
local SPENT = Reasons.Spent

local Failed = Write.Failed

local function Rejected(Why: Reason?): Future<boolean, Reason?>
	return Future.Completed(false, Why)
end

local function Trimmed(Held: Tally.Recent, Now: number)
	local Floor = Now - Windows.TALLY_KEEP
	local Bumps = Held.Bumps
	local Kept = 0
	for _, Bucket in Bumps do
		if Bucket.At >= Floor then
			Kept += 1
			Bumps[Kept] = Bucket
		end
	end
	for Index = #Bumps, Kept + 1, -1 do
		Bumps[Index] = nil
	end
end

local function Over(Held: Tally.Recent): number
	local Mark = Held.Mark
	local Sum = 0
	for _, Bucket in Held.Bumps do
		if if Mark ~= nil then Bucket.Seq > Mark else Bucket.At > Held.At then
			Sum += Bucket.Amount
		end
	end
	return Sum
end

local function Bumped(Held: Tally.Recent, Seq: number, Now: number, Amount: number)
	local Bumps = Held.Bumps
	local Last = Bumps[#Bumps]
	local Mark = Held.Mark
	if Last ~= nil and Last.At == Now and (Mark == nil or Last.Seq > Mark) then
		Last.Amount += Amount
		return
	end
	table.insert(Bumps, { Seq = Seq, At = Now, Amount = Amount })
end

local function Remember(Held: Tally.Recent, Sum: number, At: number, Seen: number, Mark: number?): number
	Held.Sum = Sum
	Held.At = At
	Held.Seen = Seen
	Held.Mark = if Mark ~= nil then Mark elseif At == Held.OwnAt then Held.OwnMark else nil
	if Mark ~= nil then
		Held.OwnAt = At
		Held.OwnMark = Mark
	end
	return Sum + Over(Held)
end

function Store.Edit(self: Store, Key: KeyLike, Kind: string, Fields: { [any]: any }?): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Edit")

	local Op = NewOp.New(Kind, Fields)

	local Fine, Wrong = NewOp.Check(Op)
	if not Fine then
		warn(`Ledger: Edit rejected op '{Kind}', {Wrong}`)
		return Rejected(INVALID)
	end

	return Future.New(function(): (boolean, Reason?)
		return self:Written(Resolved, Op, `edit '{Kind}'`)
	end)
end

function Store.Transfer(self: Store, From: KeyLike, To: KeyLike, Amount: number, Id: string?): Future<boolean, Reason?>
	self:ExpectBalance("Transfer")
	local FromKey = self:Resolve(From, "Transfer")
	local ToKey = self:Resolve(To, "Transfer")
	assert(FromKey ~= ToKey, `Transfer needs two different keys, both resolved to '{FromKey}'`)
	Validate.Amount(Amount, "Transfer")
	Validate.Maybe(Id, MAX_TRANSFER_ID, "Transfer Id")

	return Future.New(function(): (boolean, Reason?)
		local Ok, Moved, Why, Follow = pcall(function(): (boolean, Reason?, boolean?)
			return Transfer.Drive(self:Records(), self:Format(), FromKey, ToKey, Amount, Id)
		end)
		if not Ok then
			warn(`Ledger: the transfer from '{FromKey}' broke inside Ledger: {Moved}`)
			return false, UNRESOLVED
		end

		if Why == BUSY or Why == HELD or Follow then
			self.Sweep:Add(self:Swept(), FromKey)
		end
		if Moved then
			self:Went(FromKey)
			self:Went(ToKey)
		end
		return Moved :: boolean, Why :: Reason?
	end)
end

function Store.Reserve(self: Store, Key: KeyLike, Field: string, Amount: number, Id: string, Options: HoldOptions?): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Reserve")
	Validate.Field(self.Initial, Field, "Reserve")
	Validate.Amount(Amount, "Reserve")
	local Rid = Validate.Name(Id, MAX_BOOKING_ID, "Reserve")

	local Extra: HoldOptions = Options or {}
	assert(type(Extra) == "table", "Reserve takes an options table after the Id when you pass one")

	local Hold = Extra.Hold
	assert(Hold == nil or (type(Hold) == "number" and Hold > 0 and Hold < math.huge), `Reserve Hold must be a positive number of seconds when given, got {tostring(Hold)}`)

	local To: string? = nil
	if Extra.To ~= nil then
		To = self:Resolve(Extra.To, "Reserve To")
		assert(To ~= Resolved, `Reserve needs To to be a different key, both resolved to '{Resolved}'`)
		assert(Hold == nil or Hold <= Windows.HOLD_CAP, `Reserve Hold must be {Windows.HOLD_CAP} seconds or less when you give a To, got {Hold}. a longer hold is written off instead of given back`)
	end

	local Op = Booking.Book(Rid, Field, Amount, Hold, To)

	return Future.New(function(): (boolean, Reason?)
		return self:Written(Resolved, Op, `reserve {Amount} {Field}`, nil, nil, function(Record: Record): Reason?
			if Booking.Entry(self:Fold(Record)._Booked, Rid) ~= nil then
				return nil
			end

			warn(
				`Ledger: booking '{Rid}' on '{Resolved}' was used before and its units have gone, so nothing was set aside. that name cannot be used again, pick a new one`
			)
			return SPENT
		end)
	end)
end

local function Standing(self: Store, Key: KeyLike, Id: string, What: string, Make: (string) -> Op, Wanted: string): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, What)
	local Rid = Validate.Name(Id, MAX_BOOKING_ID, What)
	local Doing = string.lower(What)
	local Op = Make(Rid)

	return Future.New(function(): (boolean, Reason?)
		local Ok, Why = self:Written(Resolved, Op, `{Doing} booking '{Rid}'`, function(Record: Record): boolean
			local Booked = Booking.Entry(self:Fold(Record)._Booked, Rid)
			return Booked == nil or Booked.Handing ~= true
		end, HELD)

		if Why == HELD then
			warn(
				`Ledger: booking '{Rid}' on '{Resolved}' is being handed to another key, so its units are not here to {Wanted}. a grant that did not answer may already have delivered them. leave it to the sweep`
			)
		end
		return Ok, Why
	end)
end

function Store.Confirm(self: Store, Key: KeyLike, Id: string): Future<boolean, Reason?>
	return Standing(self, Key, Id, "Confirm", Booking.Take, "spend")
end

function Store.Release(self: Store, Key: KeyLike, Id: string): Future<boolean, Reason?>
	return Standing(self, Key, Id, "Release", Booking.Free, "give back")
end

function Store.Handed(self: Store, Key: string, Rid: string, Held: Shapes.Booked): boolean
	local To = Held.To
	if type(To) ~= "string" then
		return false
	end

	local Records = self:Records()

	local Marked = Records:Append(Key, { Booking.Hand(Rid) })
	local Mine = Booking.Entry(self:Fold(Marked)._Booked, Rid)
	if Mine == nil or not Mine.Handing then
		return false
	end

	local Print = Booking.Terms(Key, Rid, Held)
	local Given = Booking.Give(Rid, Held.Field, Held.Amount, Print)
	local Landed = Records:Append(To, { Given }, function(Record: Record): boolean
		if Booking.Expired(Held, Clock.Now()) then
			return false
		end
		return Log.NotEntombed(Record) and self:Applies(Given, Record)
	end)

	local Ruling = Booking.Granted(self:Fold(Landed), Rid, Print)
	if Ruling == Tags.OTHER then
		Errors.Raise(
			SPENT,
			`'{To}' already took a booking named {Rid} from somewhere else. nothing was handed over, release this one and pick a new name`
		)
	end
	if Ruling ~= Tags.SAME then
		Errors.Raise(HELD, `'{To}' would not take booking {Rid}. the {Held.Amount} has already left '{Key}' and stays set aside until it is given back`)
	end

	local Cleared = Records:Append(Key, { Booking.Sent(Rid) })
	local Gave = TxStamp.Carries(Cleared, `{Kinds.FREE_ID}:{Rid}`) or TxStamp.Carries(Cleared, `{Kinds.UNHAND_ID}:{Rid}`)
	assert(not Gave, `booking {Rid} was handed to '{To}' but '{Key}' had already given the same units back, so they are on both keys`)

	self:Went(Key)
	self:Went(To)
	return true
end

function Store.Grant(self: Store, Key: KeyLike, Id: string): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Grant")
	local Rid = Validate.Name(Id, MAX_BOOKING_ID, "Grant")

	return Future.New(function(): (boolean, Reason?)
		local Ok, Gave = pcall(function(): boolean
			local Held = Booking.Entry(self:Fold(self:ReadRecord(Resolved))._Booked, Rid)
			if Held == nil then
				return false
			end
			if Booking.Late(Held, Clock.Now()) then
				Errors.Raise(SPENT, `booking '{Rid}' on '{Resolved}' has run past its hold, so it cannot be handed over now. its units go back on their own, reserve them again`)
			end
			assert(type(Held.To) == "string", `booking '{Rid}' was not reserved with a To, so there is nowhere to hand it to`)
			return self:Handed(Resolved, Rid, Held)
		end)
		if not Ok then
			self.Sweep:Add(self:Swept(), Resolved)
			return false, Failed(`hand over booking '{Rid}' on`, Resolved, Gave)
		end
		return Gave, if Gave then nil else REFUSED
	end)
end

function Store.TallyName(self: Store, Name: any, Field: any, What: string): string
	self:Live(What)
	assert(self.Keys == "String", `{What} is for string keyed stores, '{self.Options.Name}' uses player keys`)
	assert(
		type(Name) == "string" and #Name > 0 and #Name + #Shards.PART + 2 <= Datastore.MAX_KEY and utf8.len(Name) ~= nil,
		`{What} needs a Name short enough to carry a shard number, up to {Datastore.MAX_KEY - #Shards.PART - 2} characters`
	)
	Validate.Field(self.Initial, Field, What)
	return Name
end

function Store.Kept(self: Store, Slot: string, Now: number): Tally.Recent
	local Held = self.Recent:Get(Slot)
	if Held ~= nil then
		Trimmed(Held, Now)
		return Held
	end

	local Fresh: Tally.Recent = { Sum = 0, At = 0, Seen = 0, Bumps = {} }
	return self.Recent:Put(Slot, Fresh)
end

function Store.Bump(self: Store, Name: string, Field: string, Amount: number): Future<boolean, Reason?>
	self:TallyName(Name, Field, "Bump")
	assert(
		type(Amount) == "number" and Amount > 0 and Amount < math.huge,
		`Bump needs a positive finite Amount. a tally is spread over keys that cannot see each other, so nothing can be taken back out of one`
	)

	local Key = Tally.Shard(Name, Tally.Mine(self.Node))
	local Op = Tally.Bump(Field, Amount)
	local Slot = Tally.Cache(self.Wrapper.Name, Name, Field)

	return Future.New(function(): (boolean, Reason?)
		local Ok, Why = self:Written(Key, Op, `add {Amount} to '{Name}'`)
		if Ok then
			local Now = Clock.Now()
			local Held = self:Kept(Slot, Now)
			self.Bumped += 1
			Bumped(Held, self.Bumped, Now, Amount)
		end
		return Ok, Why
	end)
end

function Store.Total(self: Store, Name: string, Field: string, MaxAge: number?): Future<number?, Reason?>
	self:TallyName(Name, Field, "Total")
	assert(MaxAge == nil or (type(MaxAge) == "number" and MaxAge >= 0 and MaxAge < math.huge), `Total MaxAge must be a number of seconds when given, got {tostring(MaxAge)}`)

	local Slot = Tally.Cache(self.Wrapper.Name, Name, Field)

	return Future.New(function(): (number?, Reason?)
		local Now = Clock.Now()
		local Held = self:Kept(Slot, Now)
		if MaxAge ~= nil and Held.Seen > 0 and Now - Held.Seen <= MaxAge then
			return Held.Sum + Over(Held), nil
		end

		local Tallies = self.Tallies
		if Tallies ~= nil then
			local Read, Value = Tallies:GetAsync(Slot)
			local Item = if Read then Tally.Read(Value) else nil
			if Item ~= nil then
				if Tally.Fresh(Item, Now) or Tally.Claimed(Item, Now) then
					return Remember(Held, Item.Sum, Item.At, Now), nil
				end

				local Won, Claim = Tallies:UpdateAsync(Slot, function(Current: any): any
					local Stale = Tally.Read(Current)
					if Stale == nil or Tally.Fresh(Stale, Now) or Tally.Claimed(Stale, Now) then
						return nil
					end
					return { Sum = Stale.Sum, At = Stale.At, Claimed = Now }
				end, Windows.TALLY_KEEP)
				if not Won or Claim == nil then
					return Remember(Held, Item.Sum, Item.At, Now), nil
				end
			end
		end

		local Mark = self.Bumped
		local Sum = 0
		for _, Key in Tally.Keys(Name) do
			local Ok, State = pcall(function(): any
				return self:Fold(self:ReadRecord(Key))
			end)
			if not Ok then
				return nil, Failed(`read a shard of '{Name}' for`, Key, State)
			end

			Sum += Tally.Counted(State, Field)
		end

		if Tallies ~= nil then
			Tallies:UpdateAsync(Slot, function(Current: any): any
				local Newer = Tally.Read(Current)
				if Newer ~= nil and Newer.At > Now then
					return nil
				end
				return { Sum = Sum, At = Now }
			end, Windows.TALLY_KEEP)
		end
		return Remember(Held, Sum, Now, Now, Mark), nil
	end)
end

local function LegStore(Coordinator: Store, Index: number, Leg: TxLeg): Store
	if Leg.Store == nil then
		return Coordinator
	end

	assert(getmetatable(Leg.Store :: any) == Store, `Tx leg {Index} names a Store that was not built by Ledger.New`)
	return Leg.Store :: any
end

local function LegStorable(Leg: TxLeg): (boolean, string?)
	local Probe: { [any]: any } = if Leg.Fields then table.clone(Leg.Fields) else {}
	Probe.Id = "probe"
	Probe.Kind = Leg.Kind

	return Storable.Op(Probe)
end

local function MapLeg(Coordinator: Store, Index: number, Leg: TxLeg, Touched: { [string]: boolean }): (Tx.Leg, LegTarget)
	assert(type(Leg) == "table", `Tx leg {Index} is not a table`)
	assert(type(Leg.Kind) == "string" and #Leg.Kind > 0, `Tx leg {Index} needs a non-empty string Kind`)
	assert(Leg.Fields == nil or type(Leg.Fields) == "table", `Tx leg {Index} Fields must be a table when given`)
	assert(Leg.Fields == nil or (Leg.Fields :: any).Once == nil, `Tx leg {Index} carries Once, but the transaction Id already makes every leg land at most once. drop it`)

	local Target = LegStore(Coordinator, Index, Leg)
	local Raw = if Target.Keys == "Player" then Leg.UserId else Leg.Key
	local Resolved = Target:KeyFor(Raw)
	assert(Resolved, `Tx leg {Index} needs {Target:KeyIssue()}`)

	local Mark = Target:Mark(Resolved)
	assert(not Touched[Mark], `Tx leg {Index} touches '{Resolved}' twice, a transaction may only touch a key once per store`)
	Touched[Mark] = true

	return {
		Key = Resolved,
		Kind = Leg.Kind,
		Fields = Leg.Fields,
		Log = Target:Records(),
		Shape = Target:Format(),
		TxStore = Target.TxWrapper,
	}, { Store = Target, Key = Resolved }
end

local function Follow(Targets: { LegTarget })
	for _, Target in Targets do
		Target.Store.Sweep:Add(Target.Store:Swept(), Target.Key)
	end
end

function Store.Tx(self: Store, Id: string, Legs: { TxLeg }): Future<boolean, Reason?>
	self:Live("Tx")
	assert(
		type(Id) == "string" and #Id > 0 and #Id <= MAX_TX_ID and utf8.len(Id) ~= nil,
		`Tx needs an Id first, a stable name of 1 to {MAX_TX_ID} characters derived from the thing being settled, never from the clock`
	)
	assert(string.sub(Id, 1, #Transactions.RESERVED) ~= Transactions.RESERVED, `Tx Id cannot start with '{Transactions.RESERVED}', Ledger keeps that prefix for its own keys`)
	assert(type(Legs) == "table", "Tx takes an array of legs after the Id")
	assert(#Legs >= 2 and #Legs <= Transactions.MAX_LEGS, `Tx takes 2 to {Transactions.MAX_LEGS} legs, got {#Legs}`)

	local Mapped: { Tx.Leg } = table.create(#Legs) :: { Tx.Leg }
	local Targets: { LegTarget } = table.create(#Legs) :: { LegTarget }
	local Touched: { [string]: boolean } = {}

	for Index, Leg in Legs do
		Mapped[Index], Targets[Index] = MapLeg(self, Index, Leg, Touched)

		local Fits, Unstorable = LegStorable(Leg)
		if not Fits then
			warn(`Ledger: Tx rejected leg {Index} '{Leg.Kind}', {Unstorable}`)
			return Rejected(INVALID)
		end
	end

	assert(#Mapped == #Legs and #Targets == #Legs, "a transaction ended up with a different number of legs than it was given")

	return Future.New(function(): (boolean, Reason?)
		local Ok, Committed, Why, Parked = pcall(function(): (boolean, Reason?, boolean)
			return Tx.Drive(self.TxWrapper, Mapped, Id)
		end)

		if not Ok then
			warn(`Ledger: transaction '{Id}' broke inside Ledger and its legs might still be pending: {Committed}`)
			Follow(Targets)
			return false, UNRESOLVED
		end

		if Why == BUSY or Parked then
			Follow(Targets)
		end
		if Committed then
			for _, Target in Targets do
				Target.Store:Went(Target.Key)
			end
		end
		return Committed :: boolean, Why :: Reason?
	end)
end

return table.freeze({})
