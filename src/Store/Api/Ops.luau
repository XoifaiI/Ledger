--!strict
--!optimize 2

--[=[

	Ops: The writes a game asks for by name.

	Edit, Confirm and Bump build one op and hand it to Written. Reserve, Release and Holds work on
	the MemoryStore item and never touch the key. Transfer and Tx run a protocol over more than one
	key, and add the keys to the sweep when they cannot finish.

	A confirm carries the hold it spends, so a name reused after an earlier confirm answers Spent. A
	hold item is kept inside the map's item cap, and outlives the longest hold by one margin so the
	stock it caches is still there for the next reservation.

	A total answers this server's own sum inside MaxAge, then reads the shared copy, and one server
	refills a stale one. A bump writes only its shard and carries no name, so one that answers
	Unresolved is not asked again. This server lays its own bumps over the sum it answers, in buckets
	of one second, and a refill seals the open bucket when it reads this server's own shard, so no
	bucket holds bumps from both sides of that read.

	A transaction leases each key in one fixed order and lets go on every exit. The marker still
	decides. A lease it cannot take means drive without one, and a key another server holds answers
	Busy at once.

	Return type: An empty table. It writes Edit, EditOp, Transfer, Unbooked, Crowded, Holding, Standing, Dropped, Reserve, Confirm, Release, Holds, TallyName, Kept, Bump, Flushed, Total, Leased, Claim and Tx onto the class.
	Example usage:
		local Ops = require("./Ops")
		local Ok, Why = self:Edit(1, "Add", { Amount = 5 }):Wait()
--]=]

local Future = require("../../Util/Future")
local Clock = require("../../Util/Clock")
local TableUtil = require("../../Util/TableUtil")
local MemoryStoreWrapper = require("../../Util/MemoryStoreWrapper")
local Windows = require("../../Core/Constants/Windows")
local Sizes = require("../../Core/Constants/Sizes")
local MemoryStore = require("../../Core/Constants/MemoryStore")
local Bookings = require("../../Core/Constants/Bookings")
local Reasons = require("../../Core/Constants/Reasons")
local Shapes = require("../../Core/Shapes")
local Api = require("../../Core/Api")
local Ids = require("../../Encode/Ids")
local Measure = require("../../Encode/Measure")
local Storable = require("../../Encode/Storable")
local NewOp = require("../../Record/NewOp")
local Shards = require("../../Core/Constants/Shards")
local Datastore = require("../../Core/Constants/Datastore")
local Mark = require("../../Encode/Mark")
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
type MemoryStoreWrapper = MemoryStoreWrapper.MemoryStoreWrapper
type Reserved = Types.Reserved
type Dropped = Types.Dropped
type Hold = Types.Hold
type Recent = Types.Recent
type Copy = Types.Copy
type Holding = { Holds: { [string]: Hold }, Stock: { [string]: number } }

local MAX_TRANSFER_ID = 64
local MAX_TX_ID = 50
local MAX_BOOKING_ID = 64
local SHARD_DIGITS = #tostring(Shards.MOST)
local BUMP_BUDGET = 4
local BOOK_KEEP = Windows.BOOK + Windows.BOOK_MARGIN

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

local function Trimmed(Held: Recent, Now: number)
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

local function Over(Held: Recent): number
	local Mark = Held.Mark
	local Floor = Held.Floor or Held.At
	local Sum = 0
	for _, Bucket in Held.Bumps do
		if if Mark ~= nil then Bucket.Seq > Mark else Bucket.At > Floor then
			Sum += Bucket.Amount
		end
	end
	return Sum
end

local function Sealed(Held: Recent, Seq: number)
	local Shut = Held.Sealed
	Held.Sealed = if Shut ~= nil and Shut > Seq then Shut else Seq
end

