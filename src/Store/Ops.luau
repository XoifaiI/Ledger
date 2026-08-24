--!strict
--!optimize 2

--[=[
	Ops: The writes that a game asks for by name.

	Each one checks its arguments, builds one op, and gives that op to Written.
	The ones that touch two keys are the exceptions.
	Grant writes the receiver first and clears the hold second. That is the order that a transfer
	uses, and for the same reason. A server that stops between the two leaves the units on both keys,
	which recovery can see and settle.
	A hand over marks the booking on the sender before it writes the receiver, and goes on only once
	that mark is on the key. Reading the mark back out of the state is what proves it, because an op
	sits in the log whether or not the reducer took it. Something else took the booking in between
	means nothing is handed over at all.
	A leg that names another store must carry the class that Ledger.New gives a store.
	Grant turns away a booking that has run past its hold. Recovery takes those units back a margin
	later, so the two cannot both act on one booking.

	Return type: A table with Edit, Transfer, Reserve, Confirm, Release, Grant, Handed, Bump, Total and Tx.
	Example usage:
		local Ops = require("./Ops")
		local Ok, Why = self:Edit(1, "Add", { Amount = 5 }):Wait()
--]=]

local Future = require("../Util/Future")
local Clock = require("../Util/Clock")
local Fault = require("../Contract/Fault")
local Reasons = require("../Contract/Reason")
local Contract = require("../Contract/Op")
local Public = require("../Contract/Public")
local IsStorable = require("../Encode/Storable")
local Entries = require("../Kernel/Entries")
local Log = require("../Record/Log")
local MakeOp = require("../Record/MakeOp")
local Stamp = require("../Record/Stamp")
local Booking = require("../Feature/Booking")
local Tally = require("../Feature/Tally")
local Transfer = require("../Protocol/Transfer")
local Tx = require("../Protocol/Tx")
local Arg = require("../Kernel/Arg")
local Core = require("./Core")
local Registry = require("./Registry")
local Write = require("./Write")
local Store = require("./Class")
local Types = require("./Types")

type Future<T...> = Future.Future<T...>
type Op = Contract.Op
type Record = Contract.Record<any>
type KeyLike = Contract.KeyLike
type TxLeg = Public.TxLeg
type HoldOptions = Public.HoldOptions
type Reason = Reasons.Reason
type Store = Types.Store
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

