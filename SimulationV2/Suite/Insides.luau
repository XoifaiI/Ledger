--!strict
--!optimize 2

--[=[
	Insides: The parts of Ledger that a case is allowed to reach into.

	Lib next door is what the sweep uses, and it stays narrow. A case is the other half of that: some
	of what Ledger promises is a promise about a record, a queue or a compaction, and there is no way
	to ask about those through the public surface. The rule moves here rather than going away.

	Return type: A table of the library parts the cases name.
	Example usage:
		local Records = Insides.Log.New(Store.Wrapper)
--]=]

local Ledger = require("../../src")
local Contract = require("../../src/Contract/Op")
local Fault = require("../../src/Contract/Fault")
local Horizons = require("../../src/Contract/Horizons")
local Limits = require("../../src/Contract/Limits")
local Reasons = require("../../src/Contract/Reason")
local Clock = require("../../src/Util/Clock")
local DataStoreWrapper = require("../../src/Util/DataStoreWrapper")
local Future = require("../../src/Util/Future")
local KeyedRetryQueue = require("../../src/Util/KeyedRetryQueue")
local NoYield = require("../../src/Util/NoYield")
local Observer = require("../../src/Util/Observer")
local RetryAsync = require("../../src/Util/RetryAsync")
local SetInterval = require("../../src/Util/SetInterval")
local TableUtil = require("../../src/Util/TableUtil")
local ThreadQueue = require("../../src/Util/ThreadQueue")
local Ident = require("../../src/Encode/Ident")
local Mark = require("../../src/Encode/Mark")
local Measure = require("../../src/Encode/Measure")
local IsStorable = require("../../src/Encode/Storable")
local Entries = require("../../src/Kernel/Entries")
local Layer = require("../../src/Kernel/Layer")
local Compact = require("../../src/Record/Compact")
local Fold = require("../../src/Record/Fold")
local Records = require("../../src/Record/Log")
local LogTypes = require("../../src/Record/Types")
local MakeOp = require("../../src/Record/MakeOp")
local Reconcile = require("../../src/Record/Reconcile")
local Shape = require("../../src/Record/Shape")
local Stamp = require("../../src/Record/Stamp")
local Booking = require("../../src/Feature/Booking")
local Escrow = require("../../src/Feature/Escrow")
local Names = require("../../src/Feature/Names")
local Tally = require("../../src/Feature/Tally")
local Recovery = require("../../src/Protocol/Recovery")
local Moves = require("../../src/Protocol/Transfer")
local Deals = require("../../src/Protocol/Tx")
local Registry = require("../../src/Store/Registry")
local Session = require("../../src/Live/Session")
local Mock = require("../../src/Mock")

export type Log = LogTypes.Log
export type Shape<S> = LogTypes.Shape<S>
export type Op = Contract.Op
export type Record<S> = Contract.Record<S>
export type Migration = Contract.Migration
export type Limits = RetryAsync.Limits
export type Wrapper = DataStoreWrapper.DataStoreWrapper
export type Future<T...> = Future.Future<T...>
export type Queue = ThreadQueue.ThreadQueue
export type Recalled = Entries.Recalled

local Log = table.freeze({
	New = Records.New,
	Shape = Shape.New,
	Verdict = Records.Verdict,
	Known = Records.Known,
	Entombed = Records.Entombed,
	NotEntombed = Records.NotEntombed,
	MAX_LOG_BYTES = Limits.Log,
	TOMB_HORIZON = Records.TOMB_HORIZON,

	Holds = Stamp.Holds,
	Carries = Stamp.Carries,
	Written = Stamp.Written,
	HasPending = Stamp.HasPending,
	NotPending = Stamp.NotPending,
	PendingTx = Stamp.PendingTx,
	Landed = Stamp.Landed,
	Unstamped = Stamp.Unstamped,

	Overgrown = Compact.Overgrown,
	Oversized = Compact.Oversized,
	Worthwhile = Compact.Worthwhile,
	Packed = Compact.Packed,
	Bulk = Compact.Bulk,
	SEEN_LIMIT = Compact.SEEN_LIMIT,
})