local function Bumped(Held: Recent, Seq: number, Now: number, Amount: number)
	local Bumps = Held.Bumps
	local Last = Bumps[#Bumps]
	local Shut = Held.Sealed
	if Last ~= nil and Last.At == Now and (Shut == nil or Last.Seq > Shut) then
		Last.Amount += Amount
		return
	end
	table.insert(Bumps, { Seq = Seq, At = Now, Amount = Amount })
end

local function Remember(Held: Recent, Sum: number, At: number, Seen: number, Mark: number?, Floor: number?): number
	Held.Sum = Sum
	Held.At = At
	Held.Seen = Seen
	Held.Floor = Floor or At
	Held.Mark = if Mark ~= nil then Mark elseif At == Held.OwnAt then Held.OwnMark else nil
	if Mark ~= nil then
		Held.OwnAt = At
		Held.OwnMark = Mark
	end
	return Sum + Over(Held)
end

local function Holdings(Value: any): Holding?
	if type(Value) ~= "table" or type(Value.Holds) ~= "table" or type(Value.Stock) ~= "table" then
		return nil
	end
	return Value
end

local function Unexpired(Item: Holding, Now: number): ({ [string]: Hold }, { [string]: number })
	local Fresh: { [string]: Hold } = {}
	local Sums: { [string]: number } = {}
	for Rid, Held in Item.Holds do
		if type(Held) ~= "table" or type(Held.Field) ~= "string" or type(Held.Amount) ~= "number" or type(Held.Ends) ~= "number" or Held.Ends <= Now then
			continue
		end
		if Held.Gen ~= nil and type(Held.Gen) ~= "string" then
			continue
		end
		Fresh[Rid] = Held
		Sums[Held.Field] = (Sums[Held.Field] or 0) + Held.Amount
	end
	return Fresh, Sums
end

local function Fitted(Item: Holding): Holding?
	return if Measure(Item) <= MemoryStore.MAX_ITEM then Item else nil
end

local function Rewritten(Held: MemoryStoreWrapper, Slot: string, Change: (Holding?) -> Holding?): boolean
	return (Held:UpdateAsync(Slot, function(Current: any): any
		return Change(Holdings(Current))
	end, BOOK_KEEP))
end

local function Waiting(self: Store, Slot: string): number
	local Bumps = self.Bumps
	if Bumps == nil then
		return 0
	end

	local Held = Bumps.Queued[Slot]
	return (if Held ~= nil then Held.Amount else 0) + (Bumps.Flushing[Slot] or 0)
end

local function Requeued(Bumps: Types.Batched, Slot: string, Held: Types.Queued)
	local Back = Bumps.Queued[Slot]
	if Back == nil then
		Bumps.Queued[Slot] = Held
		return
	end
	Back.Amount += Held.Amount
	for _, Thread in Held.Threads do
		table.insert(Back.Threads, Thread)
	end
end

local function Queued(Bumps: Types.Batched, Slot: string, Name: string, Field: string, Amount: number): Types.Queued
	local Held = Bumps.Queued[Slot]
	if Held ~= nil then
		Held.Amount += Amount
		return Held
	end

	local Threads: { thread } = {}
	local Fresh: Types.Queued = {
		Name = Name,
		Field = Field,
		Amount = Amount,
		Threads = Threads,
		Answer = Future.New(function(): (boolean, Reason?)
			table.insert(Threads, coroutine.running())
			return coroutine.yield()
		end),
	}
	Bumps.Queued[Slot] = Fresh
	return Fresh
end

local function Answered(self: Store, Held: Types.Queued, Ok: boolean, Why: Reason?)
	local Resume = self.Wrapper.Scheduler.Resume
	for _, Thread in Held.Threads do
		Resume(Thread, Ok, Why)
	end
	table.clear(Held.Threads)
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

function Store.EditOp(self: Store, Key: KeyLike, Op: Op): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "EditOp")
	if not Validate.Op(Op) then
		warn("Ledger: EditOp rejected the op, an op needs a string Id and a string Kind")
		return Rejected(INVALID)
	end

	local Held: Op = TableUtil.DeepCopy(Op)
	local Fine, Wrong = NewOp.Check(Held)
	if not Fine then
		warn(`Ledger: EditOp rejected op '{Held.Kind}', {Wrong}`)
		return Rejected(INVALID)
	end

	return Future.New(function(): (boolean, Reason?)
		return self:Written(Resolved, Held, `edit '{Held.Kind}'`)
	end)