function Store.Edit(self: Store, Key: KeyLike, Kind: string, Fields: { [any]: any }?): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Edit")

	local Op = MakeOp.New(Kind, Fields)

	local Named, Unnamed = MakeOp.Stamp(Op)
	if not Named then
		warn(`Ledger: Edit rejected op '{Kind}', {Unnamed}`)
		return Rejected(INVALID)
	end

	local Storable, Unstorable = IsStorable.Op(Op)
	if not Storable then
		warn(`Ledger: Edit rejected op '{Kind}', {Unstorable}`)
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
	Arg.Amount(Amount, "Transfer")
	Arg.Name(Id, MAX_TRANSFER_ID, "Transfer Id", true)

	return Future.New(function(): (boolean, Reason?)
		local Ok, Moved, Why, Escrowed = pcall(function(): (boolean, Reason?, boolean?)
			return Transfer.Drive(self:Records(), self:Format(), FromKey, ToKey, Amount, Id)
		end)
		if not Ok then
			warn(`Ledger: the transfer from '{FromKey}' broke inside Ledger: {Moved}`)
			return false, UNRESOLVED
		end

		if Why == BUSY or Why == HELD or Escrowed then
			Registry.Sweep():Add(self, FromKey)
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
	Arg.Field(self.Initial, Field, "Reserve")
	Arg.Amount(Amount, "Reserve")
	local Rid = Arg.Name(Id, MAX_BOOKING_ID, "Reserve", false)

	local Extra: HoldOptions = Options or {}
	assert(type(Extra) == "table", "Reserve takes an options table after the Id when you pass one")

	local Hold = Extra.Hold
	assert(Hold == nil or (type(Hold) == "number" and Hold > 0 and Hold < math.huge), `Reserve Hold must be a positive number of seconds when given, got {tostring(Hold)}`)

	local To: string? = nil
	if Extra.To ~= nil then
		To = self:Resolve(Extra.To, "Reserve To")
		assert(To ~= Resolved, `Reserve needs To to be a different key, both resolved to '{Resolved}'`)
	end

	local Op = Booking.Book(Rid :: string, Field, Amount, Hold, To)

	return Future.New(function(): (boolean, Reason?)
		return self:Written(Resolved, Op, `reserve {Amount} {Field}`)
	end)
end

function Store.Confirm(self: Store, Key: KeyLike, Id: string): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Confirm")
	local Rid = Arg.Name(Id, MAX_BOOKING_ID, "Confirm", false) :: string
	local Op = Booking.Take(Rid)

	return Future.New(function(): (boolean, Reason?)
		local Ok, Why = self:Written(Resolved, Op, `confirm booking '{Rid}'`, function(Record: Record): boolean
			local Booked = Booking.Entry((self:Fold(Record) :: any)._Booked, Rid)
			return Booked == nil or Booked.Handing ~= true
		end, HELD)

		if Why == HELD then
			warn(
				`Ledger: booking '{Rid}' on '{Resolved}' is being handed to another key, so its units are not here to spend. a grant that did not answer may already have delivered them, and only recovery can tell. leave it to the sweep`
			)
		end
		return Ok, Why
	end)
end

function Store.Release(self: Store, Key: KeyLike, Id: string): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Release")
	local Rid = Arg.Name(Id, MAX_BOOKING_ID, "Release", false) :: string
	local Op = Booking.Free(Rid)

	return Future.New(function(): (boolean, Reason?)
		local Ok, Why = self:Written(Resolved, Op, `release booking '{Rid}'`, function(Record: Record): boolean
			local Booked = Booking.Entry((self:Fold(Record) :: any)._Booked, Rid)
			return Booked == nil or Booked.Handing ~= true
		end, HELD)

		if Why == HELD then
			warn(
				`Ledger: booking '{Rid}' on '{Resolved}' is being handed to another key, so its units are not here to give back. a grant that did not answer may already have delivered them, and only recovery can tell. leave it to the sweep`
			)
		end
		return Ok, Why
	end)
end

function Store.Handed(self: Store, Key: string, Rid: string, Held: { [any]: any }): boolean
	local To = Held.To
	if type(To) ~= "string" then
		return false
	end

	local Records = self:Records()

	local Marked = Records:Append(Key, { Booking.Hand(Rid) })
	local Mine = Booking.Entry((self:Fold(Marked) :: any)._Booked, Rid)
	if Mine == nil or not Mine.Handing then
		return false
	end

	local Print = Booking.Terms(Key, Rid, Held)
	local Given = Booking.Give(Rid, Held.Field, Held.Amount, Print)
	local Landed = Records:Append(To, { Given }, function(Record: Record): boolean
		return Log.NotEntombed(Record) and self:Applies(Given, Record)
	end)

	local Ruling = Booking.Granted(self:Fold(Landed), Rid, Print)
	if Ruling == Entries.OTHER then
		error(
			Fault.New(
				SPENT,
				`'{To}' already took a booking named {Rid} from somewhere else, and a name has to mean the same thing every time. nothing was handed over, so release this one and pick a new name`
			)
		)
	end
	if Ruling ~= Entries.SAME then
		error(Fault.New(HELD, `'{To}' would not take booking {Rid}. the {Held.Amount} has already left '{Key}' and stays set aside until it is given back`))
	end

	local Cleared = Records:Append(Key, { Booking.Sent(Rid) })
	Fault.Holds(not Stamp.Carries(Cleared, `{Booking.FREE_ID}:{Rid}`), `booking {Rid} was handed to '{To}' but '{Key}' had already given the same units back, so they are on both keys`)

	self:Went(Key)
	self:Went(To)
	return true
end

function Store.Grant(self: Store, Key: KeyLike, Id: string): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Grant")
	local Rid = Arg.Name(Id, MAX_BOOKING_ID, "Grant", false) :: string

	return Future.New(function(): (boolean, Reason?)
		local Ok, Gave = pcall(function(): boolean
			local Held = Booking.Entry(self:Fold(self:ReadRecord(Resolved))._Booked, Rid)
			if Held == nil then
				return false
			end
			if Booking.Late(Held, Clock.Now()) then
				error(Fault.New(SPENT, `booking '{Rid}' on '{Resolved}' has run past its hold, so it cannot be handed over now. its units go back on their own, reserve them again`))
			end
			assert(type(Held.To) == "string", `booking '{Rid}' was not reserved with a To, so there is nowhere to hand it to`)
			return self:Handed(Resolved, Rid, Held)
		end)
		if not Ok then
			Registry.Sweep():Add(self, Resolved)
			return false, Failed(`hand over booking '{Rid}' on`, Resolved, Gave)
		end
		return Gave, if Gave then nil else REFUSED
	end)
end

function Store.TallyName(self: Store, Name: any, Field: any, What: string): string
	self:Live(What)
	assert(self.Keys == "String", `{What} is for string keyed stores, '{self.Options.Name}' uses player keys`)
	assert(
		type(Name) == "string" and #Name > 0 and #Name + #Tally.PART + 2 <= Core.MAX_KEY and utf8.len(Name) ~= nil,
		`{What} needs a Name short enough to carry a shard number, up to {Core.MAX_KEY - #Tally.PART - 2} characters`
	)
	Arg.Field(self.Initial, Field, What)
	return Name
end

function Store.Bump(self: Store, Name: string, Field: string, Amount: number): Future<boolean, Reason?>
	self:TallyName(Name, Field, "Bump")
	assert(
		type(Amount) == "number" and Amount > 0 and Amount < math.huge,
		`Bump needs a positive finite Amount. a tally is spread over keys that cannot see each other, so nothing can be taken back out of one`
	)

	local Key = Tally.Shard(Name, Tally.Mine())
	local Op = Tally.Bump(Field, Amount)

	return Future.New(function(): (boolean, Reason?)
		return self:Written(Key, Op, `add {Amount} to '{Name}'`)
	end)
end

function Store.Total(self: Store, Name: string, Field: string): Future<number?, Reason?>
	self:TallyName(Name, Field, "Total")

	local Base = (self.Initial :: any)[Field] or 0

	return Future.New(function(): (number?, Reason?)
		local Sum = 0
		for _, Key in Tally.Shards(Name) do
			local Ok, State = pcall(function(): any
				return self:Fold(self:ReadRecord(Key))
			end)
			if not Ok then
				return nil, Failed(`read a shard of '{Name}' for`, Key, State)
			end
			Sum += ((State :: any)[Field] or 0) - Base
		end
		return Sum, nil
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

	return IsStorable.Op(Probe)
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

function Store.Tx(self: Store, Id: string, Legs: { TxLeg }): Future<boolean, Reason?>
	self:Live("Tx")
	assert(
		type(Id) == "string" and #Id > 0 and #Id <= MAX_TX_ID and utf8.len(Id) ~= nil,
		`Tx needs an Id first, a stable name of 1 to {MAX_TX_ID} characters derived from the thing being settled, never from the clock`
	)
	assert(type(Legs) == "table", "Tx takes an array of legs after the Id")
	assert(#Legs >= 2 and #Legs <= Tx.MAX_LEGS, `Tx takes 2 to {Tx.MAX_LEGS} legs, got {#Legs}`)

	local Mapped: { Tx.Leg } = table.create(#Legs) :: { Tx.Leg }
	local Targets: { LegTarget } = table.create(#Legs) :: { LegTarget }
	local Touched: { [string]: boolean } = {}

	for Index, Leg in Legs do
		Mapped[Index], Targets[Index] = MapLeg(self, Index, Leg, Touched)

		local Storable, Unstorable = LegStorable(Leg)
		if not Storable then
			warn(`Ledger: Tx rejected leg {Index} '{Leg.Kind}', {Unstorable}`)
			return Rejected(INVALID)
		end
	end

	Fault.Holds(#Mapped == #Legs and #Targets == #Legs, "a transaction ended up with a different number of legs than it was given")

	return Future.New(function(): (boolean, Reason?)
		local Ok, Committed, Why, Parked = pcall(function(): (boolean, Reason?, boolean)
			return Tx.Drive(self.TxWrapper, Mapped, Id)
		end)

		local function Follow()
			for _, Target in Targets do
				Registry.Sweep():Add(Target.Store, Target.Key)
			end
		end

		if not Ok then
			warn(`Ledger: transaction '{Id}' broke inside Ledger and its legs might still be pending: {Committed}`)
			Follow()
			return false, UNRESOLVED
		end

		if Why == BUSY or Parked then
			Follow()
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