local function WrapEscrow(Inner: any, Balance: string?): any
	local Made = Escrow.Layered(Balance)
	return if Made == nil then Inner else Layer.Wrap(Inner, Made)
end

local function WrapBooking(Inner: any): any
	return Layer.Wrap(Inner, Booking.Layered(nil) :: any)
end

local function WrapTally(Inner: any): any
	return Layer.Wrap(Inner, Tally.Layered(nil) :: any)
end

local Transfer = table.freeze({
	Reserve = Moves.Reserve,
	Post = Moves.Post,
	Settle = Moves.Settle,
	Drive = Moves.Drive,
	Terms = Moves.Terms,
	Older = Moves.Older,
	LandedOn = Moves.LandedOn,
	Prune = Moves.Prune,

	Recover = Recovery.Transfers,
	Wrap = WrapEscrow,
})

local Tx = table.freeze({
	Drive = Deals.Drive,
	Settle = Deals.Settle,
	Reap = Deals.Reap,
	ShutdownHomes = Deals.ShutdownHomes,
	LEG_TIMEOUT = Deals.LEG_TIMEOUT,
	TIMEOUT = Deals.TIMEOUT,
	MAX_LEGS = Deals.MAX_LEGS,
	REAP_HORIZON = Deals.REAP_HORIZON,
	REAP_PAGE = Deals.REAP_PAGE,
	REAP_GRACE = Deals.REAP_GRACE,
	SHARDS = Deals.SHARDS,
	Roll = Deals.Roll,

	Wrap = Names.Wrap,
})

local function Counted(Booked: any): number
	if type(Booked) ~= "table" then
		return 0
	end

	local Total = 0
	for Rid in Booked do
		if Booking.Entry(Booked, Rid) ~= nil then
			Total += 1
		end
	end
	return Total
end

local Held = table.freeze({
	Layered = Booking.Layered,
	Book = Booking.Book,
	Take = Booking.Take,
	Sent = Booking.Sent,
	Free = Booking.Free,
	Hand = Booking.Hand,
	Undo = Booking.Undo,
	Give = Booking.Give,
	Terms = Booking.Terms,
	Entry = Booking.Entry,
	Late = Booking.Late,
	Overdue = Booking.Overdue,
	Owed = Booking.Owed,
	Granted = Booking.Granted,
	Delivered = Booking.Delivered,
	BOOK_HORIZON = Booking.BOOK_HORIZON,
	BOOK_MARGIN = Booking.BOOK_MARGIN,
	HOLD_CAP = Booking.HOLD_CAP,

	Counted = Counted,
	Wrap = WrapBooking,
})

local Store = table.freeze({
	Stores = Registry.Stores,
	Claimed = Registry.Claimed,
	Shutting = Registry.Shutting,
	Sweep = Registry.Sweep(),
})

return table.freeze({
	Ledger = Ledger :: any,

	Clock = Clock,
	DataStoreWrapper = DataStoreWrapper,
	Future = Future,
	KeyedRetryQueue = KeyedRetryQueue,
	NoYield = NoYield,
	Observer = Observer,
	RetryAsync = RetryAsync,
	SetInterval = SetInterval,
	TableUtil = TableUtil,
	ThreadQueue = ThreadQueue,

	Ident = Ident,
	Mark = Mark,
	Measure = Measure,
	IsStorable = IsStorable,

	Entries = Entries,
	Dedupe = Entries,
	Layer = Layer,

	Fold = Fold,
	Log = Log,
	MakeOp = MakeOp,
	Reconcile = Reconcile,
	Shape = Shape,
	Stamp = Stamp,
	Compact = Compact,

	Booking = Held,
	Escrow = Escrow,
	Names = Names,
	Tally = Tally,
	Recovery = Recovery,
	Transfer = Transfer,
	Tx = Tx,

	Registry = Store,
	Session = Session,
	Mock = Mock,
	Types = Contract,
	Horizons = Horizons,
	Limits = Limits,
	Reasons = Reasons,
	Fault = Fault,

	WrapEscrow = WrapEscrow,
	WrapBooking = WrapBooking,
	WrapTally = WrapTally,
})