end

function Store.Transfer(self: Store, From: KeyLike, To: KeyLike, Amount: number, Id: string?, Field: string?): Future<boolean, Reason?>
	local FromKey = self:Resolve(From, "Transfer")
	local ToKey = self:Resolve(To, "Transfer")
	assert(FromKey ~= ToKey, `Transfer needs two different keys, both resolved to '{FromKey}'`)
	Validate.Amount(Amount, "Transfer")
	Validate.Maybe(Id, MAX_TRANSFER_ID, "Transfer Id")

	local Named: string? = nil
	if Field ~= nil then
		Named = Validate.Field(self.Initial, Field, "Transfer")
	else
		self:ExpectBalance("Transfer")
	end
	if Named == self.Options.Balance then
		Named = nil
	end

	return Future.New(function(): (boolean, Reason?)
		local Ok, Moved, Why, Follow = pcall(function(): (boolean, Reason?, boolean?)
			return Transfer.Drive(self:Records(), self:Format(), FromKey, ToKey, Amount, Id, Named)
		end)
		if not Ok then
			warn(`Ledger: the transfer from '{FromKey}' broke inside Ledger: {Moved}`)
			self.Sweep:Add(self:Swept(), FromKey)
			return false, UNRESOLVED
		end

		if Why == BUSY or Why == HELD or Why == UNRESOLVED or Follow then
			self.Sweep:Add(self:Swept(), FromKey)
		end
		if Moved then
			self:Went(FromKey)
			self:Went(ToKey)
		end
		return Moved :: boolean, Why :: Reason?
	end)
end

function Store.Unbooked(self: Store, What: string)
	local Meter = self.Meter
	local Now = Clock.Now()
	if Now - Meter.Unbooked < Windows.AUTOSAVE then
		return
	end

	Meter.Unbooked = Now
	warn(`Ledger: {What} on '{self.Options.Name}' needs a MemoryStore and this store has none, so nothing was set aside`)
end

function Store.Crowded(self: Store, Key: string, Rid: string, Count: number)
	local Meter = self.Meter
	local Now = Clock.Now()
	if Now - Meter.Crowded < Windows.AUTOSAVE then
		return
	end

	Meter.Crowded = Now
	warn(`Ledger: '{Key}' already holds {Count} reservations and has no room for another, so '{Rid}' was not set aside`)
end

function Store.Holding(self: Store, Slot: string, Rid: string, Field: string, Amount: number, Now: number, Ends: number, Stock: number?): (Reserved, number?, number, Hold?)
	local Held = self.Bookings
	if Held == nil then
		return Bookings.UNKNOWN, nil, 0, nil
	end

	local Gen = Ids.Fresh()
	local Answer: Reserved = Bookings.UNKNOWN
	local Known: number? = nil
	local Count = 0
	local Standing: Hold? = nil
	local Ok = Rewritten(Held, Slot, function(Item: Holding?): Holding?
		Answer, Known, Count, Standing = Bookings.UNKNOWN, nil, 0, nil
		local Base: Holding = Item or { Holds = {}, Stock = {} }
		if Stock ~= nil then
			Base.Stock[Field] = Stock
		end

		local Have = Base.Stock[Field]
		if type(Have) ~= "number" then
			Answer = Bookings.COLD
			return nil
		end
		Known = Have

		local Fresh, Sums = Unexpired(Base, Now)
		Count = TableUtil.Count(Fresh)
		local Mine = Fresh[Rid]
		if Mine ~= nil then
			if Mine.Field ~= Field or Mine.Amount ~= Amount then
				Answer = Bookings.SPENT
				Standing = Mine
				return nil
			end
			Answer = Bookings.TAKEN
			if Mine.Ends >= Ends then
				return nil
			end
			Fresh[Rid] = { Field = Mine.Field, Amount = Mine.Amount, Ends = Ends, Gen = Mine.Gen }
			return Fitted({ Holds = Fresh, Stock = Base.Stock })
		end
		if Count >= Sizes.Booked then
			Answer = Bookings.FULL
			return nil
		end
		if (Sums[Field] or 0) + Amount > Have then
			Answer = Bookings.REFUSED
			return if Stock ~= nil then Fitted({ Holds = Fresh, Stock = Base.Stock }) else nil
		end

		Fresh[Rid] = { Field = Field, Amount = Amount, Ends = Ends, Gen = Gen }
		local Next = Fitted({ Holds = Fresh, Stock = Base.Stock })
		if Next == nil then
			Answer = Bookings.FULL
			return nil
		end
		Answer = Bookings.TAKEN
		Count += 1
		return Next
	end)

	if not Ok then
		return Bookings.UNKNOWN, nil, 0, nil
	end
	return Answer, Known, Count, Standing
