# Overview (https://xoifaii.github.io/docs)



Ledger is a DataStore library for Roblox. You describe how your data is allowed to change, and Ledger saves each change exactly once, even when a server crashes or two servers change the same player at the same moment.

```luau
local Ok, Why = PlayerStore:Edit(Player.UserId, { Kind = "AddGold", Amount = 50 })
if not Ok then
	warn("Couldn't add gold:", Why)
end
```

`true` means the change is saved. Anything else is a reason that says what happened, and [Answers](/docs/learn/answers) says what to do about each one.

## What it's for [#what-its-for]

| Job                   | What you get                                                          |
| --------------------- | --------------------------------------------------------------------- |
| Player data           | Loaded when they join, saved while they play and when they leave.     |
| Developer products    | A purchase is granted once, even when Roblox sends the receipt again. |
| Trades                | Both players change, or neither does, across servers and offline.     |
| Guild banks and shops | Data many servers change at once, without losing a change.            |
| Auctions and markets  | Gold held safely until the auction ends or the item sells.            |
| Limited items         | A fixed number sold across every server, never one too many.          |
| Global counters       | A number every server adds to, like total boss kills.                 |
| Updates               | Change the shape of your data without breaking old saves.             |
| Deleting data         | Erase a player's data when Roblox asks you to.                        |

## What it isn't for [#what-it-isnt-for]

* **Client scripts.** Ledger runs on the server. Calling it from a client throws.
* **Searching.** You can't search your data. `Store:Keys()` lists every key, a page at a time.
* **History.** You can't read an older version of a player's data.

## Where to start [#where-to-start]

The Learn pages build one game in order, starting with saving a player's gold. Each page adds one thing, and every sample is complete and type-checked. Start at the top and read them in order.

Next: [Getting started](/docs/learn/getting-started)


# Limits (https://xoifaii.github.io/docs/limits)



Check a number before you hit it.

```luau
-- Short names keep a key's list of used names small.
local Options: Ledger.TxOptions = { Id = "pay:" .. HttpService:GenerateGUID(false), IdAt = Ledger.Now() }
```

Only numbers that change what you do are here. A call that breaks a limit with a mistake throws before it sends anything. A call that meets a limit while running answers with a reason, such as `Full` or `Backlog`.

## Names and keys [#names-and-keys]

|                        | Limit                                                           |
| ---------------------- | --------------------------------------------------------------- |
| Store name             | 1 to 50 bytes. Not `Ledger$N`, which Ledger keeps for itself.   |
| String key             | 1 to 50 bytes of valid UTF-8. Cannot start with `$T:` or `$P:`. |
| Player key             | A UserId, a whole number.                                       |
| `Id` text              | At most 64 characters.                                          |
| Total or quantity name | 1 to 37 bytes.                                                  |
| `IdAt`                 | At most 1 day ahead of `Ledger.Now()`.                          |

## Size [#size]

|                            | Limit                                                                                  | What to do                                                                |
| -------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| One key's data             | About 4 MB (4,160,526 bytes). A warning shows past 2 MiB.                              | Past the cap, a write answers `Full`. Keep an active key well under 1 MB. |
| One key's writes           | About 4 MB of writes a minute.                                                         | A big key cannot be written often. Spread hot data over several keys.     |
| One op in a `Tx` or `Take` | 512 bytes of terms.                                                                    | Keep ops small.                                                           |
| Data                       | Plain tables only, up to 64 deep. No cycles, `NaN`, or arrays with gaps or mixed keys. |                                                                           |
| Numbers                    | Whole numbers below 2^53 unless you give an `Arithmetic`.                              |                                                                           |
| `Reset` with a `State`     | At most 1 MiB.                                                                         |                                                                           |

## How long Ledger remembers a name [#how-long-ledger-remembers-a-name]

A key remembers the names of recent ops, so a resend does nothing twice.

|                                                 | Limit                                                                                                             | What to do                                                                                    |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Timed names (`Id` and `IdAt`, or `Ledger.Id()`) | Remembered 180 s by default. A key holds about 275 GUID names.                                                    | Keep names short. `NoRoom` means the list is full: send again later.                          |
| Untimed names (`Id` alone)                      | A key holds about 90 GUID names. Remembered only for the time you set in `Windows`.                               | Prefer timed names.                                                                           |
| `Windows`                                       | How long a name is remembered. Timed: 136 s to 30 days. Untimed: 76 s to 30 days, and you must set it to use one. | Set `Untimed` for any op kind you name without `IdAt`.                                        |
| `CutWindow`                                     | How old a `Ledger.Id()` name can be. 360 s by default, 318 s to 30 days.                                          | Make the name just before an `Erase` or `Reset`. After this long, a server answers `Expired`. |

## Waiting [#waiting]

| Call                                                   | How long it can take                                                |
| ------------------------------------------------------ | ------------------------------------------------------------------- |
| `Ledger.Id()`                                          | `Busy` after 5 s with no server number.                             |
| A read (`Peek`, `Inspect`, `Losses`, `Resettle`)       | `Unresolved` after 30 s. `Pending` too, on a hung read.             |
| `Bump`                                                 | 0 to 60 s, up to 90 s if saves fail. Call it in `task.spawn`.       |
| `Erase`                                                | About 200 s at worst.                                               |
| `Peek` of a key where a crashed server left trade work | Up to about 30 minutes `Unresolved`. Call `Resettle` to end it now. |
| A session save                                         | Every 30 s. Idle sessions read every 120 s.                         |
| Shutdown                                               | 25 s. `BeforeClose` functions share the first 5 s.                  |

`SaveInterval`, `IdleReadInterval` and `HoldMax` can each be set from 1 s to 30 days.

## Queues [#queues]

|                                      | Limit                | Answer                      |
| ------------------------------------ | -------------------- | --------------------------- |
| A session's unsaved `Apply`s         | 4,096 ops or 1.5 MiB | `Backlog`. Call `Flush`.    |
| Unanswered writes on one key         | 4,096                | `Busy`. Send again later.   |
| Trade work not yet finished on a key | 16                   | `NoRoom`. Send again later. |

## Transactions and stock [#transactions-and-stock]

|                        | Limit                                                                             |
| ---------------------- | --------------------------------------------------------------------------------- |
| `Ledger.Tx` keys       | 2 or more, all different. Up to 29 with 16-character keys; fewer with long names. |
| `Take` `Legs`          | One fewer than the `Tx` limit.                                                    |
| Quantity `Parts`       | 1 to 64.                                                                          |
| `Proceeds` fields      | Up to 4.                                                                          |
| Holds                  | Up to 900 s each (`HoldMax`). 256 at once per part.                               |
| `Close` removing parts | After 62 minutes from the first `Open`.                                           |
| Totals `Shards`        | 1 to 64, 16 by default. Do not change a live total's `Shards`.                    |

## Reads and watching [#reads-and-watching]

|                              | Limit                                                                                 |
| ---------------------------- | ------------------------------------------------------------------------------------- |
| `Peek` `MaxAge`              | 0 to 30 days. An answer can be up to about 4.5 minutes behind on a key nobody writes. |
| `Follow`                     | Checks every 30 s, slowing to 240 s on a quiet key. Copies last 1 hour.               |
| `Store:Keys()` page          | 50 keys. Pages are in no set order.                                                   |
| `Cut.Losses`, `Store:Losses` | Kept 7 days.                                                                          |

## Requests per call [#requests-per-call]

How many Roblox DataStore requests a call makes, with no contention. `read` is a `GetAsync`, `write` an `UpdateAsync`.

| Call                                   | Requests                                                             |
| -------------------------------------- | -------------------------------------------------------------------- |
| `Edit`, `Commit`                       | 1 write. The first `Edit` of an erasable key also reads once.        |
| `Apply`                                | None. It rides the next save: 1 write per 30 s, however many ops.    |
| `Load`                                 | 1 read. An idle session then reads once per 120 s.                   |
| `Peek`, `Inspect`, `Losses`, `Pending` | 1 read.                                                              |
| `Peek(Key, MaxAge)`                    | None inside `MaxAge`.                                                |
| `Peek(Key, { Fresh = true })`          | 1 write.                                                             |
| `Ledger.Tx`, N keys                    | N writes before the answer, 2N-1 in all.                             |
| `Take`, `Hold`, `Confirm`              | 1 write, or with one key in `Legs` 2 before the answer and 3 in all. |
| `Reset`, `Erase`                       | 1 write. `Erase` also removes the key.                               |
| `Open`, `Close`                        | One write per part.                                                  |
| `Bump`                                 | One write per shard per server batch.                                |
| Server start                           | 1 write.                                                             |

Next: [Releases](/docs/releases)


# Releases (https://xoifaii.github.io/docs/releases)



`+` is new in v7, `~` exists in v6 and works differently now, `-` is gone, `!` is something to know before you upgrade.

## 7.0.0 [#700]

Ledger 7 is rebuilt from scratch. It's cheaper, holds more, and every edge case we could find is tested.

### Trades cost less than half [#trades-cost-less-than-half]

| A trade between two players  | v6      | v7           |
| ---------------------------- | ------- | ------------ |
| DataStore requests           | 8       | **2**        |
| MemoryStore requests         | 8       | **0**        |
| Players or keys in one trade | up to 4 | **up to 29** |

You can run about 4 times as many trades on the same DataStore budget, and they no longer use any MemoryStore.

### More room [#more-room]

* **4 MB per player instead of 2 MB.**
* **No more `Full` from busy shared keys.** In v6 a guild bank or shop key could fill up after about 1,900 trades a day. That limit is gone.
* **Busy keys stay usable.** In v6 a second trade on the same key got `Busy`. Now up to 16 can run on one key at once.

### Limited items and global counters [#limited-items-and-global-counters]

* **Quantities** sell a limited item from every server at once without overselling, with holds and checkout built in.
* **Totals** count things across the whole game, like total gold spent, and reading them is free most of the time.

### Clearer answers [#clearer-answers]

* Every call answers straight away with `(Ok, Result, Info)`. No more `:Wait()`.
* 15 answers, each with one meaning and one thing to do. See [Answers](/docs/learn/answers).
* When a save can't be confirmed yet, `Info.Outcome` tells you later whether it went through.
* `Reset` and `Erase` tell you exactly what they deleted.

### Harder to get wrong [#harder-to-get-wrong]

* With `--!strict`, your ops, reducer and calls are all type-checked.
* `Erase` and `Reset` can't wipe a player by mistake when a request is retried.
* Players' data saves on shutdown by itself. No `BindToClose` needed.

### Every change [#every-change]

```diff
+ Ledger.Now() and Ledger.BeforeClose()
+ Mock: run a server on the Mock package's in-memory DataStore and MemoryStore
+ Balances: number fields like gold that Ledger changes for you, with limits, and that never hold up a trade
+ Store:Keys(), Store:Losses(), Store:Pending(), Session:Refresh()
+ Quantities: Take, Hold, Confirm, Close, Deposit, Gather, Withdraw
+ Cut.Losses lists what Reset and Erase destroyed
+ Info.Outcome tells you what became of an Unresolved write
+ Six answers: Unreadable, Expired, NoRoom, Missing, Short, SoldOut
+ Peek(Key, { Fresh = true }) reads the newest saved data
~ Every call answers (Ok, Result, Info), with no Future and no Wait. A read never means empty
~ 15 answers instead of 10, all checked by Ledger.Reason
~ Peek of a key that was never saved answers nil, Missing. It no longer gives the Default
~ Ops are named with Id and IdAt in the options (Edit, Commit, Ledger.Tx)
~ Ledger.Id() answers nil, Busy when it cannot make a name yet. Erase and Reset take one
~ Reset and Erase answer a Cut
~ Ledger.Tx, Bump, Total, Follow, Stale and Peek with MaxAge keep their names, with new answers
~ Ledger.New<<Data, Ops>> type-checks every op you send against your Ops type
- Held, and calls that return a Future
- Transfer, Reserve and Once. Use Ledger.Tx, quantities and named ops
- EditOp, CommitOp, Session:Compact, Ledger.Sweep, History, PeekVersion
- TypeScript typings

! Data written by v6 may read Unreadable or Behind. Use new store names for v7
! Erase and Reset take only a Ledger.Id() name, or none. A string Id throws
! A server answers Expired for its own Ledger.Id() name once it is 6 minutes old. Make the name just before you use it
! For a quantity's counts use Store:Quantity(Name):Total(). Store:Total is for totals
! A Final quantity must declare Stock
```

### Upgrading [#upgrading]

Plan for a rewrite of the calls, not a version bump. Start with [Getting started](/docs/learn/getting-started), then [Answers](/docs/learn/answers) and [Common mistakes](/docs/learn/common-mistakes).

v7 does not read v5 or v6 data. Open v7 stores under new names, and copy each player's old data in on their first join, as in [Changing your data](/docs/learn/changing-data#data-from-before-ledger).


# Auctions and markets (https://xoifaii.github.io/docs/guides/auctions-and-markets)



This guide builds two things on top of the Learn pages: an auction that holds the top bid's gold until it ends, and a market where players sell items at a fixed price. Both move gold and items between several players at once, so both use [trades](/docs/learn/trading), and both use [balances](/docs/learn/your-data#balances-let-ledger-handle-gold) for gold.

The full code is three ModuleScripts in `ServerStorage`: `Stores`, `Auction` and `Market`.

## The player store [#the-player-store]

Gold is a balance. `Receive` is the op other players' gold arrives with:

```luau
local PlayerStore = Ledger.New<<PlayerData, PlayerOps>>({
	Name = "PlayerData",
	Keys = "Player",
	Default = { Gold = 0, Items = {} },
	MustExist = false,
	Erasable = true,
	Balances = {
		Gold = { Credit = { "AddGold", "Receive" }, Debit = "SpendGold" },
	},
	-- ... the reducer handles GiveItem, GetItem and Purchase
})
```