end

function Store.Standing(self: Store, Slot: string, Rid: string): string?
	local Held = self.Bookings
	if Held == nil then
		return nil
	end

	local Read, Value = Held:GetAsync(Slot)
	if not Read or Value == nil then
		return nil
	end
	local Item = Holdings(Value)
	if Item == nil then
		return nil
	end

	local Fresh = Unexpired(Item, Clock.Now())
	local Mine = Fresh[Rid]
	return if Mine ~= nil then Mine.Gen else nil
end

function Store.Dropped(self: Store, Slot: string, Rid: string, State: any): Dropped
	local Held = self.Bookings
	if Held == nil then
		return Bookings.ABSENT
	end

	local Answer: Dropped = Bookings.UNKNOWN
	local Now = Clock.Now()
	local Ok = Rewritten(Held, Slot, function(Item: Holding?): Holding?
		Answer = Bookings.MISSING
		if Item == nil then
			return nil
		end

		local Fresh = Unexpired(Item, Now)
		local Mine = Fresh[Rid]
		if Mine == nil then
			return nil
		end

		Fresh[Rid] = nil
		local Stock = Validate.Numbered(State, Mine.Field)
		if Stock ~= nil then
			Item.Stock[Mine.Field] = Stock
		end
		Answer = Bookings.DROPPED
		return { Holds = Fresh, Stock = Item.Stock }
	end)

	if not Ok then
		return Bookings.UNKNOWN
	end
	return Answer
end

function Store.Reserve(self: Store, Key: KeyLike, Field: string, Amount: number, Id: string, Options: HoldOptions?): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Reserve")
	Validate.Field(self.Initial, Field, "Reserve")
	Validate.Amount(Amount, "Reserve")
	local Rid = Validate.Name(Id, MAX_BOOKING_ID, "Reserve")

	local Extra: HoldOptions = Options or {}
	assert(type(Extra) == "table", "Reserve takes an options table after the Id when you pass one")
	assert((Extra :: any).To == nil, "Reserve does not take To. a hold stays on its key, hand units to another key with Transfer and a Field")

	local Hold = Extra.Hold
	assert(
		Hold == nil or (type(Hold) == "number" and Hold > 0 and Hold <= Windows.BOOK),
		`Reserve Hold must be a number of seconds up to {Windows.BOOK} when given, got {tostring(Hold)}. reserve again under the same Id to keep a hold alive for longer`
	)

	local Slot = Mark.Cached({ self.Wrapper.Name, Resolved })

	return Future.New(function(): (boolean, Reason?)
		if self.Bookings == nil then
			self:Unbooked("Reserve")
			return false, UNRESOLVED
		end

		local Now = Clock.Now()
		local Ends = Now + (Hold or Windows.BOOK)
		local Answer, Known, Count, Standing = self:Holding(Slot, Rid, Field, Amount, Now, Ends, nil)
		if Answer == Bookings.COLD or Answer == Bookings.REFUSED then
			local Read, State = pcall(function(): any
				return self:Fold(self:ReadRecord(Resolved))
			end)
			if not Read then
				return false, Failed(`read the {Field} on`, Resolved, State)
			end

			local Stock = Validate.Numbered(State, Field)
			if Stock == nil then
				return false, REFUSED
			end
			if Answer == Bookings.COLD or Stock ~= Known then
				Answer, Known, Count, Standing = self:Holding(Slot, Rid, Field, Amount, Now, Ends, Stock)
			end
		end

		if Answer == Bookings.TAKEN then
			return true, nil
		end
		if Answer == Bookings.REFUSED then
			return false, REFUSED
		end
		if Answer == Bookings.SPENT and Standing ~= nil then
			warn(`Ledger: '{Rid}' on '{Resolved}' already holds {Standing.Amount} {Standing.Field}, so it keeps that. pick a new name to hold {Amount} {Field}`)
			return false, SPENT
		end
		if Answer == Bookings.FULL then
			self:Crowded(Resolved, Rid, Count)
			return false, BUSY
		end
		return false, UNRESOLVED
	end)