`GiveItem` takes an item from the player (refused if they don't have it), `GetItem` gives one, and `Purchase` takes the price and gives the item together, for the market.

## The auction store [#the-auction-store]

Each auction is one key, named by an id. Its reducer refuses any bid that isn't allowed:

```luau
local AuctionStore = Ledger.New<<AuctionData, AuctionOps>>({
	Name = "Auctions",
	Keys = "String",
	Default = { Seller = 0, Item = "", EndsAt = 0, TopBidder = 0, TopBid = 0, IsDone = false },
	MustExist = false,
	Erasable = false,
	Reducer = function(Data, Op)
		if Op.Kind == "Create" then
			if Data.Seller ~= 0 then
				return nil -- this id is taken
			end

			return {
				Seller = Op.Seller,
				Item = Op.Item,
				EndsAt = Op.EndsAt,
				TopBidder = 0,
				TopBid = Op.MinBid,
				IsDone = false,
			}
		end

		if Op.Kind == "Bid" then
			if Data.Seller == 0 or Data.IsDone or Op.At >= Data.EndsAt then
				return nil -- no such auction, or it's over
			end

			if Op.Bidder == Data.Seller or Op.Amount <= Data.TopBid then
				return nil -- the seller can't bid, and a bid must beat the top one
			end

			if Op.PrevBidder ~= Data.TopBidder or Op.PrevBid ~= Data.TopBid then
				return nil -- someone else bid since this bidder looked
			end

			local New = table.clone(Data)
			New.TopBidder = Op.Bidder
			New.TopBid = Op.Amount
			return New
		end

		if Op.Kind == "Finish" then
			if Data.Seller == 0 or Data.IsDone or Op.At < Data.EndsAt then
				return nil -- no such auction, already finished, or not over yet
			end

			local New = table.clone(Data)
			New.IsDone = true
			return New
		end

		return nil
	end,
})
```

A `Bid` op carries the top bid the bidder saw (`PrevBidder` and `PrevBid`). If someone else bid in the meantime, they don't match, and the bid is refused. The bidder can look again and decide.

`At` is the time the bid was sent. It's in the op, not read in the reducer, because a reducer must give the same answer every time.

## Where the gold waits [#where-the-gold-waits]

While an auction runs, the top bid's gold sits in an escrow store. It only holds a balance, so it needs no reducer:

```luau
local EscrowStore = Ledger.New<<EscrowData, EscrowOps>>({
	Name = "AuctionEscrow",
	Keys = "String",
	Default = { Held = 0 },
	MustExist = false,
	Erasable = false,
	Balances = {
		Held = { Credit = "EscrowIn", Debit = "EscrowOut" },
	},
})
```

## Placing a bid [#placing-a-bid]

```luau
local function Bid(Bidder: Player, Id: string, Amount: number): (boolean, string?)
	local Auction = AuctionStore:Peek(Id)
	if not Auction then
		return false, "Missing"
	end

	if Auction.TopBidder == Bidder.UserId then
		return false, "AlreadyTop"
	end

	if Amount <= Auction.TopBid then
		return false, "TooLow"
	end

	local Legs = {
		PlayerStore:Leg(Bidder.UserId, { Kind = "SpendGold", Amount = Amount }),
		AuctionStore:Leg(Id, {
			Kind = "Bid",
			Bidder = Bidder.UserId,
			Amount = Amount,
			PrevBidder = Auction.TopBidder,
			PrevBid = Auction.TopBid,
			At = os.time(),
		}),
	}

	if Auction.TopBidder ~= 0 then
		-- Give the outbid player their gold back, from the escrow.
		table.insert(Legs, PlayerStore:Leg(Auction.TopBidder, { Kind = "Receive", Amount = Auction.TopBid }))
		table.insert(Legs, EscrowStore:Leg(Id, { Kind = "EscrowIn", Amount = Amount - Auction.TopBid }))
	else
		table.insert(Legs, EscrowStore:Leg(Id, { Kind = "EscrowIn", Amount = Amount }))
	end

	Flush(Bidder)
	local Ok, Why, Info = Ledger.Tx(Legs)
	if Why == "Unresolved" and Info and Info.Outcome then
		Ok, Why = Info.Outcome:Wait()
	end
	Refresh(Bidder)

	return Ok, Why
end
```

One trade does it all: the bidder pays, the auction records the bid, and the gold goes into escrow. If someone was outbid, the same trade gives them their gold back. Either all of it happens or none of it does.

The checks at the top matter:

* **`AlreadyTop`**: the top bidder raising their own bid would put two parts of the trade on the same player, and a trade can't do that. It throws.
* **`TooLow`**: a bid at or below the top bid would put a negative amount into escrow, which also throws. The reducer would refuse it anyway, but the trade has to make sense first.

| Answer                 | What it means                                                                       |
| ---------------------- | ----------------------------------------------------------------------------------- |
| `true`                 | They're the top bidder.                                                             |
| `Refused`              | Not enough gold, someone bid first, or the auction is over. Show the auction again. |
| `TooLow`, `AlreadyTop` | Caught before sending.                                                              |

## Finishing an auction [#finishing-an-auction]

```luau
local function Finish(Id: string): (boolean, string?)
	local Auction = AuctionStore:Peek(Id)
	if not Auction then
		return false, "Missing"
	end

	if Auction.IsDone then
		return true, nil
	end

	local Legs = {
		AuctionStore:Leg(Id, { Kind = "Finish", At = os.time() }),
	}

	if Auction.TopBidder ~= 0 then
		table.insert(Legs, EscrowStore:Leg(Id, { Kind = "EscrowOut", Amount = Auction.TopBid }))
		table.insert(Legs, PlayerStore:Leg(Auction.Seller, { Kind = "Receive", Amount = Auction.TopBid }))
		table.insert(Legs, PlayerStore:Leg(Auction.TopBidder, { Kind = "GetItem", Item = Auction.Item }))
	else
		-- Nobody bid: the seller gets the item back.
		table.insert(Legs, PlayerStore:Leg(Auction.Seller, { Kind = "GetItem", Item = Auction.Item }))
	end

	local Ok, Why = Ledger.Tx(Legs)
	if Ok then
		return true, nil
	end

	-- Another server may have finished it first. Check.
	local After = AuctionStore:Peek(Id)
	if After and After.IsDone then
		return true, nil
	end

	return false, Why
end
```

The winner gets the item, the seller gets the gold from escrow, and the auction is marked done, all in one trade. If nobody bid, the seller gets their item back.

Any server can call `Finish`, for example every server checking its list of auctions once a minute. The first one to finish it wins. The rest are refused, because the auction is already done, so `Finish` reads the auction again and reports success.

## A fixed-price market [#a-fixed-price-market]

A listing is a key too:

```luau
local ListingStore = Ledger.New<<ListingData, ListingOps>>({
	Name = "Listings",
	Keys = "String",
	Default = { Seller = 0, Item = "", Price = 0, IsSold = false },
	MustExist = false,
	Erasable = false,
	Reducer = function(Data, Op)
		if Op.Kind == "List" then
			if Data.Seller ~= 0 then
				return nil -- this id is taken
			end
```

Listing an item is a trade of the seller's `GiveItem` and the listing's `List`, like creating an auction. Buying is one trade of three parts:

```luau
local function Buy(Buyer: Player, Id: string): (boolean, string?)
	local Listing = ListingStore:Peek(Id)
	if not Listing then
		return false, "Missing"
	end

	if Listing.Seller == Buyer.UserId then
		return false, "OwnListing"
	end

	Flush(Buyer)
	local Ok, Why, Info = Ledger.Tx({
		PlayerStore:Leg(Buyer.UserId, { Kind = "Purchase", Item = Listing.Item, Price = Listing.Price }),
		ListingStore:Leg(Id, { Kind = "Sell", Buyer = Buyer.UserId }),
		PlayerStore:Leg(Listing.Seller, { Kind = "Receive", Amount = Listing.Price }),
	})
	if Why == "Unresolved" and Info and Info.Outcome then
		Ok, Why = Info.Outcome:Wait()
	end
	Refresh(Buyer)

	return Ok, Why
end
```

The buyer pays and gets the item, the listing is marked sold, and the seller is paid. If two players buy at once, one gets it and the other is refused.

## Rules for every trade here [#rules-for-every-trade-here]

* **Never two parts on the same key of one store.** That's why the seller can't bid or buy their own listing: check it before you send.
* **Flush before, Refresh after**, for any player loaded on this server, as in [Trading](/docs/learn/trading). Players in other servers see the change at their next save, or sooner with the message from [Shared data](/docs/learn/shared-data#gifts-to-players-in-other-servers).
* **Every server needs every store.** Keep them all in `Stores`, so any server can finish any trade.
* **Keep auction and listing keys apart.** One key per auction and per listing spreads the writes out. A single key holding every listing would run out of writes in a busy game.

Next: [Support tools](/docs/guides/support-tools)


# Support tools (https://xoifaii.github.io/docs/guides/support-tools)



When a player messages you that something's wrong with their data, these calls help you see what happened and fix it. They're for you and your support team, from an admin command or a script, not for gameplay.

The code on this page is one ModuleScript, `SupportTools`, in `ServerStorage`.

## Looking at a player's data [#looking-at-a-players-data]

```luau
-- Prints what's saved for a player, and anything unfinished on their data.
local function Lookup(UserId: number)
	local Record, Why = PlayerStore:Inspect(UserId)
	if not Record then
		print("Nothing to show:", Why)
		return
	end

	print("Gold:", Record.State.Gold)

	local Items = PlayerStore:Pending(UserId)
	if not Items then
		return
	end

	for _, Item in Items do
		print("Unfinished:", Item.Kind, `{Item.Age} seconds old`)
	end
end
```

`Inspect` gives you the player's saved data, like `Peek`, and answers the same way when it can't: `Missing`, `Unresolved` and so on.

`Pending` lists anything unfinished on their data, usually a [trade](/docs/learn/trading) still in progress. Each item has a `Kind` and an `Age` in seconds:

| Item                                       | What it means                                                                    |
| ------------------------------------------ | -------------------------------------------------------------------------------- |
| `Escrow` or `Exclusive`, a few seconds old | A trade is happening right now. Wait.                                            |
| `Escrow` or `Exclusive`, older             | The server that started the trade probably crashed. See below.                   |
| `Pinned`                                   | A finished trade's record. Normal for up to about 30 minutes, and clears itself. |

## Finishing stuck trades [#finishing-stuck-trades]

Ledger finishes a trade whose server crashed on its own, the next time the player's data is touched, within about 30 minutes. To do it now:

```luau
-- Finishes anything left unfinished on a player's data.
local function Unstick(UserId: number): boolean
	local Ok, Why = PlayerStore:Resettle(UserId)
	if not Ok then
		warn("Couldn't finish everything yet:", Why)
	end

	return Ok
end
```

`true` means nothing unfinished is left. `Unresolved` means something couldn't be finished yet, so try again later.

## What a reset or erase wiped [#what-a-reset-or-erase-wiped]

`Reset` and `Erase` keep a note of the [balances](/docs/learn/your-data#balances-let-ledger-handle-gold) they wiped, for 7 days:

```luau
-- Prints the gold a Reset or Erase wiped from a player in the last 7 days.
local function ShowLosses(UserId: number)
	local Losses = PlayerStore:Losses(UserId)
	if not Losses then
		return
	end

	for _, Event in Losses.Events do
		for _, Lost in Event.Fields do
			print(Event.Cause, "wiped", Lost.Field)
		end
	end
end
```

## Fixing a player's data [#fixing-a-players-data]

Make the fix an op like any other, and give each support ticket an id. The reducer remembers the last 100 tickets and refuses one it has seen, so a fix can't apply twice, even if you send it twice by accident:

```luau
-- in the reducer:
if Op.Kind == "FixGold" then
	if table.find(Data.Tickets, Op.Ticket) then
		return nil -- this ticket was already applied
	end

	local New = table.clone(Data)
	New.Gold = Op.Gold
	New.Tickets = table.clone(Data.Tickets)
	table.insert(New.Tickets, Op.Ticket)
	if #New.Tickets > TICKETS_KEPT then
		table.remove(New.Tickets, 1)
	end
	return New
end
```

```luau
-- Sets a player's gold for a support ticket. A ticket only ever applies once.
local function FixGold(UserId: number, Ticket: string, Gold: number): (boolean, string?)
	local Ok, Why = PlayerStore:Edit(UserId, { Kind = "FixGold", Ticket = Ticket, Gold = Gold })
	return Ok, Why
end
```

`Refused` means this ticket was already applied. Check the player's data with `Inspect` before and after.

## Going through every player [#going-through-every-player]

```luau
-- Goes through every player in the store and gives the ones with more gold than Limit.
local function FindRich(Limit: number): { number }
	local Found: { number } = {}
	local Pages = PlayerStore:Keys()

	while true do
		local Page = Pages:Next()
		if not Page then
			return Found
		end

		for _, Key in Page do
			local UserId = tonumber(Key)
			if not UserId then
				continue
			end

			local Data = PlayerStore:Peek(UserId)
			if Data and Data.Gold > Limit then
				table.insert(Found, UserId)
			end

			task.wait(SECONDS_BETWEEN_READS)
		end
	end
end
```

`Keys` lists every key in the store, a page at a time. `Next` gives a page, then `nil` after the last one. Keys come in no set order, and one made while you're going through might be missed.

This reads every player's data once. Each server only gets about 60 DataStore reads a minute, plus 10 per player in it, and your game needs those too. One read a second leaves plenty to spare, but it takes a while on a big game: about a day per 80,000 players. Run it on one server, not every server.

Next: [Ledger reference](/docs/reference/ledger)


# Answers (https://xoifaii.github.io/docs/learn/answers)



Every call that changes data gives back the same three things:

```luau
local Ok, Result, Info = Session:Commit(Op)
```

* **`Ok`** is `true` if the change went through, and `false` if it didn't.
* **`Result`**: when `Ok` is `false`, this is the reason, a short string like `"Refused"`. When `Ok` is `true`, it's something useful for that call, like the new data for `Commit`.
* **`Info`** has extra details when `Ok` is `false`. You'll mostly use it for `"Unresolved"`, below.

There are 15 reasons, and each one means the same thing on every call. Compare with `Ledger.Reason`, so a typo shows up in Studio instead of silently never matching:

```luau
if Result == Ledger.Reason.Refused then
```

## A full example [#a-full-example]

Here's the rare shop from [Players](/docs/learn/players), now handling its answers:

```luau
local function OnBuyRare(Player: Player)
	local Session = PlayerStore:Get(Player)
	if not Session then
		return -- still loading
	end

	local Ok, Result, Info = Session:Commit({ Kind = "BuyItem", Item = RARE_ITEM, Price = RARE_PRICE })
	if Ok then
		print(Player.Name, "bought the dragon")
		return
	end

	if Result == Ledger.Reason.Refused then
		print(Player.Name, "can't afford the dragon")
		return
	end

	if Result == Ledger.Reason.Unresolved and Info and Info.Outcome then
		print(Player.Name, "'s purchase is still saving")

		local Saved, Why = Info.Outcome:Wait()
		if not Saved then
			print(Player.Name, "'s purchase didn't go through:", Why)
			return
		end

		print(Player.Name, "bought the dragon")
		return
	end

	warn(Player.Name, "couldn't buy the dragon:", Result)
end
```

Most of your code only needs to handle a few reasons. Anything else is rare, so a `warn` is enough.

## The ones you'll see [#the-ones-youll-see]

| Reason       | What it means                                                                                                     | What to do                                                                            |
| ------------ | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `Refused`    | Your reducer returned `nil`. Nothing changed.                                                                     | Tell the player why, like "not enough gold".                                          |
| `Unresolved` | The save didn't answer in time, usually because DataStores are having trouble. The change might still go through. | Nothing. Ledger keeps sending it. Use `Info.Outcome` if you want to know how it ends. |
| `Busy`       | Ledger couldn't send it right now. Nothing was sent.                                                              | Let the player try again in a moment.                                                 |
| `Closed`     | The server is shutting down. Nothing was sent.                                                                    | Nothing.                                                                              |
| `Missing`    | The data doesn't exist, on a store with `MustExist = true`.                                                       | Create it first, or check the key.                                                    |
| `Backlog`    | `Apply` only: this player has thousands of changes waiting to save. Nothing was added.                            | Call `Session:Flush()`, then apply again.                                             |

## `Unresolved` [#unresolved]

`Unresolved` doesn't mean it failed. It means Ledger doesn't know yet, and it keeps sending the change until it finds out. **Don't send it again yourself**, or the player could get it twice.

If you want to know how it ended, wait on `Info.Outcome`:

```luau
	if Result == Ledger.Reason.Unresolved and Info and Info.Outcome then
		print(Player.Name, "'s purchase is still saving")

		local Saved, Why = Info.Outcome:Wait()
		if not Saved then
			print(Player.Name, "'s purchase didn't go through:", Why)
			return
		end

		print(Player.Name, "bought the dragon")
		return
	end
```

`Outcome:Wait()` gives back `true` once it's saved, or `false` and a reason if it didn't go through. It yields, so it's fine inside a remote handler like this one, but don't call it anywhere that has to answer straight away.

`Apply` never answers `Unresolved`: it only queues the change, and the next save takes care of it.

In a long DataStore outage, a few minutes or more, an `Unresolved` change can be lost. For things that must never be lost, like Robux purchases, keep a record in the player's data. [Once only](/docs/learn/once-only) shows how, and [Purchases](/docs/learn/purchases) does it for Robux.

## Telling the player why [#telling-the-player-why]

`Refused` doesn't say which rule failed. If you want to show a message, check the same thing in your script before you send the change, like [Bigger reducers](/docs/learn/bigger-reducers#telling-the-player-why) does.

## The rest [#the-rest]

You won't see these unless you use the feature they belong to:

| Reason                       | What it means                                                                                                                          |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `Full`                       | The data would go over about 4 MB. Nothing changed.                                                                                    |
| `Invalid`                    | The change can't be saved, like a table with a function in it. Fix your code.                                                          |
| `Behind`                     | A newer version of your game changed this data's shape, and this server is older. See [Changing your data](/docs/learn/changing-data). |
| `Unreadable`                 | This server can't read the saved data. Ledger warns with the key. See [Changing your data](/docs/learn/changing-data).                 |
| `Spent`, `Expired`, `NoRoom` | About named changes. See [Once only](/docs/learn/once-only).                                                                           |
| `Short`, `SoldOut`           | About limited items. See [Limited items](/docs/learn/limited-items).                                                                   |

Next: [Once only](/docs/learn/once-only)


# Bigger reducers (https://xoifaii.github.io/docs/learn/bigger-reducers)



The reducer on the last page had three ops. A real game has dozens, and data a few tables deep. This page shows how to keep that tidy, without a wall of `table.clone`s.

We'll build a small pet system: hatch a pet, feed it to level it up, equip it, and sell it.

## The data and ops [#the-data-and-ops]

```luau
export type Pet = {
	Species: string,
	Level: number,
	Xp: number,
	Equipped: boolean,
}

export type PlayerData = {
	Coins: number,
	Pets: { [string]: Pet },
	PetCount: number,
	EquippedCount: number,
}

export type PlayerOps = {
	Hatch: { PetId: string, Species: string },
	Feed: { PetId: string, Xp: number },
	Equip: { PetId: string },
	Sell: { PetId: string },
}

type Op<Kind> = Ledger.OpOf<PlayerOps, Kind>
```

`Op<"Feed">` is the type of one kind of op: here `{ Kind: "Feed", PetId: string, Xp: number }`. `Ledger.OpOf` builds it from your `PlayerOps` so you never write it twice.

## One function per op [#one-function-per-op]

Give each op its own function, then list them in a table by kind:

```luau
-- Every op function, by kind.
local HANDLERS: { [string]: (Data: PlayerData, Op: any) -> PlayerData? } = {
	Hatch = Hatch,
	Feed = Feed,
	Equip = Equip,
	Sell = Sell,
}
```

The reducer looks up the op's kind and hands it to the right function:

```luau
	Reducer = function(Data, Op)
		local Handler = HANDLERS[Op.Kind]
		if not Handler then
			return nil -- a kind this server doesn't know
		end

		return Handler(Data, Op)
	end,
```

To add an op, put it in `PlayerOps` as before, write its function, and add one line to `HANDLERS`. The reducer never changes.

Each function is typed with `Op<...>`, so it only accepts its own kind of op. Misspell a field, like `Op.XP` instead of `Op.Xp`, and Studio underlines it right away. If you write a function and forget to add it to `HANDLERS`, Studio warns you that it's never used.

## Copy only what you change [#copy-only-what-you-change]

`table.clone` copies one level. You only need to copy the tables on the way to what you're changing. Everything else stays shared with the old data, and that's fine.

Changing a pet means three copies: the pet, the `Pets` table, and the data at the top. A small helper takes care of the middle one:

```luau
-- Copies a table, then sets one entry in the copy. Pass nil to remove it.
local function SetEntry<Value>(Map: { [string]: Value }, Key: string, NewValue: Value?): { [string]: Value }
	local Copy = table.clone(Map)
	Copy[Key] = NewValue
	return Copy
end
```

With it, feeding a pet reads top to bottom:

```luau
local function Feed(Data: PlayerData, Op: Op<"Feed">): PlayerData?
	local Pet = Data.Pets[Op.PetId]
	if not Pet then
		return nil
	end

	local TotalXp = Pet.Xp + Op.Xp

	local NewPet = table.clone(Pet)
	NewPet.Level += TotalXp // XP_PER_LEVEL
	NewPet.Xp = TotalXp % XP_PER_LEVEL

	local New = table.clone(Data)
	New.Pets = SetEntry(Data.Pets, Op.PetId, NewPet)
	return New
end
```

Adding a pet and removing one use the same helper. `Sell` passes `nil` to remove the pet:

```luau
local function Sell(Data: PlayerData, Op: Op<"Sell">): PlayerData?
	local Pet = Data.Pets[Op.PetId]
	if not Pet then
		return nil
	end

	if Pet.Equipped then
		return nil -- unequip it first
	end

	local New = table.clone(Data)
	New.Coins += Pet.Level * SELL_PRICE_PER_LEVEL
	New.PetCount -= 1
	New.Pets = SetEntry(Data.Pets, Op.PetId, nil)
	return New
end
```

If you keep a list instead of a table of ids, remove items with `table.remove` on the copy. Setting an index to `nil` leaves a hole, and a list with a hole can't be saved.

## Keep counts in your data [#keep-counts-in-your-data]

The reducer runs a lot, so keep it quick. Instead of counting `Pets` every time a pet hatches, keep `PetCount` in the data and change it with every hatch and sell:

```luau
local function Hatch(Data: PlayerData, Op: Op<"Hatch">): PlayerData?
	if Data.Coins < HATCH_COST then
		return nil
	end

	if Data.PetCount >= MAX_PETS then
		return nil
	end

	if Data.Pets[Op.PetId] then
		return nil -- this id is already used
	end

	local NewPet: Pet = { Species = Op.Species, Level = 1, Xp = 0, Equipped = false }

	local New = table.clone(Data)
	New.Coins -= HATCH_COST
	New.PetCount += 1
	New.Pets = SetEntry(Data.Pets, Op.PetId, NewPet)
	return New
end
```

Hatching the 200th pet now costs the same as the first.

## Telling the player why [#telling-the-player-why]

When the reducer returns `nil`, the call just gets back `false`. It doesn't say which check failed. If you want to tell the player, check before you send the op:

```luau
local function OnHatch(Player: Player)
	local Session = PlayerStore:Get(Player)
	if not Session then
		return -- still loading
	end

	local Data = Session:Get()
	if Data.Coins < Stores.HATCH_COST then
		print(Player.Name, "needs", Stores.HATCH_COST, "coins to hatch")
		return
	end

	if Data.PetCount >= Stores.MAX_PETS then
		print(Player.Name, "has no room for another pet")
		return
	end

	local Species = SPECIES[math.random(#SPECIES)]
	local PetId = HttpService:GenerateGUID(false)

	Session:Apply({ Kind = "Hatch", PetId = PetId, Species = Species })
end
```

The reducer still checks the same things. The check in your script is for the message, and the check in the reducer is the rule.

The species is rolled and the pet id made here, in the script, because a reducer can't use `math.random`. The op carries what was rolled.

## The whole store [#the-whole-store]

```luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ledger = require(ReplicatedStorage.Ledger)

export type Pet = {
	Species: string,
	Level: number,
	Xp: number,
	Equipped: boolean,
}

export type PlayerData = {
	Coins: number,
	Pets: { [string]: Pet },
	PetCount: number,
	EquippedCount: number,
}

export type PlayerOps = {
	Hatch: { PetId: string, Species: string },
	Feed: { PetId: string, Xp: number },
	Equip: { PetId: string },
	Sell: { PetId: string },
}

type Op<Kind> = Ledger.OpOf<PlayerOps, Kind>

local HATCH_COST = 250
local MAX_PETS = 200
local MAX_EQUIPPED = 3
local XP_PER_LEVEL = 100
local SELL_PRICE_PER_LEVEL = 50

-- Copies a table, then sets one entry in the copy. Pass nil to remove it.
local function SetEntry<Value>(Map: { [string]: Value }, Key: string, NewValue: Value?): { [string]: Value }
	local Copy = table.clone(Map)
	Copy[Key] = NewValue
	return Copy
end

local function Hatch(Data: PlayerData, Op: Op<"Hatch">): PlayerData?
	if Data.Coins < HATCH_COST then
		return nil
	end

	if Data.PetCount >= MAX_PETS then
		return nil
	end

	if Data.Pets[Op.PetId] then
		return nil -- this id is already used
	end

	local NewPet: Pet = { Species = Op.Species, Level = 1, Xp = 0, Equipped = false }

	local New = table.clone(Data)
	New.Coins -= HATCH_COST
	New.PetCount += 1
	New.Pets = SetEntry(Data.Pets, Op.PetId, NewPet)
	return New
end

local function Feed(Data: PlayerData, Op: Op<"Feed">): PlayerData?
	local Pet = Data.Pets[Op.PetId]
	if not Pet then
		return nil
	end

	local TotalXp = Pet.Xp + Op.Xp

	local NewPet = table.clone(Pet)
	NewPet.Level += TotalXp // XP_PER_LEVEL
	NewPet.Xp = TotalXp % XP_PER_LEVEL

	local New = table.clone(Data)
	New.Pets = SetEntry(Data.Pets, Op.PetId, NewPet)
	return New
end

local function Equip(Data: PlayerData, Op: Op<"Equip">): PlayerData?
	local Pet = Data.Pets[Op.PetId]
	if not Pet then
		return nil
	end

	if Pet.Equipped then
		return nil
	end

	if Data.EquippedCount >= MAX_EQUIPPED then
		return nil
	end

	local NewPet = table.clone(Pet)
	NewPet.Equipped = true

	local New = table.clone(Data)
	New.EquippedCount += 1
	New.Pets = SetEntry(Data.Pets, Op.PetId, NewPet)
	return New
end

local function Sell(Data: PlayerData, Op: Op<"Sell">): PlayerData?
	local Pet = Data.Pets[Op.PetId]
	if not Pet then
		return nil
	end

	if Pet.Equipped then
		return nil -- unequip it first
	end

	local New = table.clone(Data)
	New.Coins += Pet.Level * SELL_PRICE_PER_LEVEL
	New.PetCount -= 1
	New.Pets = SetEntry(Data.Pets, Op.PetId, nil)
	return New
end

-- Every op function, by kind.
local HANDLERS: { [string]: (Data: PlayerData, Op: any) -> PlayerData? } = {
	Hatch = Hatch,
	Feed = Feed,
	Equip = Equip,
	Sell = Sell,
}

local PlayerStore = Ledger.New<<PlayerData, PlayerOps>>({
	Name = "PlayerData",
	Keys = "Player",
	Default = { Coins = 0, Pets = {}, PetCount = 0, EquippedCount = 0 },
	MustExist = false,
	Erasable = true,
	Reducer = function(Data, Op)
		local Handler = HANDLERS[Op.Kind]
		if not Handler then
			return nil -- a kind this server doesn't know
		end

		return Handler(Data, Op)
	end,
})

return {
	PlayerStore = PlayerStore,
	HATCH_COST = HATCH_COST,
	MAX_PETS = MAX_PETS,
}
```

Next: [Players](/docs/learn/players)


# Changing your data (https://xoifaii.github.io/docs/learn/changing-data)



Once your game is live, players have saved data in the shape you shipped. When you add a field, rename one, or restructure a table in an update, their saved data needs to change to match. That's what this page is about.

## Why you need a migration [#why-you-need-a-migration]

Changing `Default` only changes what new players start with. A player who saved yesterday still has yesterday's data, without your new field. Your reducer would then find `nil` where it expects a table.

A migration fixes that. It's a function that takes a player's old saved data and returns it in the new shape. Ledger runs it the first time that player's data is read after your update.

## Adding a field [#adding-a-field]

Say version 1 shipped with `Gold`, and version 2 adds `Pets`. Update the type and `Default` as usual, and add a `Migrations` list to the store:

```luau
type Saved = { [string]: any }

local PlayerStore = Ledger.New<<PlayerData, PlayerOps>>({
	Name = "PlayerData",
	Keys = "Player",
	Default = { Gold = 0, Pets = {} },
	MustExist = false,
	Erasable = true,
	Migrations = {
		-- 1: version 2 added Pets.
		{
			Fields = { "Pets" },
			Run = function(Stored: unknown): unknown
				local New = table.clone(Stored :: Saved)
				New.Pets = {}
				return New
			end,
		},
	},
	Reducer = ...,
})
```

`Fields` lists the new top-level fields this migration adds. Listing them tells Ledger the change is safe for servers still running version 1: they keep working, and leave `Pets` alone.

## Renaming or reshaping a field [#renaming-or-reshaping-a-field]

Version 3 renames `Gold` to `Coins`. Old servers would look for `Gold` and not find it, so this is a breaking change. Add it to the end of the list with `IsBreaking = true`:

```luau
	Migrations = {
		-- 1: version 2 added Pets.
		{
			Fields = { "Pets" },
			Run = function(Stored: unknown): unknown
				local New = table.clone(Stored :: Saved)
				New.Pets = {}
				return New
			end,
		},
		-- 2: version 3 renamed Gold to Coins.
		{
			IsBreaking = true,
			Run = function(Stored: unknown): unknown
				local New = table.clone(Stored :: Saved)
				New.Coins = New.Gold
				New.Gold = nil
				return New
			end,
		},
	},
```

A player whose data has been through a breaking migration can't be loaded by an older server. That server answers `Behind` for them instead of reading data it doesn't understand.

Use a breaking migration for anything that isn't a new top-level field: a rename, a removed field, a changed type, or a new field inside a table you already have.

## Update the rest of your code too [#update-the-rest-of-your-code-too]

Migrations run before your code ever sees the data, so everything else only deals with the newest shape. When you rename `Gold` to `Coins`:

* Change `PlayerData` and `Default` to use `Coins`.
* Change the reducer to read and write `Coins`.
* Change every other script that reads `Gold`, like your leaderstats.

```luau
-- in the reducer:
if Op.Kind == "AddCoins" then
	local New = table.clone(Data)
	New.Coins += Op.Amount
	return New
end
```

Studio's script analysis points out every place that still uses `Gold`, because it's no longer in `PlayerData`.

## The rules [#the-rules]

* **Only add to the end.** Never change, remove or reorder a migration that has shipped. Ledger knows them by their place in the list.
* **One kind of change per migration.** A new field and a rename are two migrations.
* **Keep `Run` simple.** It only turns data into data. No waiting, and no Ledger calls.
* **`Run` must work.** If it errors or returns `nil`, that player's data can't be loaded: the load answers `Unreadable` and Ledger warns with the key. Nothing is lost. Fix the migration and publish again.
* **Never change the store's `Name` or `Keys`.** A new name is a new, empty store.

## Publishing the update [#publishing-the-update]

Roblox doesn't update every server at once, so old and new servers run side by side for a while.

* **Only new fields:** publish as usual. Old servers keep working.
* **Anything breaking:** publish, then shut down all servers from the Creator Hub, so everyone rejoins on the new version.

If you don't shut down, a player whose data is newer than the server they join can't load there. They're kicked with your `KickMessage`, so make it say what to do:

```luau
	KickMessage = "The game just updated. Please rejoin.",
```

## Data from before Ledger [#data-from-before-ledger]

Ledger can't read data your game saved with plain DataStore calls or another library. Use a new store `Name`, and copy each player's old data in the first time they join, with an op that only works once:

```luau
-- in the reducer:
if Op.Kind == "Import" then
	if Data.IsImported then
		return nil -- already done
	end

	return { Gold = Data.Gold + Op.Gold, IsImported = true }
end
```

```luau
local OldStore = DataStoreService:GetDataStore("PlayerData")

local function OnPlayerAdded(Player: Player)
	local Session = PlayerStore:WaitForLoaded(Player)
	if not Session or Session:Get().IsImported then
		return
	end

	local IsRead, Old = pcall(function()
		return OldStore:GetAsync(tostring(Player.UserId))
	end)
	if not IsRead then
		Player:Kick("We couldn't load your old data. Please rejoin in a minute.")
		return
	end

	local OldGold = if type(Old) == "table" and type(Old.Gold) == "number" then Old.Gold else 0
	Session:Commit({ Kind = "Import", Gold = OldGold })
end

Players.PlayerAdded:Connect(OnPlayerAdded)
```

Add `IsImported = false` to `Default`. The reducer refuses a second import, so it's safe if the player joins two servers at once. A player who never had old data gets 0, and is marked imported too.

Change the `GetAsync` key and the fields to match how your game saved them.

## Updating Ledger itself [#updating-ledger-itself]

Read the [release notes](/docs/releases) first. Then publish every place in your game with the new Ledger at once, and shut down all servers.

Next: [Deleting data](/docs/learn/deleting-data)


# Common mistakes (https://xoifaii.github.io/docs/learn/common-mistakes)



Each of these runs fine in a quick test, then loses or duplicates data once real players arrive. They're all covered on earlier pages; this is the short version to check your game against.

## Sending again after `Unresolved` [#sending-again-after-unresolved]

```luau
-- Wrong: the first one may still go through, so the player can get paid twice
local Ok, Why = PlayerStore:Edit(UserId, AddGold)
if Why == "Unresolved" then
	PlayerStore:Edit(UserId, AddGold)
end
```

```luau
-- Right: leave it. Ledger keeps sending the first one until it knows.
local Ok, Why = PlayerStore:Edit(UserId, AddGold)
if Why == "Unresolved" then
	return
end
```

If you really need to send it again, name it first. See [Once only](/docs/learn/once-only).

## Treating `nil` as empty [#treating-nil-as-empty]

```luau
-- Wrong: a read that failed looks like a brand new player
local Data = PlayerStore:Peek(UserId)
local Gold = if Data then Data.Gold else 0
```

```luau
-- Right: only Missing means "nothing saved"
local Data, Why = PlayerStore:Peek(UserId)
if not Data and Why ~= "Missing" then
	return -- couldn't read it, try again later
end
local Gold = if Data then Data.Gold else 0
```

See [Reading data](/docs/learn/reading-data).

## Changing the table the reducer was given [#changing-the-table-the-reducer-was-given]

```luau
-- Wrong: changes the data Ledger handed you, not a copy
if Op.Kind == "AddGold" then
	Data.Gold += Op.Amount
	return Data
end
```

```luau
-- Right: change a copy
if Op.Kind == "AddGold" then
	local New = table.clone(Data)
	New.Gold += Op.Amount
	return New
end
```

Studio throws for the wrong version. A live server doesn't, and the data goes wrong instead. See [Bigger reducers](/docs/learn/bigger-reducers).

## Time or randomness in the reducer [#time-or-randomness-in-the-reducer]

```luau
-- Wrong: the reducer can run more than once, and give a different answer each time
if Op.Kind == "OpenEgg" then
	local Pet = PETS[math.random(#PETS)]
	-- ...
end
```

```luau
-- Right: pick it outside, and put it in the op
local Pet = PETS[math.random(#PETS)]
Session:Apply({ Kind = "OpenEgg", Pet = Pet })
```

The same goes for `os.time()`. The daily reward on [Once only](/docs/learn/once-only) puts the day in the op for this reason.

## Changing data outside the reducer [#changing-data-outside-the-reducer]

```luau
-- Wrong: the player sees gold that isn't saved
Player.leaderstats.Gold.Value += 10
PlayerStore:Edit(Player.UserId, AddGold)
```

```luau
-- Right: change the data with an op, and show what was saved
local Ok = PlayerStore:Edit(Player.UserId, AddGold)
local Session = PlayerStore:Get(Player)
if Ok and Session then
	Session:Refresh()
end
```

See [Purchases](/docs/learn/purchases).

## Not refreshing after `Edit`, a trade or a sale [#not-refreshing-after-edit-a-trade-or-a-sale]

```luau
-- Wrong: the session still shows the old gold until its next save
PlayerStore:Edit(Player.UserId, AddGold)
print(Session:Get().Gold)
```

```luau
-- Right: Refresh once it's saved
local Ok = PlayerStore:Edit(Player.UserId, AddGold)
if Ok then
	Session:Refresh()
end
```

## Not flushing before a trade or a sale [#not-flushing-before-a-trade-or-a-sale]

```luau
-- Wrong: the player just spent gold with Apply, but it isn't saved yet,
-- so the trade sees the gold they no longer have
Session:Apply({ Kind = "SpendGold", Amount = 100 })
Ledger.Tx({ ... })
```

```luau
-- Right: save what's waiting first
Session:Apply({ Kind = "SpendGold", Amount = 100 })
Session:Flush()
Ledger.Tx({ ... })
```

See [Trading](/docs/learn/trading).

## Making the same store twice [#making-the-same-store-twice]

```luau
-- Wrong: a second Ledger.New for the same store, in another script
local PlayerStore = Ledger.New<<PlayerData, PlayerOps>>({ Name = "PlayerData", ... })
```

```luau
-- Right: make it once in Stores, and require it everywhere
local Stores = require(ServerStorage.Stores)
local PlayerStore = Stores.PlayerStore
```

## Adding a field without a migration [#adding-a-field-without-a-migration]

```luau
-- Wrong: players who saved before this update have no Pets, so Data.Pets is nil
Default = { Gold = 0, Pets = {} },
```

```luau
-- Right: add the field to Default and add a migration
Default = { Gold = 0, Pets = {} },
Migrations = {
	{
		Fields = { "Pets" },
		Run = function(Stored: unknown): unknown
			local New = table.clone(Stored :: Saved)
			New.Pets = {}
			return New
		end,
	},
},
```

See [Changing your data](/docs/learn/changing-data).

## Waiting for a counter on the player's thread [#waiting-for-a-counter-on-the-players-thread]

```luau
-- Wrong: Bump can take up to a minute, and the player waits for it
StatsStore:Bump("BossKills", 1)
```

```luau
-- Right: run it in the background
task.spawn(function()
	StatsStore:Bump("BossKills", 1)
end)
```

See [Global counters](/docs/learn/global-counters).

## Opening a limited item after the sale ended [#opening-a-limited-item-after-the-sale-ended]

```luau
-- Wrong: once the sale is closed, Take answers Missing again, and this makes the stock again
if Result == "Missing" then
	Stock:Open()
end
```

```luau
-- Right: only open while the sale is on
if Result == "Missing" and os.time() < SALE_ENDS then
	Stock:Open()
end
```

See [Limited items](/docs/learn/limited-items).

## Waiting inside a `Follow` [#waiting-inside-a-follow]

```luau
-- Wrong: Edit waits, and a Follow function can't
GuildStore:Follow(GuildId):Subscribe(function(Value)
	GuildStore:Edit(GuildId, Op)
end)
```

```luau
-- Right: start it in a new thread
GuildStore:Follow(GuildId):Subscribe(function(Value)
	task.spawn(function()
		GuildStore:Edit(GuildId, Op)
	end)
end)
```

## Saving in `BindToClose` [#saving-in-bindtoclose]

```luau
-- Wrong: by the time this runs, Ledger is already closing, and Apply answers Closed
game:BindToClose(function()
	PayOutRounds()
end)
```

```luau
-- Right
Ledger.BeforeClose(function()
	PayOutRounds()
end)
```

See [Shutdown and testing](/docs/learn/shutdown-and-testing).

That's the end of the Learn pages. [Answers](/docs/learn/answers) lists every answer a call can give.

Next: [Auctions and markets](/docs/guides/auctions-and-markets)


# Deleting data (https://xoifaii.github.io/docs/learn/deleting-data)



Sometimes Roblox sends you a "Right to Erasure" request: a player's account was deleted, and you have to delete their data. This page shows how, and how to wipe a player back to the start without deleting them.

## Deleting a player's data [#deleting-a-players-data]

Your store needs `Erasable = true`, as in [Your data](/docs/learn/your-data). Then:

```luau
-- Deletes a player's saved data. True once nothing is saved for them.
local function ErasePlayer(UserId: number): (boolean, string?)
	local Ok, Result = PlayerStore:Erase(UserId)
	if Ok or Result == "Missing" then
		return true, nil -- erased, or there was nothing to erase
	end

	return false, tostring(Result)
end
```

`Erase` deletes everything saved for that player. `Missing` means nothing was saved for them, which is just as good.

Run it from an admin command, or anywhere on the server that suits you. If it answers anything else, like `Busy` or `Unresolved`, run it again a bit later. Erasing twice is safe.

## Other places their UserId lives [#other-places-their-userid-lives]

`Erase` only deletes the player's own data. If you keep their UserId anywhere else, like in a guild's member list or a trade log, remove it from there too, with an op of your own on that store.

## Checking it worked [#checking-it-worked]

A server that was still saving the player's data when you erased it could write it back. Their account is usually already deleted, so this is rare, but it's worth checking a day later:

```luau
-- True if nothing is saved for this player.
local function IsGone(UserId: number): boolean
	local Data, Why = PlayerStore:Peek(UserId)
	return Data == nil and Why == "Missing"
end
```

If it's not gone, erase it again.

Roblox also keeps old versions of every DataStore key for 30 days. Ledger doesn't delete those.

## Wiping a player back to the start [#wiping-a-player-back-to-the-start]

To reset a player without deleting them, for example a cheater's progress, use `Reset`:

```luau
local function WipePlayer(UserId: number): (boolean, string?)
	local Ok, Result = PlayerStore:Reset(UserId)
	if Ok then
		return true, nil
	end

	return false, tostring(Result)
end
```

`Reset` puts their data back to `Default` and keeps the key. It works on any store, `Erasable` or not. `Missing` means they have no saved data, so there's nothing to reset.

If the player is in a game when you do this, kick them first, so they rejoin with the reset data.

## Turning `Erasable` on later [#turning-erasable-on-later]

If your store went live with `Erasable = false`, you can turn it on in an update. Players saved before that can still be erased. Wait until no server is running the old version before you erase anyone: shut down all servers after you publish.

Next: [Shutdown and testing](/docs/learn/shutdown-and-testing)


# Getting started (https://xoifaii.github.io/docs/learn/getting-started)



## Install [#install]

Pick one:

* **Wally:** add `Ledger = "xoifaii/ledger@7.0.0"` to `[dependencies]` in your `wally.toml`.
* **Model file:** download `Ledger.rbxm` from the GitHub releases page and drop it into `ReplicatedStorage`.

Ledger goes in `ReplicatedStorage` so your client scripts can use `Ledger.Reason` too. Everything else in Ledger only runs on the server.

The samples on these pages use `require(ReplicatedStorage.Ledger)`. With Wally, require it from your `Packages` folder instead.

To test saving in Studio, turn on **Game Settings → Security → Enable Studio Access to API Services**.

## Make a store [#make-a-store]

A store is where one kind of data lives. Put your stores in one ModuleScript, `ServerStorage.Stores`, so every server script uses the same ones and clients can't see them.

```luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ledger = require(ReplicatedStorage.Ledger)

export type PlayerData = {
	Gold: number,
}

type PlayerOps = {
	AddGold: { Amount: number },
	SpendGold: { Amount: number },
}

local PlayerStore = Ledger.New<<PlayerData, PlayerOps>>({
	Name = "PlayerData",
	Keys = "Player",
	Default = { Gold = 0 },
	MustExist = false,
	Erasable = true,
	Reducer = function(Data, Op)
		if Op.Kind == "AddGold" then
			return { Gold = Data.Gold + Op.Amount }
		end

		if Op.Kind == "SpendGold" then
			if Data.Gold < Op.Amount then
				return nil -- not enough gold
			end

			return { Gold = Data.Gold - Op.Amount }
		end

		return nil
	end,
})

return {
	PlayerStore = PlayerStore,
}
```

Here's what each part does:

* **`PlayerData`** is what one player's data looks like.
* **`PlayerOps`** lists the changes you're allowed to make to it. Each change has a `Kind` and whatever it needs, here an `Amount`.
* **`Default`** is what a brand new player starts with.
* **`Reducer`** takes the player's data and a change, and returns the new data. Return `nil` to say no, like when a player tries to spend gold they don't have.

Ledger only ever changes your data through the reducer.

`MustExist` and `Erasable` are covered in [Your data](/docs/learn/your-data). For player data, `false` and `true` are what you want.

## Load players when they join [#load-players-when-they-join]

Ledger doesn't load anyone by itself. Load each player when they join, and unload them when they leave:

```luau
--!strict
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local Stores = require(ServerStorage.Stores)

local PlayerStore = Stores.PlayerStore

local function OnPlayerAdded(Player: Player)
	local Session = PlayerStore:Load(Player)
	if not Session then
		return -- they left while loading, or the load failed and they were kicked
	end

	print(Player.Name, "has", Session:Get().Gold, "gold")
end

local function OnPlayerRemoving(Player: Player)
	PlayerStore:Unload(Player)
end

Players.PlayerAdded:Connect(OnPlayerAdded)
Players.PlayerRemoving:Connect(OnPlayerRemoving)

for _, Player in Players:GetPlayers() do
	task.spawn(OnPlayerAdded, Player)
end
```

`Load` gives you the player's **session**. You use the session to read and change their data while they're in your server.

If `Load` gives you `nil`, the player either left while loading, or their data couldn't be loaded and Ledger kicked them so they don't play on empty data. Either way, just stop.

`Session:Get()` gives you their data as it is right now. It's read-only: you change data with ops, never by editing what `Get` gives you.

The loop at the bottom catches players who joined before the script started running.

You don't need `BindToClose`. When the server shuts down, Ledger saves everyone for you.

## Show gold on the leaderboard [#show-gold-on-the-leaderboard]

Now swap the `print` for a leaderstats folder, and keep it up to date:

```luau
local function OnPlayerAdded(Player: Player)
	local Session = PlayerStore:Load(Player)
	if not Session then
		return -- they left while loading, or the load failed and they were kicked
	end

	local Leaderstats = Instance.new("Folder")
	Leaderstats.Name = "leaderstats"

	local Gold = Instance.new("IntValue")
	Gold.Name = "Gold"
	Gold.Value = Session:Get().Gold
	Gold.Parent = Leaderstats

	Leaderstats.Parent = Player

	Session:Observe():Subscribe(function(Data)
		Gold.Value = Data.Gold
	end)
end
```

`Session:Observe():Subscribe(...)` runs your function every time the player's data changes. It doesn't run straight away, which is why we set `Gold.Value` from `Get()` first.

## Give the player gold [#give-the-player-gold]

Last, give the player 100 gold every time they join. Add a constant at the top of the script:

```luau
local JOIN_GOLD = 100
```

And one line at the end of `OnPlayerAdded`:

```luau
	Session:Apply({ Kind = "AddGold", Amount = JOIN_GOLD })
```

`Session:Apply` changes the data straight away, so the leaderboard updates with it. Ledger saves it with the player's next save, within about 30 seconds.

For things that must be saved before you move on, like a Robux purchase, use `Session:Commit` instead. That's covered in [Players](/docs/learn/players) and [Purchases](/docs/learn/purchases).

Here's the whole script:

```luau
--!strict
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local Stores = require(ServerStorage.Stores)

local PlayerStore = Stores.PlayerStore

local JOIN_GOLD = 100

local function OnPlayerAdded(Player: Player)
	local Session = PlayerStore:Load(Player)
	if not Session then
		return -- they left while loading, or the load failed and they were kicked
	end

	local Leaderstats = Instance.new("Folder")
	Leaderstats.Name = "leaderstats"

	local Gold = Instance.new("IntValue")
	Gold.Name = "Gold"
	Gold.Value = Session:Get().Gold
	Gold.Parent = Leaderstats

	Leaderstats.Parent = Player

	Session:Observe():Subscribe(function(Data)
		Gold.Value = Data.Gold
	end)

	Session:Apply({ Kind = "AddGold", Amount = JOIN_GOLD })
end

local function OnPlayerRemoving(Player: Player)
	PlayerStore:Unload(Player)
end

Players.PlayerAdded:Connect(OnPlayerAdded)
Players.PlayerRemoving:Connect(OnPlayerRemoving)

for _, Player in Players:GetPlayers() do
	task.spawn(OnPlayerAdded, Player)
end
```

Next: [Your data](/docs/learn/your-data)


# Global counters (https://xoifaii.github.io/docs/learn/global-counters)



Say you want a sign in the lobby that shows how many times the boss has been killed, across every server. Every server adds to the number all the time. If they all wrote to one key, that key would run out of writes fast. A counter spreads the adds out and adds them up for you.

Counters are for stats you show. They're not for gold or anything a player owns: that belongs in the player's data.

## 1. Declare the counters [#1-declare-the-counters]

Counters live in a store of their own. Add it to `Stores`:

```luau
local StatsStore = Ledger.New({
	Name = "GlobalStats",
	Keys = "String",
	Default = {},
	MustExist = false,
	Erasable = false,
	Totals = {
		GoldSpent = {},
		BossKills = {},
	},
})
```

This store only holds counters, so it has no data or reducer of its own. Each name in `Totals` is one counter, and starts at 0.

## 2. Add to a counter [#2-add-to-a-counter]

Put this in a ModuleScript called `GlobalStats` in `ServerStorage`:

```luau
--!strict
local ServerStorage = game:GetService("ServerStorage")

local Stores = require(ServerStorage.Stores)

local StatsStore = Stores.StatsStore

-- Adds to a counter in the background. Call it only once the thing you count has saved.
local function Add(Name: string, Amount: number)
	task.spawn(function()
		local Ok, Why = StatsStore:Bump(Name, Amount)
		if not Ok and Why ~= "Unresolved" then
			warn("Couldn't count", Name, Why)
		end
	end)
end

-- The counter's total, or nil if it can't be read right now.
local function Read(Name: string): number?
	local Total = StatsStore:Total(Name, 60)
	return Total
end

return {
	Add = Add,
	Read = Read,
}
```

`Bump` adds to the counter. It waits for the next batch, which can take up to a minute, because each server saves its adds together instead of one by one. That's why `Add` runs it in `task.spawn`: never make a player wait for it.

Add only once the thing you're counting has actually saved:

```luau
local Ok = Session:Commit({ Kind = "SpendGold", Amount = 25 })
if Ok then
	GlobalStats.Add("GoldSpent", 25)
end
```

A counter is separate from the player's data. If you add first and the purchase then fails, the counter still went up.

`Amount` is a whole number, and it can be negative to take some away.

## What `Bump` answers [#what-bump-answers]

| Answer       | What it means                                                        |
| ------------ | -------------------------------------------------------------------- |
| `true`       | Counted.                                                             |
| `Unresolved` | Ledger is still sending it. Don't send it again, or it counts twice. |
| `Busy`       | Too many adds at once. This one wasn't counted.                      |
| `Closed`     | The server is shutting down. Not counted.                            |

For a stat on a sign, missing the odd add is fine, so `Add` just warns. [Answers](/docs/learn/answers) has the rest.

## 3. Show the total [#3-show-the-total]

```luau
--!strict
local ServerStorage = game:GetService("ServerStorage")

local GlobalStats = require(ServerStorage.GlobalStats)

local REFRESH_SECONDS = 60

while true do
	local Kills = GlobalStats.Read("BossKills")
	if Kills then
		workspace:SetAttribute("BossKills", Kills)
	end

	task.wait(REFRESH_SECONDS)
end
```

`Total(Name, 60)` answers the counter. It reuses an answer up to 60 seconds old, and otherwise reads a copy that all your servers share, so it usually costs no DataStore requests. Read it about once a minute, not every frame. A new add can take a few minutes to show up in the total.

## Changing counters later [#changing-counters-later]

You can add new counters to `Totals` at any time. Don't rename one: a new name is a new counter that starts at 0.

Next: [Changing data](/docs/learn/changing-data)


# Limited items (https://xoifaii.github.io/docs/learn/limited-items)



Say you want to sell exactly 300 Golden Swords, each with its own number from 1 to 300, across every server at once. If each server kept its own count, two servers could sell sword number 300 at the same moment. Ledger keeps one shared stock, so that never happens.

## 1. Declare the stock [#1-declare-the-stock]

The stock lives in a store of its own. Add it to `Stores`:

```luau
local ItemStore = Ledger.New({
	Name = "LimitedItems",
	Keys = "String",
	Default = {},
	MustExist = false,
	Erasable = false,
	Quantities = {
		GoldenSword = { Parts = 2, Mode = "Final", Stock = 300, Serials = { First = 1, Count = 300 } },
	},
})
```

This store only holds stock, so it has no data or reducer of its own.

* **`Stock`** is how many there will ever be.
* **`Serials`** numbers them. Here they go from 1 to 300, so `Count` matches `Stock`. Leave `Serials` out if you don't need numbers.
* **`Mode = "Final"`** means the stock never grows. Once the last one sells, it's sold out for good.
* **`Parts`** splits the stock so many servers can sell at once. For a few hundred items, 2 is plenty. More parts let more servers sell at the same moment.

Once the sale is live, never change these numbers. To sell more later, add a new quantity with a new name and its own serial range, like `GoldenSword2` with `First = 301`.

## 2. The buyer's op [#2-the-buyers-op]

The player needs somewhere to keep their serial numbers, and an op that charges them. Add `Serials` to `PlayerData` and its `Default`, and a `BuyLimited` op:

```luau
export type PlayerData = {
	Gold: number,
	Serials: { [string]: number },
}

type PlayerOps = {
	-- ... the ops you have
	BuyLimited: { Item: string, Price: number },
}
```

```luau
-- in the reducer:
if Op.Kind == "BuyLimited" then
	if Data.Gold < Op.Price then
		return nil -- not enough gold
	end

	if Data.Serials[Op.Item] then
		return nil -- already owns one
	end

	local New = table.clone(Data)
	New.Gold -= Op.Price
	return New
end
```

The reducer only takes the gold. It never writes the serial number itself: Ledger does that in the next step.

## 3. Sell it [#3-sell-it]

Put this in a ModuleScript called `GoldenSword` in `ServerStorage`:

```luau
--!strict
local ServerStorage = game:GetService("ServerStorage")

local Stores = require(ServerStorage.Stores)

local PlayerStore = Stores.PlayerStore
local Stock = Stores.ItemStore:Quantity("GoldenSword")

local ITEM = "GoldenSword"
local PRICE = 500
local SALE_ENDS = DateTime.fromUniversalTime(2026, 12, 31).UnixTimestamp

local IsOpened = false

local function TakeOne(Player: Player)
	local Op = { Kind = "BuyLimited" :: "BuyLimited", Item = ITEM, Price = PRICE }
	return Stock:Take(1, {
		Legs = { { Store = PlayerStore, Key = Player.UserId, Op = Op, Slot = { "Serials", ITEM } } },
	})
end

-- Sells one sword. The serial number lands in the player's Serials.
local function Buy(Player: Player): (boolean, string?)
	if os.time() >= SALE_ENDS then
		return false, "SoldOut"
	end

	local Session = PlayerStore:Get(Player)
	if Session then
		Session:Flush()
	end

	local Ok, Result, Info = TakeOne(Player)

	if Result == "Missing" and not IsOpened then
		-- The very first sale on this server: make the stock, then try again.
		IsOpened = true
		Stock:Open()
		Ok, Result, Info = TakeOne(Player)
	end

	local Why = if type(Result) == "string" then Result else nil
	if Why == "Unresolved" and Info and Info.Outcome then
		Ok, Why = Info.Outcome:Wait()
	end

	local SessionAfter = PlayerStore:Get(Player)
	if SessionAfter then
		SessionAfter:Refresh()
	end

	return Ok, Why
end
```

`Take(1, ...)` takes one sword from the stock. The `Legs` line runs the buyer's `BuyLimited` op in the same step, so the stock goes down and the gold comes off together, or neither happens. If the reducer says no, the sword stays in stock.

`Slot = { "Serials", ITEM }` tells Ledger where to write the sword's number. After a sale, the player's data has `Serials.GoldenSword = 17`, or whichever number they got.

Like a [trade](/docs/learn/trading), the sale works on the player's saved data. That's why it calls `Flush` before and `Refresh` after.

The stock doesn't exist until something makes it. The first time anyone tries to buy, `Take` answers `Missing`, and the code calls `Open` to make it. `Open` only does anything the first time, so it doesn't matter which server gets there first. The `SALE_ENDS` check matters here: after the sale is over, the stock is removed, and calling `Open` again would make 300 new swords.

### What `Buy` answers [#what-buy-answers]

| Answer       | What it means                                                                                              |
| ------------ | ---------------------------------------------------------------------------------------------------------- |
| `true`       | Sold. The number is in the player's `Serials`.                                                             |
| `Refused`    | The reducer said no: not enough gold, or they already own one.                                             |
| `SoldOut`    | None left.                                                                                                 |
| `Short`      | None free right now. Treat it as sold out.                                                                 |
| `Unresolved` | Only if the wait gave up too. Ledger keeps going, and the sword shows up in their data if it went through. |

[Answers](/docs/learn/answers) has the rest.

## 4. Show how many are left [#4-show-how-many-are-left]

```luau
local function Left(): number?
	local Counts = Stock:Total(15)
	if not Counts then
		return nil
	end

	return Counts.Free
end
```

`Total` gives `Free`, how many are left to buy, and `Held`. The `15` lets it reuse an answer up to 15 seconds old, and otherwise it reads a shared copy, so it costs no DataStore requests and is fine to call for a shop screen. Sold so far is `300 - Counts.Free - Counts.Held`.

## 5. End the sale [#5-end-the-sale]

When the sale is over, close the stock. A Script in `ServerScriptService`:

```luau
--!strict
local ServerStorage = game:GetService("ServerStorage")

local GoldenSword = require(ServerStorage.GoldenSword)

-- Every server closes the sale when it ends. A server that starts later closes it again, which is safe.
task.delay(math.max(0, GoldenSword.SALE_ENDS - os.time()), GoldenSword.EndSale)
```

With this in `GoldenSword`, and `EndSale` and `SALE_ENDS` added to what it returns:

```luau
local function EndSale()
	Stock:Close()
end
```

`Close` is safe to call from every server, any number of times. After it, nothing more sells. It also removes the parts of the stock that sold out (once the stock is over an hour old), and a `Take` on those answers `Missing` again, as if it had never been opened.

That's the one thing to be careful about. Never call `Open` on a sale that's ended, or the stock comes back. The `SALE_ENDS` check in `Buy` stops that. In your next update, also mark the quantity closed, which makes `Open` throw:

```luau
GoldenSword = { Parts = 2, Mode = "Final", Stock = 300, Serials = { First = 1, Count = 300 }, Closed = true },
```

## Holding one during checkout [#holding-one-during-checkout]

If the player has to confirm first, like a Robux purchase, you can hold a sword for a few minutes so nobody else gets it meanwhile. See `Hold`, `Confirm` and `Release` in the [reference](/docs/reference/quantity).

Next: [Global counters](/docs/learn/global-counters)


# Once only (https://xoifaii.github.io/docs/learn/once-only)



Ledger never applies one call twice, even when it has to send it again after a DataStore hiccup. For most changes, that's all you need.

This page is for rules like "once per day" or "once per code". Those are about your game, not about one call: a player can spam the button, or claim from two servers at once. The safe way to handle them is to keep a record in the player's data.

## Keep a record in the data [#keep-a-record-in-the-data]

Here's a daily reward and a code system. `LastDailyDay` remembers the day the reward was last claimed, and `RedeemedCodes` remembers every code the player has used:

```luau
export type PlayerData = {
	Gold: number,
	LastDailyDay: number,
	RedeemedCodes: { [string]: boolean },
}
```

The reducer checks the record before giving anything, and updates it in the same change:

```luau
	Reducer = function(Data, Op)
		if Op.Kind == "ClaimDaily" then
			if Data.LastDailyDay == Op.Day then
				return nil -- already claimed today
			end

			local New = table.clone(Data)
			New.Gold += Op.Amount
			New.LastDailyDay = Op.Day
			return New
		end

		if Op.Kind == "RedeemCode" then
			if Data.RedeemedCodes[Op.Code] then
				return nil -- already redeemed
			end

			local RedeemedCodes = table.clone(Data.RedeemedCodes)
			RedeemedCodes[Op.Code] = true

			local New = table.clone(Data)
			New.Gold += Op.Amount
			New.RedeemedCodes = RedeemedCodes
			return New
		end

		return nil
	end,
```

Because the check and the reward happen in one change, there's no gap where a second claim can slip in. However many times the op is sent, from however many servers, only the first one gets through. The rest are refused.

## Sending it [#sending-it]

Your script works out the day and sends the op. The reducer can't use the clock, so the day goes in the op:

```luau
local SECONDS_PER_DAY = 86400
local DAILY_GOLD = 100

local CODES: { [string]: number } = {
	RELEASE = 500,
	THANKYOU = 250,
}

local function OnClaimDaily(Player: Player)
	local Session = PlayerStore:Get(Player)
	if not Session then
		return
	end

	local Today = os.time() // SECONDS_PER_DAY

	local Ok = Session:Apply({ Kind = "ClaimDaily", Day = Today, Amount = DAILY_GOLD })
	if not Ok then
		print(Player.Name, "already claimed today")
		return
	end

	print(Player.Name, "claimed their daily reward")
end

local function OnRedeemCode(Player: Player, Code: unknown)
	if type(Code) ~= "string" then
		return
	end

	local Amount = CODES[Code]
	if not Amount then
		return -- not a real code
	end

	local Session = PlayerStore:Get(Player)
	if not Session then
		return
	end

	local Ok = Session:Apply({ Kind = "RedeemCode", Code = Code, Amount = Amount })
	if not Ok then
		print(Player.Name, "already used", Code)
		return
	end

	print(Player.Name, "redeemed", Code)
end
```

The codes and amounts live on the server, so a player can't make up their own.

## Why this is safe [#why-this-is-safe]

With a record in the data, sending the same op twice is harmless. That matters when something goes wrong:

* If the player clicks twice, the second click is refused.
* If a save is lost in a long DataStore outage, the player can just claim again, and they'll get it exactly once.

This is the same pattern [Purchases](/docs/learn/purchases) uses for Robux, where Roblox does the asking again for you.

Records grow, so keep them small. One number for the last day is enough for a daily reward. For codes, a table of the codes used is fine, since there are only ever a few.

## Names [#names]

Ledger quietly names every change it sends, which is how it never applies one twice. You can pass your own name with an `Id` option, but you don't need to anywhere in these docs.

Three answers are about names. You'll mostly see them when you pass your own:

| Reason    | What it means                                                                                                                                  |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `Spent`   | That name was already used for a different change, or a [trade](/docs/learn/trading) stopped without going through. This call changed nothing. |
| `Expired` | Ledger has forgotten the name. Names are kept for a few minutes. Nothing was sent.                                                             |
| `NoRoom`  | Too many names on this data at once. Nothing was sent. Try again in a moment.                                                                  |

Next: [Purchases](/docs/learn/purchases)


# Players (https://xoifaii.github.io/docs/learn/players)



On [Getting started](/docs/learn/getting-started) you loaded each player when they joined and unloaded them when they left. This page covers what you do in between.

## Getting a player's session [#getting-a-players-session]

Any server script can get a loaded player's session from the store:

```luau
local Session = PlayerStore:Get(Player)
if not Session then
	return -- still loading
end
```

`Get` gives you `nil` until the player's data has loaded, and again once they've left. Always check for it.

If your script runs while the player might still be loading, like a remote the client fires as soon as it starts, wait for the load instead:

```luau
local function OnClientReady(Player: Player)
	local Session = PlayerStore:WaitForLoaded(Player)
	if not Session then
		return -- the load failed, or they left
	end

	print(Player.Name, "is ready with", Session:Get().Gold, "gold")
end
```

`WaitForLoaded` waits for the load to finish. It gives you `nil` if the load failed or the player left.

Don't keep a session around after the player leaves. Once a player is unloaded, their old session errors if you use it. Get it fresh with `PlayerStore:Get` each time instead.

## `Apply` or `Commit` [#apply-or-commit]

There are two ways to change a player's data:

|                   | `Session:Apply`                             | `Session:Commit`                                  |
| ----------------- | ------------------------------------------- | ------------------------------------------------- |
| Shows in the data | Straight away                               | Once it's saved                                   |
| Saved             | With the next save, within about 30 seconds | Before it answers                                 |
| Waits             | No                                          | Yes, until the save is done                       |
| Use it for        | Most things: coins from kills, XP, settings | Things you'd hate to lose: rare items, big spends |

Saves are cheap with `Apply`: every change made in those 30 seconds goes out in one save, however many there are.

Here's a rare item bought with `Commit`:

```luau
local RARE_ITEM = "GoldenDragon"
local RARE_PRICE = 5000

local function OnBuyRare(Player: Player)
	local Session = PlayerStore:Get(Player)
	if not Session then
		return -- still loading
	end

	local Ok, Result = Session:Commit({ Kind = "BuyItem", Item = RARE_ITEM, Price = RARE_PRICE })
	if not Ok then
		print(Player.Name, "couldn't buy the dragon:", Result)
		return
	end

	print(Player.Name, "bought the dragon and it's saved")
end
```

When `Commit` gives back `true`, the change is saved. When it gives back `false`, the second value says why, like `"Refused"` when the reducer said no. [Answers](/docs/learn/answers) lists every reason and what to do about it.

One you'll see in an outage is `"Unresolved"`: the save didn't answer in time. Ledger keeps sending it for you, so don't send it again.

## Saving right now [#saving-right-now]

`Session:Flush()` saves anything `Apply` has waiting, without waiting for the next save. Use it before you teleport a player, so the next place sees their latest data:

```luau
local function OnGoToLobby(Player: Player)
	local Session = PlayerStore:Get(Player)
	if Session then
		Session:Flush() -- save anything waiting before they leave
	end

	TeleportService:TeleportAsync(LOBBY_PLACE_ID, { Player })
end
```

You don't need `Flush` when a player leaves or the server shuts down. `Unload` and shutdown save for you.

## Changes from somewhere else [#changes-from-somewhere-else]

A player's data can also change outside their session, for example in a [trade](/docs/learn/trading). The session doesn't see that change straight away:

* **On the same server**, call `Session:Refresh()` right after, and the player sees it at once. The [Trading](/docs/learn/trading) page does this for both players.
* **From another server**, Ledger doesn't tell this server about it. The session picks it up on its own within about 2 minutes. If it needs to show sooner, like a gift from a friend in another server, send a message with `MessagingService` and call `Refresh` on the server that receives it. [Shared data](/docs/learn/shared-data#gifts-to-players-in-other-servers) has the full code.

## When loading fails [#when-loading-fails]

If Ledger can't load a player's data, for example during a Roblox DataStore outage, it kicks them so they don't play on empty data. You can change the kick message, and run your own code when it happens:

```luau
	KickMessage = "We couldn't load your data. Please rejoin in a minute.",
	OnLoadFailed = function(Player, Reason)
		warn("Couldn't load", Player.Name, Reason)
	end,
```

Both go in your store's options, next to `Default`. `OnLoadFailed` runs first, then the kick. It doesn't run when the player just left while loading.

## When a player leaves [#when-a-player-leaves]

`PlayerStore:Unload(Player)` saves anything waiting and ends the session. It's the `PlayerRemoving` line you already have.

When the server shuts down, Ledger saves every loaded player for you. You don't need `BindToClose`.

Next: [Answers](/docs/learn/answers)


# Purchases (https://xoifaii.github.io/docs/learn/purchases)



Roblox sends your game a receipt for every developer product purchase. If you don't say the purchase was granted, Roblox sends the same receipt again the next time that player buys something or joins one of your servers. So the same receipt can arrive more than once. This page makes sure the player gets paid exactly once.

It's the record pattern from [Once only](/docs/learn/once-only): remember each purchase id in the player's data, and refuse any id you've already seen.

## Add the op [#add-the-op]

```luau
export type PlayerData = {
	Gold: number,
	Receipts: { string },
}

type PlayerOps = {
	GrantPurchase: { PurchaseId: string, Gold: number },
}

local RECEIPTS_KEPT = 1000

local PlayerStore = Ledger.New<<PlayerData, PlayerOps>>({
	Name = "PlayerData",
	Keys = "Player",
	Default = { Gold = 0, Receipts = {} },
	MustExist = false,
	Erasable = true,
	Reducer = function(Data, Op)
		if Op.Kind == "GrantPurchase" then
			if table.find(Data.Receipts, Op.PurchaseId) then
				return nil -- already granted
			end

			local Receipts = table.clone(Data.Receipts)
			table.insert(Receipts, Op.PurchaseId)
			if #Receipts > RECEIPTS_KEPT then
				table.remove(Receipts, 1) -- forget the oldest
			end

			local New = table.clone(Data)
			New.Gold += Op.Gold
			New.Receipts = Receipts
			return New
		end

		return nil
	end,
})
```

The reducer gives the gold and remembers the purchase id in `Receipts`, in one change. If the same receipt comes in again, the id is already there, so it returns `nil` and the player isn't paid twice.

That also covers the rarer cases: Roblox running the same receipt on two servers at once when the player switches servers mid-purchase, or Roblox failing to record that you granted it and sending the receipt again. Only the first one ever gets through.

`Receipts` keeps the last 1,000 ids, so it never grows without end. Roblox resends an ungranted receipt the next time the player buys something or joins, so the resend arrives long before 1,000 newer purchases could push its id out.

## Handle the receipt [#handle-the-receipt]

Roblox has two ways to handle developer product receipts: the newer `BindReceiptHandler`, and the older `ProcessReceipt` callback. Use `BindReceiptHandler` in a new game. If yours already uses `ProcessReceipt`, the second tab has it. The Ledger part is the same in both.

<Tabs items="['BindReceiptHandler', 'ProcessReceipt']">
  <Tab value="BindReceiptHandler">
    ```luau
    -- Product id to how much gold it gives.
    local PRODUCTS: { [number]: number } = {
    	[123456] = 100,
    	[123457] = 500,
    }

    type Receipt = {
    	PlayerId: number,
    	ProductId: number,
    	PurchaseId: string,
    }

    local function HandleReceipt(Receipt: Receipt): Enum.ReceiptDecision
    	local Gold = PRODUCTS[Receipt.ProductId]
    	if not Gold then
    		return Enum.ReceiptDecision.NotProcessedYet
    	end

    	local Ok, Result, Info = PlayerStore:Edit(Receipt.PlayerId, {
    		Kind = "GrantPurchase",
    		PurchaseId = Receipt.PurchaseId,
    		Gold = Gold,
    	})

    	if Ok then
    		return Enum.ReceiptDecision.Processed
    	end

    	if Result == Ledger.Reason.Refused and Info and Info.State then
    		if table.find(Info.State.Receipts, Receipt.PurchaseId) then
    			return Enum.ReceiptDecision.Processed -- granted on an earlier try
    		end
    	end

    	return Enum.ReceiptDecision.NotProcessedYet
    end

    MarketplaceService:BindReceiptHandler(Enum.ReceiptType.DeveloperProduct, HandleReceipt)
    ```
  </Tab>

  <Tab value="ProcessReceipt">
    ```luau
    -- Product id to how much gold it gives.
    local PRODUCTS: { [number]: number } = {
    	[123456] = 100,
    	[123457] = 500,
    }

    type Receipt = {
    	PlayerId: number,
    	ProductId: number,
    	PurchaseId: string,
    }

    local function ProcessReceipt(Receipt: Receipt): Enum.ProductPurchaseDecision
    	local Gold = PRODUCTS[Receipt.ProductId]
    	if not Gold then
    		return Enum.ProductPurchaseDecision.NotProcessedYet
    	end

    	local Ok, Result, Info = PlayerStore:Edit(Receipt.PlayerId, {
    		Kind = "GrantPurchase",
    		PurchaseId = Receipt.PurchaseId,
    		Gold = Gold,
    	})

    	if Ok then
    		return Enum.ProductPurchaseDecision.PurchaseGranted
    	end

    	if Result == Ledger.Reason.Refused and Info and Info.State then
    		if table.find(Info.State.Receipts, Receipt.PurchaseId) then
    			return Enum.ProductPurchaseDecision.PurchaseGranted -- granted on an earlier try
    		end
    	end

    	return Enum.ProductPurchaseDecision.NotProcessedYet
    end

    MarketplaceService.ProcessReceipt = ProcessReceipt
    ```
  </Tab>
</Tabs>

This uses `PlayerStore:Edit` instead of a session. `Edit` changes any player's data, whether they're in this server, in another server, or offline, and saves before it answers. The player may have left by the time it runs, so that matters here. If the player is in this server, their session shows the gold straight away.

What each answer does:

* **`true`**: the gold is saved. Tell Roblox it's done (`Processed`, or `PurchaseGranted` with `ProcessReceipt`).
* **`Refused`, and the id is in `Info.State.Receipts`**: an earlier try already went through. Tell Roblox it's done. `Info.State` is the player's data as Ledger saw it when it said no.
* **Anything else**, like `Unresolved` in an outage: tell Roblox it's not processed yet. Roblox calls again the next time the player buys something or joins, and the receipt list makes that safe.

## Don't show gold before it's saved [#dont-show-gold-before-its-saved]

```luau
-- Wrong: the gold shows up before it's saved
Player.leaderstats.Gold.Value += Gold
PlayerStore:Edit(Player.UserId, Op)
```

If the server crashes between those two lines, the player sees the gold and then loses it when they rejoin. If Roblox calls again, the screen can count it twice.

You don't need to touch leaderstats at all. The `Observe` from [Getting started](/docs/learn/getting-started) updates them once the gold is really in the player's data.

Next: [Trading](/docs/learn/trading)


# Reading data (https://xoifaii.github.io/docs/learn/reading-data)



For a player in this server, you already have their data: `Session:Get()`, from [Players](/docs/learn/players). This page is for everything else: a player in another server or offline, like a profile card or a friend list, or [shared data](/docs/learn/shared-data) like a guild.

## Reading a key with `Peek` [#reading-a-key-with-peek]

```luau
local function GoldOf(UserId: number): number?
	local Data, Why = PlayerStore:Peek(UserId)
	if Data then
		return Data.Gold
	end

	if Why == "Missing" then
		return 0 -- never played
	end

	return nil -- couldn't read it right now
end
```

`Peek` reads the saved data and answers it, or `nil` and a reason. It doesn't load a session, so it works on any player, wherever they are.

The data is read-only. To change it, use `Edit`, as on [Shared data](/docs/learn/shared-data).

For a player in a session somewhere, `Peek` gives what was last saved. That can be a little behind what the player sees, until their next save.

## When `Peek` says no [#when-peek-says-no]

`nil` never means "empty", so always look at the reason:

| Reason           | What it means                                                                         | What to do                                         |
| ---------------- | ------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `Missing`        | Nothing was ever saved for this key, or it was deleted.                               | Treat it as new. `Peek` never gives you `Default`. |
| `Unresolved`     | The read didn't finish, usually because the DataStore is having trouble.              | Show nothing for now and try again later.          |
| `Behind`         | A newer version of your game has saved this key, and this server is running old code. | Don't show it: this server's copy is out of date.  |
| `Busy`, `Closed` | This server can't read right now, or is shutting down.                                | Try again later, or stop.                          |

[Answers](/docs/learn/answers) has the rest.

## Reading a popular key [#reading-a-popular-key]

A plain `Peek` costs one DataStore read every time. That's fine for a profile card someone opens now and then.

For a key that many servers read all the time, like the top player on a global leaderboard or a big guild's page, give `Peek` a number of seconds:

```luau
local Data, Why = GuildStore:Peek(GuildId, 30)
```

If this server read the key in the last 30 seconds, it answers that again for free. Otherwise it reads a copy that all your servers share, which is usually under a minute old, and a few minutes on a key that hasn't changed in a while. Either way, most of these reads cost no DataStore request at all.

Only do this for keys that really are read a lot. The first server to read a key this way keeps the shared copy up to date for the next 30 minutes, which costs it 2 DataStore reads a minute. For a key that's only read now and then, that's far more than a plain `Peek` costs.

## Keeping a screen up to date with `Follow` [#keeping-a-screen-up-to-date-with-follow]

To show something that changes, like a guild's bank on a board every member can see, follow the key instead of reading it over and over:

```luau
local function WatchGuild(GuildId: string, OnChange: (Gold: number) -> ())
	return GuildStore:Follow(GuildId):Subscribe(function(Value)
		if Value == "Behind" then
			return -- a newer version of the game owns this guild
		end

		OnChange(Value.Gold)
	end)
end
```

```luau
local Connection = WatchGuild("guild-123", function(Gold)
	BankLabel.Text = `Guild bank: {Gold}`
end)

-- when the board closes
Connection:Disconnect()
```

Your function is called with the data soon after you subscribe, so you don't need a `Peek` first. Then it's called again each time the data changes. A change shows up within about 30 seconds, or up to about 4 minutes on a key that hasn't changed in a while.

A few things to know:

* Your function can't yield. If you need to wait for something, start it with `task.spawn`.
* It's never called for a key with no saved data.
* `Follow` doesn't stop on its own. Call `Disconnect` when nobody is looking any more.
* Following the same key twice in one server shares the work, so it costs no more.

## Counters and limited items [#counters-and-limited-items]

Global counters and limited-item stock have their own reads. See [Global counters](/docs/learn/global-counters) and [Limited items](/docs/learn/limited-items).

Next: [Limited items](/docs/learn/limited-items)


# Shared data (https://xoifaii.github.io/docs/learn/shared-data)



So far every store has been keyed by player. Some data belongs to a group instead: a guild's bank, a clan's message, a server-wide shop. For those, use a store with `Keys = "String"` and pick your own keys, like a guild id.

## A guild store [#a-guild-store]

```luau
export type GuildData = {
	Gold: number,
	Message: string,
}

type GuildOps = {
	Deposit: { Amount: number },
	Withdraw: { Amount: number },
	SetMessage: { Message: string },
}

local GuildStore = Ledger.New<<GuildData, GuildOps>>({
	Name = "Guilds",
	Keys = "String",
	Default = { Gold = 0, Message = "" },
	MustExist = false,
	Erasable = true,
	Reducer = function(Data, Op)
		if Op.Kind == "Deposit" then
			local New = table.clone(Data)
			New.Gold += Op.Amount
			return New
		end

		if Op.Kind == "Withdraw" then
			if Data.Gold < Op.Amount then
				return nil -- not enough in the bank
			end

			local New = table.clone(Data)
			New.Gold -= Op.Amount
			return New
		end

		if Op.Kind == "SetMessage" then
			local New = table.clone(Data)
			New.Message = Op.Message
			return New
		end

		return nil
	end,
})
```

It works like the player store, with two differences:

* Keys are strings you choose, up to 50 characters. Here it's the guild's id.
* There are no sessions. Nobody "loads" a guild. You change it with `Edit`, from any server.

## Changing it with `Edit` [#changing-it-with-edit]

```luau
local function SetMessage(GuildId: string, Message: string): boolean
	local Ok = GuildStore:Edit(GuildId, { Kind = "SetMessage", Message = Message })
	return Ok
end
```

`Edit` runs your reducer on the guild's saved data and saves the result before it answers, like `Commit`. Any server can do this at the same time as any other, and no change is ever lost: each one is applied on top of the last.

`Edit` gives the same answers as every other call. See [Answers](/docs/learn/answers).

## Moving gold into the bank [#moving-gold-into-the-bank]

Moving gold from a player into the guild is a [trade](/docs/learn/trading) between the player and the guild, so both sides happen or neither does:

```luau
local function Deposit(Player: Player, GuildId: string, Amount: number): boolean
	local Session = PlayerStore:Get(Player)
	if Session then
		Session:Flush()
	end

	local Ok = Ledger.Tx({
		PlayerStore:Leg(Player.UserId, { Kind = "SpendGold", Amount = Amount }),
		GuildStore:Leg(GuildId, { Kind = "Deposit", Amount = Amount }),
	})

	local SessionAfter = PlayerStore:Get(Player)
	if SessionAfter then
		SessionAfter:Refresh()
	end

	return Ok
end
```

Withdrawing is the same with the ops swapped: `Withdraw` from the guild and `AddGold` to the player.

## Keep shared data small [#keep-shared-data-small]

Many servers can write to the same guild, but one key can only take so many writes a minute, and bigger data means fewer. As a rough guide, a key holding 1 MB takes about 4 changes a minute, and a key holding 10 KB takes hundreds.

So keep shared data small, and split it up if it grows. Give each guild its own key, rather than one giant key for every guild. For a number every server bumps all the time, like total kills across the game, use [Global counters](/docs/learn/global-counters) instead.

## Gifts to players in other servers [#gifts-to-players-in-other-servers]

`Edit` also works on a player store, by UserId. The player can be in this server, in another server, or offline:

```luau
local REFRESH_TOPIC = "RefreshPlayer"

-- Sends gold to any player, wherever they are.
local function SendGift(UserId: number, Amount: number): boolean
	local Ok = PlayerStore:Edit(UserId, { Kind = "AddGold", Amount = Amount })
	if not Ok then
		return false
	end

	-- Tell the server they're in to show it now. If this fails, they still see it within about 2 minutes.
	pcall(MessagingService.PublishAsync, MessagingService, REFRESH_TOPIC, UserId)
	return true
end
```

If the player is in this server, they see the gold straight away. If they're offline, they see it next time they join.

If they're in another server, that server finds out on its own within about 2 minutes. The `PublishAsync` line makes it sooner: it tells every server to refresh that player, and the server they're in does. Put this in a Script so every server listens:

```luau
local function OnRefreshMessage(Message: { Data: unknown })
	if type(Message.Data) ~= "number" then
		return
	end

	local Player = Players:GetPlayerByUserId(Message.Data)
	if not Player then
		return -- not in this server
	end

	local Session = PlayerStore:Get(Player)
	if not Session then
		return
	end

	Session:Refresh()
end

pcall(MessagingService.SubscribeAsync, MessagingService, Gifts.REFRESH_TOPIC, OnRefreshMessage)
```

The message is only a nudge. If it's lost, nothing breaks: the gold is already saved, and the player sees it a little later.

Next: [Reading data](/docs/learn/reading-data)


# Shutdown and testing (https://xoifaii.github.io/docs/learn/shutdown-and-testing)



## When a server shuts down [#when-a-server-shuts-down]

You don't need to do anything. When a server shuts down, Ledger saves every player's waiting changes before it closes. You don't need `game:BindToClose` for your data.

The only thing Ledger can't save is something it doesn't know about yet. Say players earn gold during a round, and you keep it in a table until the round ends. If the server shuts down mid-round, that table is lost. Use `Ledger.BeforeClose` to hand it to Ledger first:

```luau
-- Gold each player has earned this round, paid out when the round ends.
local RoundGold: { [Player]: number } = {}

local function PayOut(Player: Player)
	local Gold = RoundGold[Player]
	RoundGold[Player] = nil
	if not Gold or Gold <= 0 then
		return
	end

	local Session = PlayerStore:Get(Player)
	if not Session then
		return
	end

	Session:Apply({ Kind = "AddGold", Amount = Gold })
end

-- If the server shuts down mid-round, pay everyone what they have so far.
Ledger.BeforeClose(function()
	for _, Player in Players:GetPlayers() do
		PayOut(Player)
	end
end)
```

`BeforeClose` runs your function at the start of the shutdown, before Ledger saves. Call it once when the server starts. Keep the function quick: it gets at most 5 seconds.

Don't use `game:BindToClose` for this. By the time yours runs, Ledger is already closing, and every new call answers `Closed`.

The simplest fix is not to need this at all: `Apply` each change as it happens, instead of keeping it in a table.

## Testing the reducer [#testing-the-reducer]

The reducer is just a function, so you can test it without any DataStore at all. Move it out of `Ledger.New` into a local function, and return it from `Stores` too:

```luau
local function Reduce(Data: PlayerData, Op: Ledger.Op<PlayerOps>): PlayerData?
	if Op.Kind == "AddGold" then
		return { Gold = Data.Gold + Op.Amount }
	end

	if Op.Kind == "SpendGold" then
		if Data.Gold < Op.Amount then
			return nil -- not enough gold
		end

		return { Gold = Data.Gold - Op.Amount }
	end

	return nil
end

local PlayerStore = Ledger.New<<PlayerData, PlayerOps>>({
	-- ...
	Reducer = Reduce,
})

return {
	PlayerStore = PlayerStore,
	Reduce = Reduce,
}
```

Then a Script in `ServerScriptService` can check it:

```luau
--!strict
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Stores = require(ServerStorage.Stores)

if not RunService:IsStudio() then
	return
end

local Rich = { Gold = 100 }

assert(Stores.Reduce(Rich, { Kind = "SpendGold", Amount = 500 }) == nil, "spending too much is refused")

local After = Stores.Reduce(Rich, { Kind = "SpendGold", Amount = 40 })
assert(After and After.Gold == 60, "spending 40 of 100 leaves 60")

print("Reducer tests passed")
```

`Ledger.Op<PlayerOps>` is the type of any op from `PlayerOps`, the same one `Ledger.New` gives the reducer.

## Testing without real DataStores [#testing-without-real-datastores]

Ledger can run on the [Mock](https://github.com/XoifaiI/mock) package instead of the real DataStores and MemoryStore. It keeps everything in memory, with the same limits as the real services, so nothing your tests do touches your players' data.

Install it with Wally (`Mock = "xoifaii/mock@1.0.0"`), or put `Mock.rbxm` in your game. Then give a store the mock:

```luau
local Mock = require(ReplicatedStorage.Packages.Mock)

local FakeServices = Mock.New({ Players = 10 })

local PlayerStore = Ledger.New<<PlayerData, PlayerOps>>({
	Name = "PlayerData",
	Keys = "Player",
	Default = { Gold = 0 },
	MustExist = false,
	Erasable = true,
	Reducer = Reduce,
	Mock = FakeServices,
})
```

The mock is for the whole server, because Ledger's own bookkeeping shares the services with your stores:

* Every store runs on it, including ones that leave `Mock` out.
* Giving a different mock to another store throws.
* Give it before Ledger saves or loads anything. A mock given after Ledger's first request throws, so a store never switches halfway.

`Players` sets how many players the mock's request budget is sized for. `Mock.New({ Throttled = false })` turns its limits off.

## What Studio checks for you [#what-studio-checks-for-you]

In Studio, Ledger watches your reducer more closely than on a live server:

| Studio warns when                                             | Fix                                                                                                                         |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| The reducer changes the `Data` or `Op` it was given           | Clone the table and change the copy, as in [Bigger reducers](/docs/learn/bigger-reducers). In Studio, changing them throws. |
| The reducer gives a different answer for the same data and op | Don't use `os.time()`, `math.random()` or anything else that changes between calls. Put those in the op instead.            |
| The reducer doesn't return `nil` for a kind it doesn't know   | End the reducer with `return nil`.                                                                                          |

These checks only run in Studio, but the rules hold everywhere. A reducer that breaks them on a live server can give players the wrong data.

Next: [Common mistakes](/docs/learn/common-mistakes)


# Trading (https://xoifaii.github.io/docs/learn/trading)



A trade changes two players' data at once. If you do that with two separate calls and the server crashes in between, one player can lose their item without getting paid. `Ledger.Tx` changes both together: either both changes happen, or neither does.

## The ops [#the-ops]

Each player in the trade gets one op. Here the seller gives up an item and gets gold, and the buyer does the opposite:

```luau
type PlayerOps = {
	SellItem: { Item: string, Price: number },
	BuyItem: { Item: string, Price: number },
}

	Reducer = function(Data, Op)
		if Op.Kind == "SellItem" then
			local Count = Data.Inventory[Op.Item]
			if not Count then
				return nil -- they don't have it
			end

			local Inventory = table.clone(Data.Inventory)
			if Count > 1 then
				Inventory[Op.Item] = Count - 1
			else
				Inventory[Op.Item] = nil
			end

			local New = table.clone(Data)
			New.Gold += Op.Price
			New.Inventory = Inventory
			return New
		end

		if Op.Kind == "BuyItem" then
			if Data.Gold < Op.Price then
				return nil -- not enough gold
			end

			local Inventory = table.clone(Data.Inventory)
			Inventory[Op.Item] = (Inventory[Op.Item] or 0) + 1

			local New = table.clone(Data)
			New.Gold -= Op.Price
			New.Inventory = Inventory
			return New
		end

		return nil
	end,
```

These are normal ops with normal reducer rules. Each side checks its own player: the seller must have the item, and the buyer must have the gold.

## The trade [#the-trade]

Put this in a ModuleScript, `ServerStorage.Trading`:

```luau
-- Saves anything waiting for this player, if they're in this server.
local function FlushIfHere(UserId: number)
	local Player = Players:GetPlayerByUserId(UserId)
	if not Player then
		return
	end

	local Session = PlayerStore:Get(Player)
	if not Session then
		return
	end

	Session:Flush()
end

-- Shows this player their latest saved data, if they're in this server.
local function RefreshIfHere(UserId: number)
	local Player = Players:GetPlayerByUserId(UserId)
	if not Player then
		return
	end

	local Session = PlayerStore:Get(Player)
	if not Session then
		return
	end

	Session:Refresh()
end

local function Trade(SellerId: number, BuyerId: number, Item: string, Price: number): boolean
	FlushIfHere(SellerId)
	FlushIfHere(BuyerId)

	local Ok, Result, Info = Ledger.Tx({
		PlayerStore:Leg(SellerId, { Kind = "SellItem", Item = Item, Price = Price }),
		PlayerStore:Leg(BuyerId, { Kind = "BuyItem", Item = Item, Price = Price }),
	})

	if Result == Ledger.Reason.Unresolved and Info and Info.Outcome then
		Ok, Result = Info.Outcome:Wait()
	end

	RefreshIfHere(SellerId)
	RefreshIfHere(BuyerId)

	if Ok then
		return true
	end

	if Result == Ledger.Reason.Refused and Info and Info.Key then
		local SellerSaidNo = tostring(Info.Key.Key) == tostring(SellerId)
		if SellerSaidNo then
			print("The seller doesn't have a", Item)
			return false
		end

		print("The buyer can't afford it")
		return false
	end

	warn("Trade failed:", Result)
	return false
end
```

`Trade` takes UserIds, not players. A trade doesn't need either player to be in this server, or online at all: the buyer could be in another server, and the seller could be offline selling from a market listing. Ledger changes their saved data either way.

`PlayerStore:Leg(UserId, Op)` describes one player's side of the trade. `Ledger.Tx` takes the list and applies every side, or none.

A two-player trade costs 2 DataStore requests.

## Players in this server [#players-in-this-server]

A trade works on the players' saved data, not on what their sessions are showing. So for a player who's in this server:

* **Before:** `Flush` their session, so anything `Apply` has waiting is saved and the trade sees it.
* **After:** `Refresh` their session, so they see the trade straight away.

`FlushIfHere` and `RefreshIfHere` do that, and do nothing for a player who isn't here. They look the session up fresh each time, because a player can leave while the trade runs.

A `Flush` costs a DataStore request when the player has changes waiting, and nothing when they don't. If your game trades a lot, that adds up. You can skip it, but then a change `Apply` still had waiting can be undone at the next save if the trade already spent the same gold.

A player in another server sees the trade within about 2 minutes. To show it sooner, send a message and refresh them there, like the [gift example](/docs/learn/shared-data#gifts-to-players-in-other-servers). An offline player sees it next time they join.

If that other server still has `Apply` changes waiting for the player, they're checked again against the traded data when they save. So a player can't spend the same gold in a trade and in another server at once.

## Answers [#answers]

| Answer       | What it means                                                                                                                                                                                            |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `true`       | Both sides happened.                                                                                                                                                                                     |
| `Refused`    | One side's reducer said no. Nothing happened to either player. `Info.Key.Key` is the UserId of the player whose side said no.                                                                            |
| `Unresolved` | Ledger doesn't know yet, and keeps going until it does. When it finishes, either both sides happened or neither did. Wait on `Info.Outcome` if you want to know. In a long outage that can take a while. |
| `Spent`      | The trade stopped without going through, for a reason that isn't your rules. Nothing happened. It's safe to try again.                                                                                   |

Everything else means the same as on [Answers](/docs/learn/answers), and nothing happened to either player.

## Not just players [#not-just-players]

A leg can be any key in any store, so the same code moves gold from a player into a [guild bank](/docs/learn/shared-data), or between three players at once. Each key can only be in a trade once.

Next: [Shared data](/docs/learn/shared-data)


# Your data (https://xoifaii.github.io/docs/learn/your-data)



On the last page the player only had gold. Let's give them an inventory too, and a way to buy things. Here's the `Stores` module again with both:

```luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ledger = require(ReplicatedStorage.Ledger)

export type PlayerData = {
	Gold: number,
	Inventory: { [string]: number },
}

type PlayerOps = {
	AddGold: { Amount: number },
	SpendGold: { Amount: number },
	BuyItem: { Item: string, Price: number },
}

local PlayerStore = Ledger.New<<PlayerData, PlayerOps>>({
	Name = "PlayerData",
	Keys = "Player",
	Default = { Gold = 0, Inventory = {} },
	MustExist = false,
	Erasable = true,
	Reducer = function(Data, Op)
		if Op.Kind == "AddGold" then
			local New = table.clone(Data)
			New.Gold += Op.Amount
			return New
		end

		if Op.Kind == "SpendGold" then
			if Data.Gold < Op.Amount then
				return nil -- not enough gold
			end

			local New = table.clone(Data)
			New.Gold -= Op.Amount
			return New
		end

		if Op.Kind == "BuyItem" then
			if Data.Gold < Op.Price then
				return nil -- not enough gold
			end

			local Inventory = table.clone(Data.Inventory)
			Inventory[Op.Item] = (Inventory[Op.Item] or 0) + 1

			local New = table.clone(Data)
			New.Gold -= Op.Price
			New.Inventory = Inventory
			return New
		end

		return nil
	end,
})

return {
	PlayerStore = PlayerStore,
}
```

## What you can save [#what-you-can-save]

`PlayerData` is the shape of one player's data, and `Default` is what a new player starts with.

You can save numbers, strings, booleans, and tables of those, up to about 4 MB per player. The same rules as DataStores apply: no Instances, Vector3s or functions, no holes in arrays, and a table can't mix array and string keys.

Every field your data will ever have needs to be in `Default`. If a field has no value at the start, give it an empty one, like `0`, `""` or `{}`. A reducer that sets a field `Default` doesn't have is refused, and Ledger warns you in the output.

## Ops [#ops]

An op is one change to a player's data. `PlayerOps` lists every kind of op, and what each one carries:

```luau
type PlayerOps = {
	AddGold: { Amount: number },
	SpendGold: { Amount: number },
	BuyItem: { Item: string, Price: number },
}
```

When you send one, you give its `Kind` and its fields:

```luau
Session:Apply({ Kind = "BuyItem", Item = "Sword", Price = 50 })
```

Because the ops are typed, a typo in a kind or a missing field shows up in Studio's script analysis before you ever run the game.

## The reducer [#the-reducer]

The reducer is the only place your data changes. It gets the player's current data and an op, and returns one of two things:

* **The new data**, if the op is allowed.
* **`nil`**, if it isn't. The op does nothing, and the call that sent it gets back `false`.

Notice that each branch starts with `table.clone(Data)` and changes the copy. That's on purpose, because of the rules below. If your reducer grows past a handful of ops, [Bigger reducers](/docs/learn/bigger-reducers) shows how to keep it short.

## Reducer rules [#reducer-rules]

Ledger may run your reducer more than once for the same op, so it has to give the same answer every time:

* **Never change `Data` or `Op` directly.** Copy the table you're changing with `table.clone`, like `Inventory` above, and return the copy.
* **Return every field.** Cloning `Data` first takes care of that.
* **No randomness and no clock.** Don't use `math.random`, `os.time` or `tick()` in a reducer. Work it out in your script and put the result in the op. For a loot drop, roll the item in your script and send `{ Kind = "AddItem", Item = Rolled }`.
* **No waiting, no Ledger calls, nothing outside the data.** Don't fire remotes, print, or change parts from a reducer. Do that in your script after the call answers, or in `Observe`.
* **Return `nil` for kinds you don't know.** That's the `return nil` at the bottom.

If your reducer errors, Ledger treats it as `nil` and the op is refused. It won't print the error, so wrap risky code in `pcall` while you debug.

Studio helps you catch broken rules. There, your reducer runs three times per op and Ledger warns you if the answers differ. `Data` and `Op` are also read-only in Studio, so a reducer that changes them directly gets every op refused.

## Using it [#using-it]

Here's a shop that sells through the new op. The price comes from the server, never from the client:

```luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Stores = require(ServerStorage.Stores)

local PlayerStore = Stores.PlayerStore

local BuyItemEvent = ReplicatedStorage:WaitForChild("BuyItem") :: RemoteEvent

local PRICES: { [string]: number } = {
	Sword = 50,
	Shield = 80,
}

local function OnBuyItem(Player: Player, Item: unknown)
	if type(Item) ~= "string" then
		return
	end

	local Price = PRICES[Item]
	if not Price then
		return -- not something we sell
	end

	local Session = PlayerStore:Get(Player)
	if not Session then
		return -- still loading
	end

	local Ok = Session:Apply({ Kind = "BuyItem", Item = Item, Price = Price })
	if not Ok then
		print(Player.Name, "can't afford a", Item)
	end
end

BuyItemEvent.OnServerEvent:Connect(OnBuyItem)
```

If the player can't afford it, the reducer returns `nil` and `Apply` gives back `false`. Their gold and inventory stay as they were.

## Balances: let Ledger handle gold [#balances-let-ledger-handle-gold]

Most games have a few numbers that only ever go up or down by an amount: gold, gems, coins. Instead of writing reducer code for those, you can tell Ledger which ops add and which take away, and it handles them for you:

```luau
local PlayerStore = Ledger.New<<PlayerData, PlayerOps>>({
	Name = "PlayerData",
	Keys = "Player",
	Default = { Gold = 0, Inventory = {} },
	MustExist = false,
	Erasable = true,
	Balances = {
		Gold = { Credit = "AddGold", Debit = "SpendGold" },
	},
	Reducer = function(Data, Op)
		-- AddGold and SpendGold never get here: Ledger applies them.
		-- ... your other ops, like BuyItem
		return nil
	end,
})
```

* **`Credit`** ops add their `Amount&#x60; to the field. &#x2A;*`Debit`** ops take it away.
* A debit that would take the field below 0 is refused, like the "not enough gold" check you'd write yourself.
* `Amount` must be a whole number above 0. Anything else throws when you send the op.
* Keep the ops in `PlayerOps` as usual, with `{ Amount: number }`, so they stay type checked.

Plain ops can still change `Gold` too, like `BuyItem` taking the price. Ledger's limits don't apply to those, so the reducer checks them itself, as before.

### Limits [#limits]

Give the field a `Min` or a `Max` to change the limits. Here, gold can never go above a million:

```luau
	Balances = {
		Gold = { Credit = "AddGold", Debit = "SpendGold", Max = 1000000 },
	},
```

An `AddGold` that would pass the `Max` is refused.

You can list several ops, and give one op limits of its own by writing it as a table. Here a `Refund` always goes through, even above the cap:

```luau
local NO_LIMIT = 2 ^ 53 - 1

	Balances = {
		Gold = {
			Credit = { "AddGold", { Kind = "Refund", Max = NO_LIMIT } },
			Debit = "SpendGold",
			Max = 1000000,
		},
	},
```

`Min` and `Max` are limits on the field, not on one op: `Max = 1000000` means the gold can't go above a million, not that one op can't add more than a million.

### Why bother [#why-bother]

For one player's gold, a reducer works just as well. Balances start to matter in [trades](/docs/learn/trading): while a trade is in progress, it holds the player's data until it finishes, and their other changes wait. A gold op in a trade doesn't hold anything. It only sets the amount aside, so the player can keep earning and spending meanwhile. Shops, auctions and guild banks that many servers trade with at once rely on that, as in [Auctions and markets](/docs/guides/auctions-and-markets).

## `MustExist` and `Erasable` [#mustexist-and-erasable]

Every store has to say these two:

| Option      | `true`                                                                                    | `false`                                                                                    |
| ----------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `MustExist` | The data must already exist. Loading or changing a key with no data fails with `Missing`. | Data that doesn't exist yet starts from `Default`, and is saved the first time it changes. |
| `Erasable`  | You can delete a key's data for good with `Erase`, for example for a GDPR request.        | `Erase` isn't allowed.                                                                     |

For player data, use `MustExist = false` and `Erasable = true`. Pick `Erasable` before your game goes live: turning it on later takes extra care, covered in [Deleting data](/docs/learn/deleting-data).

Next: [Players](/docs/learn/players)


# Ledger (https://xoifaii.github.io/docs/reference/ledger)



Look up any function on `Ledger` itself.

```luau
local Name = Ledger.Id() -- a fresh name for Erase and Reset
if Name == nil then
	return false -- Busy: try again later
end
local Ok, Result = Bank:Erase(Key, { Id = Name })
```

Ledger runs on the server only. On a client, only `Ledger.Reason` works.

| Function                          | What it does                                                                                                                                                              |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Ledger.New<<Data, Ops>>(Config)` | Makes a [store](/docs/reference/store). Make each store once, in a `Stores` module, and require it from every script. See [Getting started](/docs/learn/getting-started). |
| `Ledger.Id()`                     | Makes a name for `Erase` and `Reset`.                                                                                                                                     |
| `Ledger.Now()`                    | Ledger's clock in whole seconds. Use it for every `IdAt`.                                                                                                                 |
| `Ledger.Tx(Legs, Options?)`       | Changes several players or keys: all or none.                                                                                                                             |
| `Ledger.BeforeClose(Fn)`          | Runs `Fn` first when the server shuts down.                                                                                                                               |
| `Ledger.CloseAll()`               | Starts the shutdown now. Yields until it ends.                                                                                                                            |
| `Ledger.Reason`                   | The names of all the answers, such as `Ledger.Reason.Busy`.                                                                                                               |

## New [#new]

Takes a config table and returns the store. `Data` is the shape of one key's data, and `Ops` is the type that lists every kind of op and what it carries. Sending an op that isn't in `Ops` is a type error.

| Setting                               | What it is                                                                                                                                                                                                                                        |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Name`                                | The store's name. Never change it once players have data.                                                                                                                                                                                         |
| `Keys`                                | `"Player"` for player data, `"String"` for keys you choose, like a guild id.                                                                                                                                                                      |
| `Default`                             | What a new key starts with. Every field the data will ever have.                                                                                                                                                                                  |
| `MustExist`                           | `true`: a key with no saved data answers `Missing`. `false`: it starts from `Default`.                                                                                                                                                            |
| `Erasable`                            | `true`: `Erase` works on this store.                                                                                                                                                                                                              |
| `Reducer`                             | Your function that applies an op. See [Your data](/docs/learn/your-data).                                                                                                                                                                         |
| `Balances`                            | Number fields Ledger changes for you. See below.                                                                                                                                                                                                  |
| `Migrations`                          | Changes to the data's shape. See [Changing your data](/docs/learn/changing-data).                                                                                                                                                                 |
| `Totals`                              | Counters. See [Global counters](/docs/learn/global-counters).                                                                                                                                                                                     |
| `Quantities`                          | Limited stock. See [Limited items](/docs/learn/limited-items).                                                                                                                                                                                    |
| `Schema`                              | A function that checks every state the reducer returns. Answer `false` and a message to refuse it.                                                                                                                                                |
| `OnLoadFailed`, `Kick`, `KickMessage` | What happens when a player's data won't load. Player stores only. See [Players](/docs/learn/players).                                                                                                                                             |
| `Mock`                                | A mock DataStore and MemoryStore to run on instead of the real ones, from the [Mock](https://github.com/XoifaiI/mock) package. One mock per server. See [Shutdown and testing](/docs/learn/shutdown-and-testing#testing-without-real-datastores). |

The defaults below are right for almost every game. Change them only if you know you need to.

| Setting            | Default | What it is                                                                                                                                       |
| ------------------ | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `SaveInterval`     | 30      | Seconds between a session's saves, when it has changes waiting.                                                                                  |
| `IdleReadInterval` | 120     | Seconds between a session's reads, when it has nothing waiting. This is how soon a player sees changes made from other servers.                  |
| `HoldMax`          | 900     | The longest a `Quantity:Hold` can last, in seconds.                                                                                              |
| `OrphanAge`        | 86,400  | Seconds before Ledger gives up on a trade whose deciding key never appeared, and hands its amounts back.                                         |
| `CutWindow`        | 360     | Seconds a key remembers a `Reset` or `Erase` name, so a repeat of it is safe.                                                                    |
| `Windows`          | 180     | Per op kind, `{ Timed = seconds, Untimed = seconds }`: how long a key remembers a named op of that kind. See [Once only](/docs/learn/once-only). |
| `LegLimit`         | none    | The most parts a `Tx` touching this store may have.                                                                                              |

### Balances [#balances]

```luau
Balances = {
	Gold = {
		Credit = { "AddGold", { Kind = "Refund", Max = NO_LIMIT } },
		Debit = "SpendGold",
		Max = 1000000,
	},
},
```

Each entry is a number field in `Default`. Ledger applies its ops itself, so your reducer never sees them.

| Option       | What it is                                                                                  |
| ------------ | ------------------------------------------------------------------------------------------- |
| `Credit`     | The op kinds that add `Amount` to the field: one name, or a list.                           |
| `Debit`      | The op kinds that take `Amount` away.                                                       |
| `Min`        | The field can't go below this. Default 0.                                                   |
| `Max`        | The field can't go above this. Default: no limit.                                           |
| `Arithmetic` | For amounts that aren't plain whole numbers, like very big numbers. Leave it out otherwise. |

A kind written as a table, `{ Kind = "Refund", Min = ..., Max = ... }`, uses its own `Min` or `Max` in place of the field's. An op of a balance kind carries `Amount`, a whole number from 1 up. Each kind can only be named once, and not with one of Ledger's own names (`Open`, `Take`, `Credit`, `Close`, `Hold`, `Confirm`, `Release`, `Bump`, `Cut`, or one starting `Debit:`). See [Your data](/docs/learn/your-data#balances-let-ledger-handle-gold).

## Id and Now [#id-and-now]

`Ledger.Id()` answers a name, or `nil, Busy` if the server cannot make one yet (for example at startup in an outage). Ask again.

Make the name just before you use it. A server answers `Expired` for its own name once it is 6 minutes old.

`Ledger.Now()` counts seconds since 1 January 2026. Take it once per op, and use the same value on every retry. See [Making a change happen once](/docs/learn/once-only).

## Tx [#tx]

```luau
local Legs = {
	PlayerStore:Leg(From, { Kind = "SpendGold", Amount = Amount }),
	PlayerStore:Leg(To, { Kind = "AddGold", Amount = Amount }),
}
-- Make the name once. Send the same Options again after Busy or Unresolved.
local Options: Ledger.TxOptions = { Id = "pay:" .. HttpService:GenerateGUID(false), IdAt = Ledger.Now() }
local Ok, Why = Ledger.Tx(Legs, Options)
```

Each player or key in the trade is one entry, `{ Store, Key, Op, MustExist? }`. `Store:Leg` builds one with the op type-checked. Use at least 2 entries, on different keys. The entries can be in different stores, such as a player store and a guild store. `Options` is `{ Id, IdAt }`, both or neither. `Id` is a string you make, never a `Ledger.Id()` name.

| Answer              | Means                                                                                  | Do                                                                         |
| ------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `true`              | Every change happened, once.                                                           | Done.                                                                      |
| `Refused` or `Full` | A rule said no. Nothing changed. `Info.Key` names the key.                             | Tell the player. Do not resend.                                            |
| `Spent`             | The name was used with other terms, or the transaction was cancelled. Nothing changed. | Use a new name.                                                            |
| `Missing`           | A key that must exist is not there.                                                    | Check `Info.Key`.                                                          |
| `Behind`            | A newer build owns a key.                                                              | Stop writing it from this build.                                           |
| `Busy` or `NoRoom`  | Nothing was sent.                                                                      | Send the same name again later.                                            |
| `Unresolved`        | Not known yet. All the changes or none will happen.                                    | Send the same name, `IdAt` and list again. `Info.Outcome` tells you later. |

More in [Answers](/docs/learn/answers) and [Trading](/docs/learn/trading).

## BeforeClose and CloseAll [#beforeclose-and-closeall]

```luau
Ledger.BeforeClose(function()
	-- runs first when the server shuts down, for up to 5 seconds
end)
```

Roblox already starts the shutdown for you. Call `CloseAll` only to end it sooner. `BeforeClose` throws if the server is already closing. See [Shutdown and testing](/docs/learn/shutdown-and-testing).

## Reason [#reason]

`Ledger.Reason.Refused == "Refused"`. Use it to avoid mistyping an answer. There are 15 answers; see [Answers](/docs/learn/answers).

Next: [Store](/docs/reference/store)


# Observers and futures (https://xoifaii.github.io/docs/reference/observers)



Watch a key for changes, and wait for the result of an `Unresolved` write.

```luau
local Connection = Bank:Follow(Key)
	:Changed() -- skip a value equal to the one before
	:Subscribe(function(State)
		if State == "Behind" then
			warn("a newer build owns this key")
		else
			print("gold is now", State.Gold)
		end
	end)

Connection:Disconnect()
```

An observer sends you values over time. `Session:Observe`, `Session:ObserveFates`, `Store:Follow` and `Store:Stale` each return one.

A listener runs at once, in the thread that caused the value, and must not wait. An error in a listener is caught and printed as a warning.

## Observer [#observer]

| Method                | What it does                                                                                           |
| --------------------- | ------------------------------------------------------------------------------------------------------ |
| `Subscribe(Listener)` | Calls `Listener` for each value. Returns a `Connection`.                                               |
| `Map(Transform)`      | A new observer of the transformed values.                                                              |
| `Filter(Predicate)`   | A new observer that only passes values the predicate accepts.                                          |
| `Changed(Equals?)`    | A new observer that skips a value equal to the last one. Use it to drop a repeated `"Behind"`.         |
| `Use(Middleware)`     | Map and filter in one step: call `Emit` to pass a value on.                                            |
| `Destroy()`           | Ends the observer and disconnects its listeners. Destroying a derived observer ends only its own link. |

```luau
Bank:Follow(Key)
	:Filter(function(State)
		return State ~= "Behind"
	end)
	:Map(function(State)
		return if State == "Behind" then 0 else State.Gold
	end)
	:Subscribe(function(Gold)
		print("gold:", Gold)
	end)
```

### Follow [#follow]

`Store:Follow(Key)` emits the data when it changes, and the text `"Behind"` while a newer build owns the key and has saved its copy. It does nothing until the first `Subscribe`, and the first subscriber gets the current data soon after. Failed reads and absent keys emit nothing. Following one key twice in a server shares the work. See [Reading data](/docs/learn/reading-data).

## Connection [#connection]

|                |                                                                                         |
| -------------- | --------------------------------------------------------------------------------------- |
| `Connected`    | `true` until you disconnect. It stays `true` after a session ends; no more values come. |
| `Disconnect()` | Stops the listener.                                                                     |

## Future [#future]

`Info.Outcome` is a future. It is known once, when Ledger learns what happened to an `Unresolved` write.

```luau
local Ok, Why, Info = Bank:Edit(Key, { Kind = "AddGold", Amount = Amount })
if Why == "Unresolved" and Info and Info.Outcome then
	local Outcome = Info.Outcome
	task.spawn(function() -- Wait yields
		local Landed, Reason = Outcome:Wait(120)
		print(Landed, Reason)
	end)
end
```

| Method            | What it does                                                                                                                                                                            |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Wait(Timeout?)`  | Waits and returns `Landed, Reason?`. `Landed` is `true` if the op took effect, or `false` with the reason. Returns nothing if the timeout comes first; the answer may still come later. |
| `Happened(Wait?)` | `true` once the answer is known. With `Wait` it waits until then.                                                                                                                       |

`Reason` is a definite answer the server heard later, or `Unresolved` if this server stopped trying. It is never `Closed`. A future is lost if the server restarts. Sending the same name again is the only way across servers. See [Making a change happen once](/docs/learn/once-only).

Next: [Types](/docs/reference/types)


# Quantity (https://xoifaii.github.io/docs/reference/quantity)



Sell a limited item from many servers at once.

```luau
local Sword = Shop:Quantity("Sword")

local Options: Ledger.TakeOptions = { Id = "sword:" .. HttpService:GenerateGUID(false), IdAt = Ledger.Now() }
local Ok, Result = Sword:Take(1, Options)
```

A quantity is a stock of units split over parts, so many servers can sell without waiting for each other. Declare it in the store's `Quantities`, then get it with `Store:Quantity(Name)`. See [Limited items](/docs/learn/limited-items).

```luau
Quantities = {
	Sword = { Parts = 2, Mode = "Final", Stock = 100 },
	Pot = { Parts = 2, Mode = "Open" },
}
```

| Setting    | Means                                                                                                      |
| ---------- | ---------------------------------------------------------------------------------------------------------- |
| `Parts`    | 1 to 64. More parts let more servers sell at once.                                                         |
| `Mode`     | `"Final"`: a fixed stock that never refills. `"Open"`: a pot you can add to.                               |
| `Stock`    | Final only, and a Final quantity must declare it. Open leaves it out.                                      |
| `Serials`  | Final only. `{ First, Count }`: each unit has a number. `Count` must equal `Stock`.                        |
| `Proceeds` | Up to 4 [balance fields](/docs/reference/ledger#balances) of the store that a take's `Price` is paid into. |
| `Closed`   | `true` makes `Open` throw in this build. A restock is a new quantity.                                      |

Do not change `Parts`, `Mode`, `Stock`, `Serials` or `Proceeds` of a live quantity. Declare a new name instead.

## Calls [#calls]

| Call                            | What it does                                       |
| ------------------------------- | -------------------------------------------------- |
| `Open()`                        | Creates the parts. Once ever. Never after `Close`. |
| `Take(Count, Options?)`         | Sells units.                                       |
| `Hold(Count, Seconds)`          | Keeps units for a buyer for up to 900 s.           |
| `Confirm(Hold, Options?)`       | Turns a hold into a sale.                          |
| `Release(Hold)`                 | Gives a hold back.                                 |
| `Total(MaxAge?)`                | `{ Sold, Free, Held }`.                            |
| `Close()`                       | Ends the sale and removes empty parts.             |
| `Deposit`, `Gather`, `Withdraw` | Move units or proceeds. See below.                 |

### Take [#take]

`Options` is `{ Price?, Id?, IdAt?, Legs? }`. Give `Id` and `IdAt` together: a named take is safe to resend. `Legs` are changes to other keys, such as the buyer's coins. The take and those changes happen together. `Price` adds to the quantity's proceeds and takes nothing from the buyer, so charge the buyer in `Legs`.

On `true`, `Result` is `{ Part, Value }`. `Value` is the serial number, or `nil` without `Serials`.

| Answer              | Means                                                                                          | Do                                                                                                            |
| ------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `true`              | Sold.                                                                                          | Done.                                                                                                         |
| `SoldOut`           | A Final quantity has none left, for good.                                                      | Stop selling it.                                                                                              |
| `Short`             | Too few free units right now. `Info.ShortReason` is `"Free"`, `"Held"`, `"Holds"` or `"Gone"`. | Tell the player. A named take needs a new name to try again.                                                  |
| `Missing`           | Not opened yet, closed and removed, or a key in `Legs` is missing.                             | `Open()` once if it was never opened.                                                                         |
| `Refused` or `Full` | A rule said no. `Info.Key` names the key.                                                      | Tell the player.                                                                                              |
| `Busy` or `Closed`  | Nothing was sent.                                                                              | `Busy`: send the same call again.                                                                             |
| `Unresolved`        | Not known yet.                                                                                 | Unnamed: Ledger keeps sending it, so wait on `Info.Outcome`. Named: send again with the same `Id` and `IdAt`. |

### Hold and Confirm [#hold-and-confirm]

```luau
local Ok, Hold = Sword:Hold(1, 120)
if Ok and typeof(Hold) == "table" then
	-- later, when the buyer pays
	Sword:Confirm(Hold)
end
```

`Hold` answers `true, Hold`, `SoldOut` or `Short`. `Confirm` takes the same `Price` and `Legs` as `Take`. If the hold ran out, `Confirm` uses a free unit; if there is none it answers `Short` with `ShortReason "Gone"`, never `SoldOut`. `Release(Hold)` answers `true`.

### Total and Close [#total-and-close]

`Total(15)` answers `{ Sold, Free, Held }`. `Free` and `Held` are advice. After `Close`, count sold as `Stock - Free - Held`.

`Close()` answers `true` and `{ Removed, Left, Missing }`, lists of part numbers. A part is removed when it is empty and more than 62 minutes old. Parts in `Left` stay closed. Any server may call it, and again later.

### Open quantities only [#open-quantities-only]

| Call                                         | What it does                                                                                                                                                                |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Deposit(Count, Options?)`                   | Adds units. `Options` is `{ From?, Field?, Kind?, Part? }`; `From` pays for them from a key's balance field, one with a `Debit` kind in its store's `Balances`.             |
| `Gather(Count, To, Field, Options?)`         | Moves units into a key's balance field, one with a `Credit` kind in its store's `Balances`. `To` is `{ Store, Key }`. `Options.Kind` picks the kind when there are several. |
| `Withdraw(Count, Part, To, Field, Options?)` | Moves units or proceeds out of a part.                                                                                                                                      |

On a Final quantity, `Deposit` and `Gather` throw.

Next: [Observers and futures](/docs/reference/observers)


# Session (https://xoifaii.github.io/docs/reference/session)



Look up any call on a player's session.

```luau
local Session = Store:Load(Player) -- yields until the data is in
if Session == nil then
	return -- OnLoadFailed ran, and the player is kicked
end

Player:SetAttribute("Gold", Session:Get().Gold)
Session:Observe():Subscribe(function(State)
	Player:SetAttribute("Gold", State.Gold)
end)
```

A session holds one player's data in memory while they are in the server. You get one from `Store:Load`, `Store:Get`, `Store:Expect` or `Store:WaitForLoaded`. Player stores only. See [Players](/docs/learn/players).

Every session call throws on a session that was released. Calls that wait also throw inside an observer listener.

| Call                       | What it does                                                                                                                     |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `Get()`                    | The player's data now. No request.                                                                                               |
| `Observe()`                | An [observer](/docs/reference/observers) that emits the data each time it changes. It has no first value, so call `Get()` first. |
| `ObserveFates()`           | An observer of what became of each `Apply`.                                                                                      |
| `Apply(Op)`                | A change that answers at once and is saved soon.                                                                                 |
| `Commit(Op, Options?)`     | A change that is saved before it answers.                                                                                        |
| `DidApply(Name, Options?)` | Did a named op take effect?                                                                                                      |
| `Flush()`                  | Saves queued `Apply`s now.                                                                                                       |
| `Refresh()`                | Reads the key now, to pick up changes made elsewhere.                                                                            |
| `Release()`                | Saves and ends the session.                                                                                                      |

## Apply [#apply]

```luau
local Ok, Result = Session:Apply({ Kind = "AddGold", Amount = Amount })
```

Apply judges the op on the session's data, queues it and answers at once. It is saved by the next save (every 30 s), a `Flush`, a `Commit`, a `Release`, or shutdown. A `true` is not a save: the op is judged again when saved and may be turned away.

| Answer               | Means                                                    | Do                                        |
| -------------------- | -------------------------------------------------------- | ----------------------------------------- |
| `true, Applied`      | Queued. `Applied` is a handle to watch.                  | Watch `ObserveFates` for ops that matter. |
| `Refused` or `Full`  | The reducer said no on the current data. Nothing queued. | Tell the player.                          |
| `Backlog`            | 4,096 ops or 1.5 MiB are waiting.                        | `Flush`, then apply again.                |
| `Busy`               | Another server's unfinished trade work decides this op.  | Try again later.                          |
| `Behind` or `Closed` | A newer build owns the key, or the server is closing.    | Stop.                                     |
| `Invalid`            | The op cannot be stored.                                 | Fix the op.                               |

Apply never answers `Unresolved`. It takes no options.

## ObserveFates [#observefates]

```luau
Session:ObserveFates():Subscribe(function(Fate)
	if Fate.Fate.Kind == "Turned" then
		warn("turned away:", Fate.Fate.Why)
	end
end)
```

Each applied op gets one fate, once: `Took` (saved), `Turned` (refused at save; `Why` and `State` say why) or `Unknown` (we cannot tell). Subscribe before you apply.

## Commit [#commit]

```luau
local Ok, Result = Session:Commit({ Kind = "AddGold", Amount = Amount })
```

Saves before it answers, and saves queued `Apply`s in the same write. `Options` is `{ Id?, IdAt? }`, as for `Edit`. On `true`, `Result` is the saved data. The answers are the same as `Store:Edit`, with `Info.State` on `Refused` and `Info.Outcome` on `Unresolved`. See [Store](/docs/reference/store).

## Flush, Refresh, Release [#flush-refresh-release]

| Call        | Answer                                                                                                                                                                              |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Flush()`   | `true` once the save was answered, or after about 30 s. `true` does not mean the ops were saved: read the fates. `false, Closed` or `false, Behind`. Nothing queued answers `true`. |
| `Refresh()` | `true` once the read is in. `false` with `Unresolved`, `Behind`, `Unreadable` or `Closed`. With ops queued it works like `Flush`. The view never goes back to older data.           |
| `Release()` | Saves once, waits up to about 30 s, and ends the session. Answers `true` even if the last save failed. Fates say what was saved.                                                    |

`Store:Unload(Player)` is the same as `Release`. Use `Flush` before a [`Ledger.Tx`](/docs/reference/ledger) on the player's key, and `Refresh` after it to show the result.

Next: [Quantity](/docs/reference/quantity)


# Store (https://xoifaii.github.io/docs/reference/store)



Look up any call on a store.

```luau
local Ok, Why, Info = Bank:Edit(Key, { Kind = "AddGold", Amount = Amount })
if not Ok then
	warn("add failed:", Why)
end

local State, Why = Bank:Peek(Key, 30) -- up to 30 s old is fine
```

A store holds one name and every key under it. A key is a string, or a `Player` or UserId in a player store. Most calls work on any store. The player calls (`Load` and friends) work on player stores only, and throw on a string store.

A bad call throws before anything is sent: an unknown op kind, a bad key, a wrong option name, or a call made from inside a reducer. Answers are never thrown. See [Answers](/docs/learn/answers).

## Changing data [#changing-data]

| Call                            | What it does                                                               |
| ------------------------------- | -------------------------------------------------------------------------- |
| `Edit(Key, Op, Options?)`       | One change, saved before it answers.                                       |
| `Reset(Key, Options?)`          | Replaces a key's data with the Default or a state you give.                |
| `Erase(Key, Options?)`          | Removes a key. Erasable stores only.                                       |
| `Bump(Total, Amount, Options?)` | Adds to a total.                                                           |
| `Leg(Key, Op, Options?)`        | Builds one entry for [`Ledger.Tx`](/docs/reference/ledger). Sends nothing. |

### Edit [#edit]

`Options` is `{ MustExist?, Id?, IdAt? }`. `MustExist` overrides the store's setting for this call. A string `Id` needs `IdAt` too. Edit is safe on a key a player session holds.

| Answer                       | Means                                                                                          | Do                                                                                         |
| ---------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `true`                       | Saved.                                                                                         | Done.                                                                                      |
| `Refused` or `Full`          | Your reducer said no, or the data would pass the size cap. `Info.State` is the data it judged. | Final for this name. Do not resend.                                                        |
| `Missing`                    | `MustExist` and the key is not there.                                                          | Create it first, or turn `MustExist` off.                                                  |
| `Spent`, `Expired`, `NoRoom` | The name is used up, forgotten, or the key's name list is full.                                | See [Making a change happen once](/docs/learn/once-only).                                  |
| `Busy` or `Closed`           | Nothing was sent.                                                                              | `Busy`: send the same call again later. `Closed`: stop.                                    |
| `Behind` or `Unreadable`     | A newer build owns the key, or the key cannot be read.                                         | Stop writing it from this build.                                                           |
| `Unresolved`                 | Not known yet. `Info.Outcome` is known later.                                                  | A named Edit: send it again, same name. An unnamed one is still being sent: do not resend. |

An op kind your reducer doesn't handle is refused. Studio's type check catches a kind that isn't in `Ops` before you run the game.

### Reset and Erase [#reset-and-erase]

```luau
local Name = Ledger.Id()
if Name then
	local Ok, Result = Bank:Erase(Key, { Id = Name })
end
```

`Options` for both is `{ Id }` with a `Ledger.Id()` name, or nothing. A string `Id` throws, and so does `IdAt` beside it. `Reset` also takes `State`, a complete state in the newest shape. Make the name just before the call: a server answers `Expired` for its own name once it is 6 minutes old.

| Answer                         | Means                                                                                              | Do                                                      |
| ------------------------------ | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `true`, `Cut`                  | Done. `Cut.Losses` lists the balances that were erased.                                            | Log `Cut.Losses` now. This is the only time you get it. |
| `true`, no `Losses`            | A repeat of the same name, already done. Also the answer for `Erase` of a key that does not exist. | Done.                                                   |
| `Missing`                      | Nothing to reset or erase.                                                                         | Done: the key is gone.                                  |
| `Expired`                      | The name is too old. Nothing was sent.                                                             | Make a new name.                                        |
| `Spent`                        | The name was used for something else.                                                              | Make a new name.                                        |
| `Busy` or `Closed`             | Nothing was sent.                                                                                  | Send again with the same name.                          |
| `Unresolved`                   | Not known yet.                                                                                     | Send again with the same name, soon.                    |
| `Behind`, `Unreadable`, `Full` | A newer build owns the key, it cannot be read, or the given `State` is too big.                    | See [Answers](/docs/learn/answers).                     |

An `Erase` on a store with `Erasable = false` throws. See [Deleting data](/docs/learn/deleting-data).

### Bump [#bump]

```luau
task.spawn(function() -- Bump can wait up to a minute
	Bank:Bump("GoldAdded", Amount)
end)
```

The total must be declared in `Totals`. `Amount` is a whole number and may be negative. Unnamed bumps are best. After `Unresolved`, an unnamed bump is still being sent, so do not send it again. See [Global counters](/docs/learn/global-counters).

## Reading data [#reading-data]

| Call                    | What it does                                                      |
| ----------------------- | ----------------------------------------------------------------- |
| `Peek(Key, Freshness?)` | The key's data.                                                   |
| `Inspect(Key)`          | The stored record, with its migration version.                    |
| `Total(Name, MaxAge?)`  | A declared total.                                                 |
| `Follow(Key)`           | An [observer](/docs/reference/observers) of the key's data.       |
| `Stale()`               | An observer of keys this server wrote that its view is behind on. |
| `Keys()`                | Pages of every key.                                               |

### Peek [#peek]

`Freshness` is a number of seconds (0 to 2,592,000), or `{ Fresh = true }`.

| Call                          | Gives                                                                                                                          |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `Peek(Key)`                   | The saved data, read now.                                                                                                      |
| `Peek(Key, 0)`                | The same: a plain `Peek`.                                                                                                      |
| `Peek(Key, 30)`               | A recent copy that all servers share. Cheaper for a key many servers read often. See [Reading data](/docs/learn/reading-data). |
| `Peek(Key, { Fresh = true })` | The newest saved data. Costs a write, so use it rarely.                                                                        |

| Answer                              | Means                                                 | Do                                                                                                                                                   |
| ----------------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| the data                            | The key's data at some moment.                        | Use it.                                                                                                                                              |
| `nil, Missing`                      | Never saved, or erased. It does not give the Default. | Use your own default.                                                                                                                                |
| `nil, Behind`                       | A newer build owns the key.                           | Stop using this key. A plain `Peek` and `{ Fresh = true }` answer this. `Peek(Key, MaxAge)` can keep answering the old copy for up to about an hour. |
| `nil, Unresolved`                   | The read failed or took over 30 s.                    | Show "loading", try later.                                                                                                                           |
| `nil, Busy`, `Closed`, `Unreadable` | See [Answers](/docs/learn/answers).                   |                                                                                                                                                      |

`nil` never means empty. See [Reading data](/docs/learn/reading-data).

### Total [#total]

`Total(Name, MaxAge?)` answers a number, or `nil, Unresolved` or `nil, Behind`. It's for totals. For a quantity, use `Quantity(Name):Total()`. A name that isn't in `Totals` or `Quantities` throws.

### Keys [#keys]

```luau
local Pages = Bank:Keys()
local Page, Why = Pages:Next()
```

`Next` answers a list of up to 50 keys. `nil, nil` means the last page was read. `nil, Unresolved` means the fetch failed; the next `Next` tries the same page. Pages come in no set order.

## Support calls [#support-calls]

| Call                            | What it does                                                  |
| ------------------------------- | ------------------------------------------------------------- |
| `DidApply(Key, Name, Options?)` | Did a named op take effect? `Options` is `{ IdAt?, Probe? }`. |
| `Losses(Key)`                   | The balances that a Reset or Erase erased, kept for 7 days.   |
| `Pending(Key)`                  | Trade work that is not finished on a key.                     |
| `Resettle(Key)`                 | Finishes that work now. Takes no options.                     |

See [Support tools](/docs/guides/support-tools). `Pending` answers `Unresolved` after 30 s on a hung read, as `Peek` does.

## Quantities [#quantities]

`Quantity(Name)` returns the [quantity object](/docs/reference/quantity). It throws if the name is not in `Quantities`.

## Players [#players]

| Call                    | What it does                                                                                          |
| ----------------------- | ----------------------------------------------------------------------------------------------------- |
| `Load(Player)`          | Loads the player's [session](/docs/reference/session). Yields. Answers the session, or `nil, Reason`. |
| `Unload(Player)`        | Saves and ends the session. Does nothing if there is none.                                            |
| `Get(Player)`           | The session, or `nil`.                                                                                |
| `Expect(Player)`        | The session, or throws.                                                                               |
| `IsLoaded(Player)`      | `true` if a session is loaded.                                                                        |
| `WaitForLoaded(Player)` | Waits for a load that has started.                                                                    |
| `Read(Player)`          | The session's data, or `nil`.                                                                         |

`Load` answers `nil, nil` if the player left. Otherwise the reason is `Unresolved`, `Missing`, `Behind`, `Busy` or `Unreadable`. Then `OnLoadFailed` runs, and the player is kicked unless `Kick = false`.

## Destroy [#destroy]

`Destroy()` ends every session and observer on the store. The store takes no more calls, and its name cannot be opened again on this server. You will rarely need it.

Next: [Session](/docs/reference/session)


# Types (https://xoifaii.github.io/docs/reference/types)



Type your config, ops and variables so Luau catches mistakes.

```luau
local Config: Ledger.TypedConfig<Data, Ops> = {
	Name = "PlayerData",
	Keys = "Player",
	MustExist = false,
	Erasable = false,
	Default = { Gold = 0, Items = {} },
	Balances = {
		Gold = { Credit = "AddGold" },
	},
}

local function GoldOp(Amount: number): Ledger.OpOf<Ops, "AddGold">
	return { Kind = "AddGold", Amount = Amount }
end
```

All types are `Ledger.<Name>`, for example `Ledger.Info<Data>`. Luau checks them in strict mode with the new type solver. There are no TypeScript typings.

## The ones you will use [#the-ones-you-will-use]

| Type                                        | Is                                                                                                                         |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `Reason`                                    | One of the 15 answers, as text.                                                                                            |
| `Info<D>`                                   | The third value of a no: `State`, `Identity`, `Key`, `ShortReason`, `Name`, `Outcome`. See [Answers](/docs/learn/answers). |
| `Frozen<D>`                                 | What `Peek` and `Get` give: your data, read only.                                                                          |
| `TypedConfig<D, O>`                         | The table for `Ledger.New`.                                                                                                |
| `BalanceField<T>`                           | One entry of `Balances`: `{ Credit?, Debit?, Min?, Max?, Arithmetic? }`.                                                   |
| `Op<O>`                                     | An op of any kind in `O`.                                                                                                  |
| `OpOf<O, "Kind">`                           | One kind of op. A wrong field is named in the error.                                                                       |
| `Reducer<D, O>`                             | A reducer function.                                                                                                        |
| `TypedStore<D, O>`, `TypedSession<D, O>`    | The store and session objects.                                                                                             |
| `Quantity`, `KeyPages<K>`                   | The quantity and key-pager objects.                                                                                        |
| `Observer<T>`, `Connection`, `Future<T...>` | See [Observers](/docs/reference/observers).                                                                                |
| `Cut`                                       | The answer of `Reset` and `Erase`: `{ Name, Losses? }`.                                                                    |
| `Closed`                                    | The answer of `Quantity:Close`: `{ Removed, Left, Missing }`.                                                              |

## Options [#options]

`EditOptions`, `CommitOptions`, `BumpOptions`, `PeekOptions`, `DidApplyOptions`, `ResetOptions<D>`, `EraseOptions`, `TxOptions`, `TakeOptions`, `ConfirmOptions`, `GatherOptions`, `DepositOptions`, `WithdrawOptions`, `LegOptions`.

## Everything else [#everything-else]

`KeyLike`, `KeysMode`, `OpMap`, `Name`, `OpId`, `Applied`, `Terms<O>`, `Overloads<O, Shape>`, `Fate<O>`, `DidApplyInfo`, `InfoKey`, `Identity`, `Record<D>`, `LossRecords`, `PendingItems`, `ShortReason`, `LoadFailedHandler`, `ResultSchema<D>`, `Migration`, `BalanceField<T>`, `BalanceKindLimits<T>`, `Amount`, `Arithmetic<T>`, `Windows`, `TotalDeclaration`, `QuantityDeclaration`, `KeyOfStore`, `TxLeg`, `Leg<S>`, `TakeLeg`, `SessionCommon<D, O>`, `Session<D>`, `StoreCommon<D>`, `Store<D>`, `Config<D>`.

`Ledger.Took`, `Ledger.QuantityTotal` and `Ledger.HoldHandle` name the results of `Take`, `Quantity:Total` and `Hold`, so you can type a variable that keeps one (a checkout that holds a hold between two clicks, for example).

An `OpId` is what `Ledger.Id()` gives. It is opaque: you cannot turn it into text or build one.

Next: [Limits](/docs/limits)