end

function Store.Confirm(self: Store, Key: KeyLike, Id: string, Kind: string, Fields: { [any]: any }?): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Confirm")
	local Rid = Validate.Name(Id, MAX_BOOKING_ID, "Confirm")
	assert(type(Kind) == "string" and #Kind > 0, "Confirm needs the Kind of the op that spends the units, after the Id")
	assert(Fields == nil or type(Fields) == "table", `Confirm '{Kind}' Fields must be a table when given`)

	local Op = NewOp.New(Kind, Fields)
	Op.Id = `{Bookings.CONFIRM_ID}:{Rid}`
	local Fine, Wrong = NewOp.Check(Op)
	if not Fine then
		warn(`Ledger: Confirm rejected op '{Kind}', {Wrong}`)
		return Rejected(INVALID)
	end

	local Slot = Mark.Cached({ self.Wrapper.Name, Resolved })

	return Future.New(function(): (boolean, Reason?)
		local Gen = self:Standing(Slot, Rid)
		if Gen ~= nil then
			(Op :: any).Booking = Gen
		end

		local State: any = nil
		local Ok, Why = self:Written(
			Resolved,
			Op,
			`confirm booking '{Rid}' with '{Kind}'`,
			function(Record: Record): boolean
				for _, Existing in Record.Ops do
					if Existing.Id == Op.Id then
						return Gen == nil or Existing.Booking == nil or Existing.Booking == Gen
					end
				end
				return true
			end,
			SPENT,
			function(Settled: Record): Reason?
				State = self:Fold(Settled)
				return nil
			end
		)

		if Ok then
			self:Dropped(Slot, Rid, State)
		elseif Why == SPENT then
			warn(`Ledger: booking '{Rid}' on '{Resolved}' was already spent by an earlier confirm under that name, so nothing was sold. pick a new name for each purchase`)
		end
		return Ok, Why
	end)
end

function Store.Release(self: Store, Key: KeyLike, Id: string): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Release")
	local Rid = Validate.Name(Id, MAX_BOOKING_ID, "Release")
	local Slot = Mark.Cached({ self.Wrapper.Name, Resolved })

	return Future.New(function(): (boolean, Reason?)
		local Gone = self:Dropped(Slot, Rid, nil)
		if Gone == Bookings.DROPPED then
			return true, nil
		end
		if Gone == Bookings.MISSING then
			return false, REFUSED
		end
		if Gone == Bookings.ABSENT then
			self:Unbooked("Release")
		end
		return false, UNRESOLVED
	end)
end

function Store.Holds(self: Store, Key: KeyLike, Field: string): Future<number?, Reason?>
	local Resolved = self:Resolve(Key, "Holds")
	Validate.Field(self.Initial, Field, "Holds")
	local Slot = Mark.Cached({ self.Wrapper.Name, Resolved })

	return Future.New(function(): (number?, Reason?)
		local Held = self.Bookings
		if Held == nil then
			self:Unbooked("Holds")
			return nil, UNRESOLVED
		end

		local Read, Value = Held:GetAsync(Slot)
		if not Read then
			return nil, UNRESOLVED
		end
		if Value == nil then
			return 0, nil
		end

		local Item = Holdings(Value)
		if Item == nil then
			return nil, UNRESOLVED
		end
		local _, Sums = Unexpired(Item, Clock.Now())
		return Sums[Field] or 0, nil
	end)
end

function Store.TallyName(self: Store, Name: any, Field: any, What: string): string
	self:Live(What)
	assert(self.Keys == "String", `{What} is for string keyed stores, '{self.Options.Name}' uses player keys`)
	assert(
		type(Name) == "string" and #Name > 0 and #Name + #Shards.PART + SHARD_DIGITS <= Datastore.MAX_KEY and utf8.len(Name) ~= nil,
		`{What} needs a Name short enough to carry a shard number, up to {Datastore.MAX_KEY - #Shards.PART - SHARD_DIGITS} characters`
	)
	Validate.Field(self.Initial, Field, What)
	return Name
end

function Store.Kept(self: Store, Slot: string, Now: number): Recent
	local Held = self.Recent:Get(Slot)
	if Held ~= nil then
		Trimmed(Held, Now)
		return Held
	end

	local Fresh: Recent = { Sum = 0, At = 0, Seen = 0, Slack = self.Wrapper.Scheduler.Roll() * Windows.COPY_SLACK, Behind = false, Bumps = {} }
	return self.Recent:Put(Slot, Fresh)
end

function Store.Bump(self: Store, Name: string, Field: string, Amount: number): Future<boolean, Reason?>
	self:TallyName(Name, Field, "Bump")
	assert(
		type(Amount) == "number" and Amount > 0 and Amount < math.huge,
		`Bump needs a positive finite Amount. a tally is spread over keys that cannot see each other, so nothing can be taken back out of one`
	)

	local Key = Tally.Shard(Name, Tally.Mine(self.Node, self.Shards))
	local Op = Tally.Bump(Field, Amount)
	local Slot = Tally.Cache(self.Wrapper.Name, Name, Field)

	local Bumps = self.Bumps
	if Bumps ~= nil then
		return Queued(Bumps, Slot, Name, Field, Amount).Answer
	end

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

function Store.Flushed(self: Store)
	local Bumps = self.Bumps
	if Bumps == nil or next(Bumps.Queued) == nil then
		return
	end
	local Queued = Bumps.Queued
	Bumps.Queued = {}

	local Flushing = Bumps.Flushing
	for Slot, Held in Queued do
		if not self:AffordsWrite(BUMP_BUDGET) then
			Requeued(Bumps, Slot, Held)
			continue
		end

		local Amount = Held.Amount
		Flushing[Slot] = (Flushing[Slot] or 0) + Amount
		local Key = Tally.Shard(Held.Name, Tally.Mine(self.Node, self.Shards))
		local Ok, Why = self:Written(Key, Tally.Bump(Held.Field, Amount), `add {Amount} to '{Held.Name}'`)

		local Left = (Flushing[Slot] or 0) - Amount
		Flushing[Slot] = if Left > 0 then Left else nil
		if Ok then
			local Now = Clock.Now()
			local Recent = self:Kept(Slot, Now)
			self.Bumped += 1
			Bumped(Recent, self.Bumped, Now, Amount)
		end
		Answered(self, Held, Ok, Why)
	end
end

function Store.Total(self: Store, Name: string, Field: string, MaxAge: number?): Future<number?, Reason?>
	self:TallyName(Name, Field, "Total")
	assert(MaxAge == nil or (type(MaxAge) == "number" and MaxAge >= 0 and MaxAge < math.huge), `Total MaxAge must be a number of seconds when given, got {tostring(MaxAge)}`)

	local Slot = Tally.Cache(self.Wrapper.Name, Name, Field)

	local Age = MaxAge or Windows.TALLY_CACHE

	return Future.New(function(): (number?, Reason?)
		local Now = Clock.Now()
		local Held = self:Kept(Slot, Now)
		if Age > 0 and Held.Seen > 0 and Now - Held.Seen <= Age then
			return Held.Sum + Over(Held) + Waiting(self, Slot), nil
		end

		local Count = self.Shards
		local Mine = Tally.Mine(self.Node, Count)
		local Mark: number? = nil
		local Source: Types.Source = {
			Key = Name,
			Slot = Slot,
			Map = self.Tallies,
			Cost = Count,
			Fits = false,
			Refill = function(_Copy: Copy): (any?, number?, Reason?)
				local Own = Tally.Shard(Name, Mine)
				local Counted = self.Bumped
				Sealed(Held, Counted)
				local Sum = 0
				local Read: { number } = table.create(Count) :: { number }
				for Index, Key in Tally.Keys(Name, Count) do
					Read[Index] = Clock.Now()
					local Ok, State = pcall(function(): any
						return self:Fold(self:ReadRecord(Key))
					end)
					if not Ok then
						return nil, nil, Failed(`read a shard of '{Name}' for`, Key, State)
					end

					Sum += Tally.Counted(State, Field)
					if Key == Own then
						Counted = self.Bumped
						Sealed(Held, Counted)
					end
				end

				Mark = Counted
				return { Sum = Sum, Read = Read }, nil, nil
			end,
		}

		local State, Why = self:Copied(Held, Now, false, Source)
		if type(State) ~= "table" or type(State.Sum) ~= "number" then
			return nil, Why or UNRESOLVED
		end
		return Remember(Held, State.Sum, Held.At, Held.Seen, Mark, Tally.Since(State, Mine)) + Waiting(self, Slot), nil
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

local function Freed(Taken: { () -> () })
	for _, Release in Taken do
		Release()
	end
end

function Store.Leased(self: Store, Targets: { { Name: string, Key: string } }): ({ () -> () }, boolean)
	local Taken: { () -> () } = {}
	if self.Leases == nil or not self:AffordsWrite(Transactions.LEASE_BUDGET) then
		return Taken, false
	end

	local Keys: { string } = table.create(#Targets) :: { string }
	for Index, Target in Targets do
		Keys[Index] = Mark.Cached({ "tx", Target.Name, Target.Key })
	end
	table.sort(Keys)

	for _, Key in Keys do
		local Claim = self:Claim(Key, Windows.TX_LEASE)
		if Claim.Outcome == Transactions.TAKEN then
			table.insert(Taken, Claim.Release)
			continue
		end

		Freed(Taken)
		return {}, Claim.Outcome == Transactions.HELD
	end
	return Taken, false
end

function Store.Claim(self: Store, Key: string, Ttl: number): Types.Claimed
	local Leases = self.Leases
	if Leases == nil then
		return { Outcome = Transactions.ABSENT }
	end

	local Node = self.Node
	local Read, Holder = Leases:GetAsync(Key)
	if not Read then
		return { Outcome = Transactions.UNKNOWN }
	end
	if Holder ~= nil and Holder ~= Node then
		return { Outcome = Transactions.HELD }
	end

	local Ok, Won = Leases:UpdateAsync(Key, function(Current: any): any
		if Current ~= nil and Current ~= Node then
			return nil
		end
		return Node
	end, Ttl)

	if not Ok then
		return { Outcome = Transactions.UNKNOWN }
	end
	if Won == nil then
		return { Outcome = Transactions.HELD }
	end
	return {
		Outcome = Transactions.TAKEN,
		Release = function()
			Leases:RemoveAsync(Key)
		end,
	}
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

	local Leasing: { { Name: string, Key: string } } = table.create(#Legs) :: { { Name: string, Key: string } }
	for Index, Target in Targets do
		Leasing[Index] = { Name = Target.Store.Wrapper.Name, Key = Target.Key }
	end

	return Future.New(function(): (boolean, Reason?)
		local Taken, Held = self:Leased(Leasing)
		if Held then
			return false, BUSY
		end

		local Ok, Committed, Why, Parked = pcall(function(): (boolean, Reason?, boolean)
			return Tx.Drive(self.TxWrapper, Mapped, Id, self.Node)
		end)
		Freed(Taken)

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
