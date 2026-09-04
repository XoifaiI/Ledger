# Getting started (https://xoifaii.github.io/LedgerDocs/docs/getting-started)



## Install [#install]

<Tabs items="['Wally', 'Rojo', 'Model file', 'roblox-ts']">
  <Tab value="Wally">
    ```toml
    [dependencies]
    Ledger = "xoifaii/ledger@5.0.0"
    ```
  </Tab>

  <Tab value="Rojo">
    Clone the repo and add `src` to your project, as `ServerStorage/Ledger` or anywhere else the server can reach.
  </Tab>

  <Tab value="Model file">
    Drop the `Ledger` model anywhere the server can reach. It's one module and it has no dependencies.
  </Tab>

  <Tab value="roblox-ts">
    ```
    npm install @xoifail/ledger
    ```

    See [Using Ledger from TypeScript](/docs/guides/typescript) for the line your project file needs.
  </Tab>
</Tabs>

Ledger installs where both sides can see it, so you can keep it next to shared type definitions. It
still only runs on the server, because only the server can reach a datastore, and requiring it from a
client says so and stops there.

## Build a store [#build-a-store]

A store is one datastore name plus the rules for everything under it. Build it once, near the top of
a server script.

Start simple. One field, and a reducer that hands back the next state or `nil` to refuse:

```luau
local Ledger = require(ServerStorage.Ledger)

export type Profile = {
	Gold: number
}

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	if Op.Kind == "AddGold" then
		if type(Op.Amount) ~= "number" or Op.Amount <= 0 then
			return nil
		end
		return { Gold = State.Gold + Op.Amount }
	end

	if Op.Kind == "SpendGold" then
		if type(Op.Amount) ~= "number" or Op.Amount > State.Gold then
			return nil
		end
		return { Gold = State.Gold - Op.Amount }
	end

	return nil
end

local Store = Ledger.New({
	Name = "PlayerData",
	Default = { Gold = 100 },
	Reducer = Reducer,
	Balance = "Gold",
})
```

The reducer takes the state and one op and gives back the next state, or `nil` to refuse it. It has
to be pure. [Writing a reducer](/docs/concepts/reducer) covers the rules and what breaks when you
don't keep them.

`Balance` is optional. You only need it for [transfers](/docs/guides/transfers), and it names a
number field that's already in `Default`.

### Once there is more than one field [#once-there-is-more-than-one-field]

Writing the next state out by hand stops working as soon as `Default` grows. Any field you don't
mention is not in the state you handed back, so it is gone from that moment on.

Copy the state and change what you need instead:

```luau
export type Profile = {
	Gold: number,
	Items: { string }
}

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	if Op.Kind == "AddGold" then
		if type(Op.Amount) ~= "number" or Op.Amount <= 0 then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold += Op.Amount
		return Next
	end

	if Op.Kind == "PickUp" then
		if type(Op.Item) ~= "string" then
			return nil
		end

		local Next = table.clone(State)
		Next.Items = table.clone(State.Items)
		table.insert(Next.Items, Op.Item)
		return Next
	end

	return nil
end
```

`table.clone` is shallow, so `Items` needs a copy of its own before you touch it. The state you were
handed is deep frozen, so writing into it throws on the line that did it rather than breaking a fold
somewhere later.

Deeper than that and the copying gets hard to read. [Advanced
reducers](/docs/concepts/advanced-reducers) has a `SetPath` for it.

## Load and unload [#load-and-unload]

```luau
Players.PlayerAdded:Connect(function(Player)
	Store:Load(Player)
end)

Players.PlayerRemoving:Connect(function(Player)
	Store:Unload(Player)
end)

game:BindToClose(function()
	Ledger.CloseAll()
end)
```

`Load` yields until the profile is folded, and kicks the player if it can't read it. `Unload` saves
whatever is queued and yields until that's durable. `CloseAll` does the same thing for every store
at once, and it's the only thing you need in `BindToClose`.

## Read and write [#read-and-write]

```luau
local Session = Store:Expect(Player)

print(Session:Get().Gold)          --> 100

Session:Apply("AddGold", { Amount = 50 })
print(Session:Get().Gold)          --> 150
```

`Apply` is instant. It runs your reducer against live state, updates it, and queues the op for the
next save. You get back `(boolean, Reason?)`, and `false` means either your reducer refused it or
Ledger did.

When you need the write to be durable before you act on it, use `Commit`:

```luau
local Ok, Why = Session:Commit("SpendGold", { Amount = 25 }):Wait()
if not Ok then
	warn(`could not spend: {Why}`)
end
```

[Apply and Commit](/docs/concepts/apply-and-commit) goes into which one to use.

## Watch for changes [#watch-for-changes]

```luau
Session:Observe():Subscribe(function(State)
	UpdateGoldLabel(Player, State.Gold)
end)
```

This fires on every change that goes through, including ones that turn up from another server when a
transfer or a transaction settles.

## Running without a datastore [#running-without-a-datastore]

`Mock = true` puts a store on an in memory datastore and it never touches `DataStoreService`. Real
limits, no API access, no published place.

```luau
local Store = Ledger.New({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {} },
	Reducer = Reducer,
	Mock = true,
})
```

The mock is stricter than Studio on purpose, because Studio hands you request budgets a live server
never gets. See [Testing](/docs/guides/testing).

## Naming your ops [#naming-your-ops]

Everything above takes any kind with any fields. Once the kinds settle down, write down what each one
carries. The checker then holds every write against it, and the reducer reads its fields without a
cast:

```luau
export type Ops = {
	SpendGold: { Amount: number },
	AddItem: { Item: string },
}

local Store = Ledger.NewTyped<<Profile, Ops>>(Options)
```

See [Typed ops](/docs/concepts/typed-ops).


# Overview (https://xoifaii.github.io/LedgerDocs/docs)



Ledger keeps player data as a log of changes instead of a document you overwrite. You never write
state. You write down the change you want, a function you own decides if it's allowed, and state is
what falls out of replaying those changes.

```luau
local Store = Ledger.New({
	Name = "PlayerData",
	Default = { Gold = 100 },
	Reducer = function(State, Op)
		if Op.Kind == "Earn" then
			if type(Op.Amount) ~= "number" or Op.Amount <= 0 then
				return nil
			end
			return { Gold = State.Gold + Op.Amount }
		end

		if Op.Kind == "SpendGold" then
			if type(Op.Amount) ~= "number" or Op.Amount > State.Gold then
				return nil -- refused, on every server, forever
			end
			return { Gold = State.Gold - Op.Amount }
		end

		return nil -- an op this build has never heard of
	end,
})

Store:Load(Player)
Store:Expect(Player):Apply("SpendGold", { Amount = 25 })
```

Two servers spend the same 100 gold, both writes go through, the fold takes one and refuses the
other. Every server agrees, every time.

## Why there's no session lock [#why-theres-no-session-lock]

A session lock stops the second writer. You pay for that in three ways. A dead server leaves a lease
someone has to wait out. Whoever is locked waits at the join screen. And nothing can reach a player
who is offline or on another server.

A fold that validates makes the bad state unreachable, so nothing needs unlocking when a server
crashes. It costs discipline instead. Changes have to be ops with names, and you have to write a
reducer.

## What's in it [#whats-in-it]

<Cards>
  <Card title="The fold" href="/docs/concepts/the-fold">
    State is a pure fold of the log, so every server works out the same answer with no lock.
  </Card>

  <Card title="Apply and Commit" href="/docs/concepts/apply-and-commit">
    Apply is instant and local. Commit is durable and tells you whether your op won.
  </Card>

  <Card title="Cross server writes" href="/docs/reference/store">
    Edit, Transfer and Tx work on any key, online here, elsewhere, or offline.
  </Card>

  <Card title="Entity stores" href="/docs/guides/entity-stores">
    String keys for clans, listings, world records. Shared state no server owns.
  </Card>

  <Card title="Transfers" href="/docs/guides/transfers">
    A balance moved through an escrow, deduped by id, and it fixes itself after a crash.
  </Card>

  <Card title="Transactions" href="/docs/guides/transactions">
    Two phase commit across two to four keys, which can sit in two different stores.
  </Card>

  <Card title="Once" href="/docs/concepts/once">
    Name an op after a receipt or an order and it only ever applies once.
  </Card>

  <Card title="Migrations" href="/docs/guides/migrations">
    Shape upgrades with a version on them, safe to roll out one server at a time.
  </Card>

  <Card title="Typed ops" href="/docs/concepts/typed-ops">
    Name what each op carries and the checker holds every write against it.
  </Card>
</Cards>

## What it isn't [#what-it-isnt]

Ledger is server side only. It doesn't replicate to clients, it doesn't do leaderboards or ordered
stores, and it won't hide a reducer that's wrong. If your reducer reads `os.time()` or
`math.random()`, two servers will fold the same log into different state. Ledger warns about that in
Studio.


# Limits (https://xoifaii.github.io/LedgerDocs/docs/limits)



Some of these are Roblox's and some are Ledger's. The Roblox ones you can't move. The Ledger ones
are set below the real limit so you get a clean refusal instead of a failed save.

## Names and keys [#names-and-keys]

|                | Cap           |                                                   |
| -------------- | ------------- | ------------------------------------------------- |
| Store name     | 47 characters | Ledger, so `<Name>_Tx` fits in the datastore's 50 |
| Entity key     | 50 characters | Roblox                                            |
| Transfer id    | 64 characters | Ledger                                            |
| Transaction id | 50 characters | Ledger                                            |

Player keys are the UserId, so there's nothing to think about there. Entity keys have to be valid
UTF-8.

## Size [#size]

|                         | Cap    |        |
| ----------------------- | ------ | ------ |
| Stored value            | 4 MB   | Roblox |
| Folded state            | 2 MB   | Ledger |
| One op                  | 1 MB   | Ledger |
| Unsaved ops             | 1.5 MB | Ledger |
| Queued ops              | 4096   | Ledger |
| Reservations on one key | 256    | Ledger |

State can hold numbers, strings, booleans, tables and buffers. A buffer costs about a third more than
its length. That is what the datastore charges to store one, and what these caps count.

State caps at 2 MB rather than 4, which leaves room for the ops sitting on top of the snapshot.

An op that would push state over the cap is refused with [`Full`](/docs/concepts/reasons). Ops that
shrink it are still allowed, so a cleanup works when you're already over.

Hitting the unsaved caps gives you [`Backlog`](/docs/concepts/reasons), and in practice that only
happens when the datastore is down.

Ledger keeps two tables of its own in the state, and they clear on different rules:

|             | Holds                          | Clears after                      |
| ----------- | ------------------------------ | --------------------------------- |
| `_Received` | names already applied          | 30 days                           |
| `_Held`     | units set aside for a transfer | 7 days to deliver, 8 to give back |

A reservation is not one of them. A hold lives in MemoryStore and takes nothing off the key.

Neither grows with uptime. Each is bounded by how much happened inside its own window.

## Applied names [#applied-names]

The set of applied ids lives in the state, so it counts against the state cap. It does not grow
without bound. Every time a name is written into it, anything already in there older than 30 days is
dropped, whichever kind of name it is.

That sweep only rebuilds the set when something in it is actually old enough to go, so the usual
write costs nothing.

One entry is about 40 bytes when Ledger picked the id, more if you named the transfer yourself, so a
rolling 30 day window is nowhere near the state cap for any real player. An entry also carries a short
fingerprint of what the name meant, which is what lets a name reused for a different amount answer
[`Spent`](/docs/concepts/reasons) instead of `true`.

`ClearDelivered` runs that sweep early. It cannot drop a delivery id sooner than 30 days, because a
sender can ask for a refund up to that point and needs the evidence to know the delivery already
happened.

A key many players write to fills at the rate all of them write to it. Every `Tx` leg and every
`Transfer` adds one name. One name is about 40 bytes and lasts 30 days. That is about 1,700 of
them a day on one key before the names alone fill the state cap.

`Reserve` and `Confirm` add no name. Stock held on one key has no such ceiling.

A key that reaches the cap stays there. `ClearDelivered` has nothing older than 30 days to drop. Spread the entity over several keys before that point, the same way `Bump` spreads
a total. See [Entity stores](/docs/guides/entity-stores).

Naming your transfers `tip:8412` rather than after a random string keeps this set small.

## Transactions [#transactions]

Between 2 and 4 legs, and a key can only appear once.

One key doesn't need a transaction, which is why two is the minimum. `Edit` already applies to a
single key or refuses it.

The maximum is four because each leg holds up a key while it waits. A leg is written to its key
first and sits there unresolved, and anything else writing to that key meanwhile answers
[`Busy`](/docs/concepts/reasons). If the server running the transaction dies, another one has to
abort it, and it may not do that until 30 seconds per leg have passed. Four legs can hold four keys
for two minutes.

A transaction is considered dead after 60 seconds, so another server will abort it on the original's
behalf. Committed markers get tidied up in the background about an hour later.

A transaction id ages out after 30 days, the same as every other name. A transaction lives at most an
hour, so 30 days covers the whole protocol many times over. What it does not cover is you reusing the
same id a month later, which applies it again. Derive ids from the thing being settled and they are
never reused.

### One key at a time [#one-key-at-a-time]

A key takes one transaction at a time. While a leg is parked on it, every other transaction touching
that key answers [`Busy`](/docs/concepts/reasons) and stops. `Tx` does not retry a `Busy` for you,
because every server retrying at once would multiply the load on a key that is already contended.

Retry it yourself with a short backoff. Measured against the mock, 8 servers depositing into one bank
key all get through in about 3 attempts each. 32 servers take about 8 attempts each, and the cost per
successful transaction goes from 10 requests to over 100.

Plan around this for anything every player writes to, so a guild bank, a global shop, or an event pot.
Spread the writes across keys where you can, for example one key per guild rather than one for all of
them. Correctness never suffers from contention, only throughput.

### What an operation costs [#what-an-operation-costs]

Measured on the mock, for the path where nothing fails.

| operation              | datastore requests                                                     |
| ---------------------- | ---------------------------------------------------------------------- |
| `Peek`, `Edit`, `Bump` | 1                                                                      |
| `Reserve`, `Release`   | 0, and two MemoryStore units, plus one read on the first hold of a key |
| `Confirm`              | 1, and two MemoryStore units                                           |
| `Holds`                | 0, and one MemoryStore unit                                            |
| `Transfer`             | 3                                                                      |
| `Tx`, 2 legs           | 8                                                                      |
| `Tx`, 4 legs           | 12                                                                     |
| `Total`, cached        | 0, and one MemoryStore unit                                            |
| `Total`, cold          | 16, and three units                                                    |

A transaction costs 4 requests on its marker whatever the leg count, which is why the two leg case is
the one worth avoiding. A limit that lives on one key is a reservation, not a transaction. See
[Reservations and totals](/docs/guides/reservations).

Roblox gives an experience `UpdateAsync` budget of `300 + 20 per CCU` a minute, which works out at
about 20 writes per player per minute at any real player count. So a player can average roughly 6
transfers or 2 two leg transactions a minute across the whole experience, before autosave takes its
share. Autosave itself is cheap and does not scale with how busy a player is, see
[Timing](#timing).

## Transfers [#transfers]

A stranded transfer is redriven for 7 days. After that it expires and refunds. Delivered ids stay in
the receiver's applied set for 30 days so a late retry can't pay twice.

Recovery handles up to 32 holds per pass, so a key with a lot stranded takes a few passes.

## Reservations and totals [#reservations-and-totals]

A hold lasts 15 minutes, not the 30 days an applied name lasts. Fifteen minutes is the cap as well
as the default. `Hold` sets a shorter time per reservation, and `Reserve` throws above the cap. A
checkout that stays open longer calls `Reserve` again under the same Id. A hold lives in MemoryStore,
so it costs the key nothing and runs out on its own. One key holds 256 at once.

Holds share the experience's MemoryStore quota, `1000 + 120 × concurrent users` request units a
minute, with totals, transaction leases and idle sessions. A `Reserve` or `Release` is two units, a
`Confirm` two, a `Holds` one.

A total is spread over 16 keys. `Total` answers from a sum cached in MemoryStore while that sum is
under a minute old, for one request unit, and reads all 16 keys when it is not, so a cold total costs
16 requests on the one server that refills it. `Bump` costs one request and no units.

See [Reservations and totals](/docs/guides/reservations).

## Timing [#timing]

Autosave runs every 30 seconds per session, and compacts as well when the log has gotten long.

A session with nothing queued and no transaction parked on it reads every fourth turn. An idle player
then costs one request every two minutes rather than one every 30 seconds. It writes as soon as there
is anything to write. Only the check for what other servers did waits.

An autosave is skipped when the server is under 4 requests of write budget, and it warns.

## Compaction [#compaction]

The log is folded into the snapshot once it is worth rewriting the record. The snapshot size decides
when. A small profile compacts every 128 ops. A large one waits until the log is a fifth of the
snapshot. Nothing waits past 512 ops.

A big profile is expensive to rewrite, so rewriting it every 128 ops costs more than carrying them. A
small one is cheap to rewrite, and folding fewer ops keeps loads fast.

## Versions [#versions]

Roblox keeps 30 days of history per key. `History` pages up to 100 at a time and defaults to 25.

## What isn't limited [#what-isnt-limited]

There's no cap on how many servers write the same key at once. The fold is why. It's the one number
you don't have to plan around.


# Releases (https://xoifaii.github.io/LedgerDocs/docs/releases)



`+` is new, `-` is gone, `!` is something you have to know about before you upgrade.

## 5.0.0 [#500]

The release that takes Ledger to 100k CCU.

A hold moved off the key and into MemoryStore. A total is summed once a minute for the whole fleet
instead of once a poll on every server. The reaper and the sweep split a pass between them rather
than every server doing all of it. Measured at \~5,000 servers, the four workloads
MemoryStore touches cost **1,170,705 datastore calls a minute on 4.x, to just 958 on 5.0**.

| at 100k CCU, per minute                  | 4.x                   | 5.0 |
| ---------------------------------------- | --------------------- | --- |
| a pot every server draws every 5 seconds | 960,600 calls         | 616 |
| reaping every shard                      | 160,004 calls         | 324 |
| one key the whole fleet is repairing     | 50,000 repairs        | 10  |
| 32 servers driving one key               | 101 calls per success | 8   |

A purchase is 3 datastore calls and 6 MemoryStore units, and it stays there from 200 servers to
5,000.

```diff
+ Holds live in MemoryStore and cost the key nothing
+ Holds answers what is held on a key
+ Total reads a sum the whole fleet shares, so a polled pot costs one MemoryStore read
+ Transfer takes a Field, so any number field moves between keys
+ Confirm takes your own op, so your reducer decides what a checkout takes
+ A transaction whose key another server is driving answers Busy at once, for one MemoryStore read
+ The reaper and the sweep do each shard and each followed key once a minute across the whole fleet

- Grant, and Reserve's To
- _Booked, and everything that read it
- The Balance requirement on RecoverTransfers and ClearDelivered

! Confirm is Confirm(Key, Id, Kind, Fields) and needs your op
! A hold is not in the fold: Peek shows the full field, an Edit can spend held units, and that checkout is Refused
! Reserve needs MemoryStore, which in Studio means API access on, and answers Unresolved without it
! A hold that has gone frees its name, and Reserve no longer answers Spent
! A hold is capped at 15 minutes, so Hold only shortens one and a longer Hold throws. Reserve again under the same Id to keep a checkout open
! Total is up to two minutes old by default, one window for this server's sum and one for the item it came from. Pass MaxAge for fresher, or zero to read the shards every time
! 5.0 does not read a reservation a 4.x server made. Drain them before you upgrade
```

### Upgrading [#upgrading]

Install the new version. The stored record does not change, and a store that never called `Reserve`
needs nothing else.

**Confirm.** Give it the kind and fields of the op that spends the units, the way you would give
`Edit`, and have your reducer refuse one the field cannot cover. A hold no longer lowers the field, so
a reducer that spent nothing on confirm now has to.

**Grant.** Reserve without `To` and move the units with `Transfer(From, To, Amount, Id, Field)`. The
[buying sequence](/docs/guides/reservations#the-buying-sequence) is a hold and two transfers under two
ids now.

**Studio.** Turn API access on. Without MemoryStore every `Reserve` answers `Unresolved`, and a
checkout still works, refused by your reducer when the stock has gone.

<Callout type="warn">
  If your game called `Reserve` on 4.x, drain it before you upgrade. Stop reserving, let every open
  reservation be confirmed or released, and let the keys compact. A 5.0 server does not apply the old
  reservation ops, so units a 4.x reservation was still holding come back to the field, and a key
  whose log still carries one warns that it cannot be compacted until you erase it.
</Callout>

Do not roll 5.0 out alongside 4.x servers. The two fold a reservation differently, so for the length
of the deploy the same key reads one way on an old server and another on a new one. Take the servers
down, or accept that anything reserved in that window is voided.

## 4.5.0 [#450]

```diff
+ Clearer warnings
+ Erase answers Unresolved when it cannot read the key first, and leaves it alone

- An edit that only held if a parked transaction did not go through being written, and the key never compacting again once it did
- A session that outlived the 8 days of an erase mark closing on its next save, and losing what it had applied since
- A session filled to its byte cap during a datastore outage never saving again once the datastore came back
- A transaction with a buffer in a leg answering Spent when asked again with the same buffer
- A player who rejoined inside the 8 days after an erase being called a session on another server
- A migration that copies the state being told it had dropped Ledger's own fields
- Erase burying a key it could not read, and the money set aside on it with it

! An Edit that only holds if a parked transaction does not go through answers Unresolved and is not written
! An Apply in the same position waits until the transaction settles, then lands or is turned away
! A reducer or migration that writes a field starting with an underscore is warned about as your mistake, not as a Ledger bug
```

### Upgrading [#upgrading-1]

Install the new version. The stored record does not change.

**Edits beside a parked transaction.** An `Edit` that holds on the key as it is, but not once the parked
transaction goes through, used to be written and answer `Unresolved`. It still answers
[`Unresolved`](/docs/concepts/reasons), and nothing is written. Ask again once the transaction settles.
An `Apply` in the same position stays queued until then. Nothing changes for an op that holds either way.

**Erase.** When the key cannot be read before the hand over, `Erase` answers `Unresolved` and the key
stays as it was. Ask again. It used to bury the key and warn that the money was gone.

## 4.4.1 [#441]

```diff
+ Buffers in the fake datastore stored with zstd rather than base64
+ Transactions check for any pending ids
```

### Upgrading [#upgrading-2]

Install the new version. The stored record does not change. Your code does not change.

## 4.4.0 [#440]

```diff
+ Mock takes Players, CCU and Throttled
+ Reset says when the key it reset still cannot compact, and what will clear it

- A migration that rebuilt the state dropping the money set aside, the applied names, the reservations and the tally
- Reserve answering true under a name whose units had already gone, without setting anything aside
- A transaction leg landing on a key that was erased, with nothing said about it
- An older build being able to rewrite the op list of a record it cannot read
- One store's transaction clean up list skipping the keys another store in the same game had filled

! Reserve answers Spent under a name whose units have gone, where it used to answer true
! A transaction leg is turned away from a key that was erased, for the 8 days its tombstone lasts
```

### Upgrading [#upgrading-3]

**Migrations.** A migration is handed the stored state, and that carries Ledger's own fields next to
yours. One that copies the state and changes what it needs has always kept them:

```luau
local Next = table.clone(State)
Next.Gold = State.Coins or 0
Next.Coins = nil
return Next
```

**Reserve.** Asking again under a name that still holds units answers `true` and sets nothing aside
twice, the same as before. Under a name whose units have gone, confirmed, released or given back, it
answers [`Spent`](/docs/concepts/reasons) where it used to answer `true` while setting nothing aside.
Nothing could be spent twice either way, since `Confirm` refuses a reservation that isn't there. The
answer was wrong.

A reservation name is a handle on live units rather than a receipt. To know later whether a purchase
happened, put a [`Once`](/docs/concepts/once) name on the op that grants the item and ask `DidApply`.

**Transactions and erased keys.** A leg on a key that was erased used to land, so money arrived on a
key the erase was meant to empty.

## 4.3.1 [#431]

```diff
+ Runcontext check for client using Ledger

! Ledger installs to the shared realm now, so a Wally dependency moves out of server-dependencies
! Ledger.Op<Ops> and Ledger.OpOf are read only, so a reducer that writes to its op stops the build
```

### Upgrading [#upgrading-4]

**Wally.** Ledger is a shared package now, so move it across:

```diff
- [server-dependencies]
+ [dependencies]
  Ledger = "xoifaii/ledger@4.3.1"
```

**Ops are read only.** On a typed store the op your reducer is handed no longer takes a write.

## 4.3.0 [#430]

```diff
+ Ledger.NewTyped, which takes a map of the op kinds your store writes and what each one carries
+ Apply, Commit and Edit on a typed store checked against that map, kind and fields together
+ Ledger.Op<Ops>, the op as one of your kinds, so a reducer narrows on Op.Kind and reads fields with no cast
+ The Field argument to Reserve, Bump and Total held against your state's number fields on a typed store
+ A typed reducer held to giving back your state or nil
+ Ledger.Record, Ledger.Future and Ledger.Observer exported
+ Erase passes on money the key was still sending, and units a Reserve set aside for another key, before the key goes
+ Marker clean up starts on every server, not only one that has already had a write to retry

- A reservation kept rather than given back, after sitting 30 days without a Grant having started on it
- A delivery landing after the window it can still be given back in
- A reducer that copies the whole state being told it had written Ledger's own bookkeeping
- A reducer being able to put applied names on a key that had none

! Reserve answers Refused once a key holds 256 reservations at once
! ClearDelivered throws on a store that names no Balance field, the way RecoverTransfers already did
! Nothing else changes unless you ask for it. A store built with Ledger.New behaves as it did
```

### Upgrading [#upgrading-5]

There's nothing to do. `Ledger.New` takes the same options, hands back the same store, and every call
site on it reads the same. Naming your ops is something you do when you want it.

To opt one store in, write what each kind carries and build it with `NewTyped`:

```luau
export type Ops = {
	Buy: { Item: string },
	AddGold: { Amount: number },
}

local Store = Ledger.NewTyped<<Profile, Ops>>({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {} },
	Reducer = Reducer,
})
```

The call shape doesn't change, so the calls you already have keep working:

```luau
Session:Apply("Buy", { Item = "Sword" })
```

Both kinds of store can live in one game. See [Typed ops](/docs/concepts/typed-ops).

**Two answers you may not have seen before.** `Reserve` now answers `Refused` on a key already
holding 256 reservations at once. A shop key sits at a handful, so reaching this means they are being
made faster than they are being confirmed or released. Handle it the same way you already handle
`Refused` from asking for more than the field holds.

`ClearDelivered` is about money moving between keys, so it now throws on a store that names no
`Balance` field, where before it wrote something the key could not read back. `RecoverTransfers`
already asked for one. If `ClearDelivered` is in your support tooling, point it at the store that
names the balance.

**Erase.** It already passed on money the key was still sending. It now also passes on money that had
been waiting too long to be retried, and units a `Reserve` set aside with a `To`. Nothing to change:
an erase that used to warn about what went with the key now has less to warn about. See
[Erase](/docs/guides/recovery#erase).

## 4.2.0 [#420]

```diff
+ A tally keeps its total in a field of Ledger's own, so the number stops moving when your Default does
+ Marker clean up starts where the last pass stopped, so every shard gets its turn
+ A clean up pass asks both stores whether it can afford to run before each shard

- A key that stopped compacting, and later stopped taking writes, after it held an op for a transaction that then aborted
- Store:Total reading a different number on a server whose Default had changed
- A marker left behind for good when a transaction took longer than five minutes to open one
- Clean up spending more of the request budget than it had checked for
- The near cap warning telling you to take out your own data when the field filling the key is Ledger's own

! An Op field reads as unknown in strict Luau, so a reducer checks the type before it uses one
! Reserve refuses a Hold longer than just under 30 days when you give it a To
! Store:Total says so while a shard still keeps its total the old way
```

### Upgrading [#upgrading-6]

**Your reducer.** An `Op` field is `unknown` now instead of `any`. In `--!strict` that means you
check the type before you use the value:

```luau
if Op.Kind == "Add" and type(Op.Amount) == "number" then
	return { Gold = State.Gold + Op.Amount }
end
```

Nothing about how an op behaves changed. The checker asks for the check that a careful reducer
already made. A file that is not strict reads the same as before.

**Tallies.** A tally used to keep its total in the field you named. A fold puts your `Default` under
every key it reads, so once a shard compacted, that `Default` was part of the total, and a build
that changed it read the tally differently. The total now lives beside your field instead.

A shard written before the upgrade moves across on its next `Bump`. Until then Ledger says so, and
names the tally, so you know which ones are waiting. A `Total` that was already off stays off by the
same amount, because the old shape gives no way to tell your `Default` apart from what was counted.
Bump each tally once and the number stops drifting from there.

Finish the deploy before you read a total. A server still on 4.1 reads a shard that has moved across
as empty, so its `Total` comes back short while the deploy runs. Nothing is lost, and the number is
right again once every server is on 4.2.

**Reservations.** A `Hold` longer than just under 30 days is refused when you give a `To`. A hold
that outlives the window Ledger keeps a delivery for cannot be given back safely, so it is written
off instead. Leave `To` out and a long hold is fine.

**A key that already stopped compacting.** This one does not fix itself, the same as 4.0.4. Ledger
keeps an op it accepted only because a transaction was parked, and drops it once that transaction
has been decided. It can only do that for an op written by 4.2, because that is when the op is
marked. A key that was already stuck stays stuck, and Ledger names it in the warning.

To clear one, take the op that is stuck instead of turning it away. Hand back a copy of the state
and change nothing:

```luau
if Op.Kind == "Spend" and State.Gold < Op.Amount then
	return table.clone(State)
end
```

Deploy that, let the key compact, then put the guard back.

**Everything else.** Drop it in. The stored record grew two fields that older builds ignore, and no
key needs a hand.

## 4.1.1 [#411]

```diff
+ Ledger.UseAsync, to replace the defer, the delay and the cancel that Ledger gives to the engine
+ Faster encoding of the marks that name the keys of a transaction

+ Better transaction mark clean up
+ A clean up pass no longer steps over a page of marks that it did not read

! Ledger writes each warning one time for each place in Ledger that sends it
```

### Upgrading [#upgrading-7]

Install the new version. The stored record does not change. Your code does not change.

If you use the same transaction name again after an attempt that did not commit.
Ledger now marks a completed marker as dead. Ledger does not remove it.
The recovery sweep removes the dead marker after one hour.

You do not have to do anything. A key that holds a leg from before the upgrade settles at the next
read of that key, or at the next write to it.

**The warnings.** Ledger now writes each warning one time. Two identical failures at the same place
in Ledger give one message. The output stays short when many keys have the same problem.

**`UseAsync`.** `Ledger.UseAsync(Defer, Delay, Cancel)` replaces the three task functions that
Ledger gives to the engine. It is for a test that has its own scheduler. Give it nothing to put
the engine functions back.

Ledger uses `Defer` for the queue on one key, and `Delay` for the timeout of a
[`Future`](/docs/reference/future) and for the watch on a slow
[`Observer`](/docs/reference/observer) listener. `Cancel` stops a delay. A game does not have to
call this.


# Advanced reducers (https://xoifaii.github.io/LedgerDocs/docs/concepts/advanced-reducers)



[Writing a reducer](/docs/concepts/reducer) covers the rules. This is what to do once the state is
deep, the op kinds run past a dozen, and the if chain stops being readable.

Nothing here is a dependency. It's all a few lines you paste into your own project.

## Reaching into nested state [#reaching-into-nested-state]

`table.clone` is shallow and the state is deep frozen, so every level you touch needs its own clone.
Two levels down that's still fine:

```luau
local Next = table.clone(State)
Next.Pets = table.clone(State.Pets)
Next.Pets[Op.PetId] = table.clone(State.Pets[Op.PetId])
Next.Pets[Op.PetId].Level += 1
return Next
```

Three levels down it stops being readable. Forget one line and you get `attempt to modify a readonly
table`. Forget it in a branch you rarely reach and you get a fold that disagrees with itself.

Write it once instead:

```luau
local function SetPath<S>(State: S, Path: { any }, Value: any): S
	local Depth = #Path
	if Depth == 0 then
		return Value
	end

	local Root = table.clone(State :: any)
	local Node = Root

	for Index = 1, Depth - 1 do
		local Key = Path[Index]
		local Held = Node[Key]
		assert(
			Held == nil or type(Held) == "table",
			`SetPath: '{tostring(Key)}' holds a {typeof(Held)}, not a table`
		)

		local Fresh = if Held == nil then {} else table.clone(Held)
		Node[Key] = Fresh
		Node = Fresh
	end

	Node[Path[Depth]] = Value
	return Root :: any
end
```

The whole example above becomes one line:

```luau
return SetPath(State, { "Pets", Op.PetId, "Level" }, State.Pets[Op.PetId].Level + 1)
```

Only the path you name gets cloned. Every other subtree stays shared by reference. Ledger then
re-freezes only what changed.

Incrementing needs the old value first. Give that its own function:

```luau
local function UpdatePath<S>(State: S, Path: { any }, Change: (Held: any) -> any, Fallback: any?): S
	local Held: any = State
	for _, Key in Path do
		if type(Held) ~= "table" then
			Held = nil
			break
		end
		Held = Held[Key]
	end

	return SetPath(State, Path, Change(if Held == nil then Fallback else Held))
end
```

```luau
return UpdatePath(State, { "Pets", Op.PetId, "Level" }, function(Level: number): number
	return Level + 1
end, 0)
```

Setting a path to `nil` removes that key, so there's no separate remove.

Changing two or three fields at the top takes a third one, so you don't clone the root once per
field:

```luau
local function Patch<S>(State: S, Changes: { [any]: any }): S
	local Next = table.clone(State :: any)
	for Key, Value in Changes do
		Next[Key] = Value
	end
	return Next :: any
end
```

```luau
return Patch(State, { Coins = State.Coins - 250, Owned = State.Owned + 1 })
```

Those three cover it. `Patch` for fields at the top, `SetPath` to write down a path, `UpdatePath`
to read one and write it back.

## Dispatching without an if chain [#dispatching-without-an-if-chain]

Past a dozen kinds a table of handlers is easier to read. It also stops you shadowing a branch by
accident:

```luau
type Handler = (State: Profile, Op: Ledger.Op) -> Profile?

local Handlers: { [string]: Handler } = {}

function Handlers.SpendGold(State: Profile, Op: Ledger.Op): Profile?
	if type(Op.Amount) ~= "number" or Op.Amount <= 0 or Op.Amount > State.Gold then
		return nil
	end
	return SetPath(State, { "Gold" }, State.Gold - Op.Amount)
end

function Handlers.LevelPet(State: Profile, Op: Ledger.Op): Profile?
	if State.Pets[Op.PetId] == nil then
		return nil
	end
	return UpdatePath(State, { "Pets", Op.PetId, "Level" }, function(Level: number): number
		return Level + 1
	end, 0)
end

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	local Handler = Handlers[Op.Kind]
	if Handler == nil then
		return nil
	end
	return Handler(State, Op)
end
```

A missing handler returns `nil`, which is a refusal. An old server should refuse a kind it has never
heard of. See [ops you don't know](/docs/concepts/reducer#ops-you-dont-know).

### With named ops [#with-named-ops]

A store built with [`NewTyped`](/docs/concepts/typed-ops) hands its reducer the op as one of your
kinds, so the handler table above will not build against it. A handler typed `Ledger.Op` is wider
than the reducer that store asks for.

Narrow on `Op.Kind` first and give each kind its own function. `Ledger.OpOf` picks one kind out of
the map:

```luau
type Ops = {
	SpendGold: { Amount: number },
	LevelPet: { PetId: string },
}

local function SpendGold(State: Profile, Op: Ledger.OpOf<Ops, "SpendGold">): Profile?
	if Op.Amount <= 0 or Op.Amount > State.Gold then
		return nil
	end
	return SetPath(State, { "Gold" }, State.Gold - Op.Amount)
end

local function LevelPet(State: Profile, Op: Ledger.OpOf<Ops, "LevelPet">): Profile?
	if State.Pets[Op.PetId] == nil then
		return nil
	end
	return SetPath(State, { "Pets", Op.PetId, "Level" }, State.Pets[Op.PetId].Level + 1)
end

local function Reducer(State: Profile, Op: Ledger.Op<Ops>): Profile?
	if Op.Kind == "SpendGold" then
		return SpendGold(State, Op)
	elseif Op.Kind == "LevelPet" then
		return LevelPet(State, Op)
	end

	return nil
end
```

`Op.Amount` is a number and `Op.PetId` is a string inside their own handlers, so every `type(...)`
check in this section is gone. Both shapes are read only, so a handler that writes to the op it was
given stops the build whether it took `Ledger.Op<Ops>` or `Ledger.OpOf`.

The if chain comes back with it. A table lookup cannot tell the checker which kind it found, so
narrowing needs the comparison. Keep the handler table and build that store with `Ledger.New` if
the dispatch matters to you more than the field types do.

<Callout type="warn">
  Don't put a `__` prefix on your own kinds. Ledger reserves that for its transfer and transaction
  ops, and `Apply` refuses them with [`Invalid`](/docs/concepts/reasons).
</Callout>

## Splitting by domain [#splitting-by-domain]

Once several people are adding kinds, give each domain its own file and its own slice of the state:

```luau
-- Pets.luau
local Pets = {}

function Pets.Handlers.Hatch(Owned: { [string]: Pet }, Op: Ledger.Op): { [string]: Pet }?
	...
end
```

Then join them at the top, translating each slice's answer back into a whole profile:

```luau
local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	local OnPets = Pets.Handlers[Op.Kind]
	if OnPets ~= nil then
		local Next = OnPets(State.Pets, Op)
		return if Next == nil then nil else SetPath(State, { "Pets" }, Next)
	end

	local OnQuests = Quests.Handlers[Op.Kind]
	if OnQuests ~= nil then
		local Next = OnQuests(State.Quests, Op)
		return if Next == nil then nil else SetPath(State, { "Quests" }, Next)
	end

	return nil
end
```

A slice handler only sees its own subtree. It cannot reach across and couple two domains by accident.
If a kind needs both, handle it at the top.

## What folding costs [#what-folding-costs]

The reducer does not run once per op. It runs once when you `Apply`. It runs again for every op in
the log, on every read that folds the record. In Studio it runs a third time, when Ledger refolds to
check the reducer is pure.

Work that is O(n) in the size of your state, per op, becomes O(n squared) across a fold. Counting a
collection to enforce a cap is the usual cause:

```luau
-- every Hatch walks every pet you own
local Owned = 0
for _ in State.Pets do
	Owned += 1
end
if Owned >= 200 then
	return nil
end
```

Keep the count in the state instead and move it with the collection. A log of 128 ops against a
profile holding 200 pets is 25,600 iterations per fold, on a path that runs on every read.

## Keep the result storable [#keep-the-result-storable]

Whatever the reducer returns gets written as JSON. No metatables, no functions, no NaN, no mixing
array and string keys in one table, no holes in an array.

A hole is easy to make without noticing. The obvious way to remove an item makes one:

```luau
local Next = table.clone(State)
Next.Items = table.clone(State.Items)
Next.Items[Index] = nil     -- leaves a hole
return Next
```

Use `table.remove` on the copy, or rebuild the list, so the array stays dense:

```luau
local Items = table.clone(State.Items)
table.remove(Items, Index)
return SetPath(State, { "Items" }, Items)
```

Ledger refuses to compact a record whose state it cannot store, and warns with the field name.
Nothing is lost. The log keeps growing until you fix it.

## Don't error [#dont-error]

Check the op and return `nil`.

```luau
if type(Op.Amount) ~= "number" then
	return nil
end
```

A reducer that throws is a bug. Ledger catches it, warns with what was raised, and answers `Refused`. See [check the fields](/docs/concepts/reducer#check-the-fields).

## A worked example [#a-worked-example]

A pet game, with an inventory cap, equip slots, and fusing three pets of the same species into one a
level higher.

```luau
type Pet = {
	Species: string,
	Level: number,
	Xp: number,
	Locked: boolean
}

type Profile = {
	Coins: number,
	Pets: { [string]: Pet },
	Owned: number,
	Equipped: { [string]: true },
	Wearing: number,
	Slots: number,
	Discovered: { [string]: true }
}

local MAX_PETS = 200
local FUSE_COUNT = 3
local HATCH_COST = 250
local LEVEL_XP = 100
```

`Owned` and `Wearing` are counts of `Pets` and `Equipped`. They are stored so no handler has to walk
either table.

`Fuse` has nine rules to check, so they get names of their own rather than nine `if`s in a row. Each
one answers a question you could say out loud.

```luau
local function NewPet(Species: string, Level: number): Pet
	return { Species = Species, Level = Level, Xp = 0, Locked = false }
end

-- can this one pet go into a fuse of this species at this level
local function Fusable(State: Profile, Id: string, Species: string, Level: number): boolean
	local Pet = State.Pets[Id]
	if Pet == nil then
		return false
	end
	if Pet.Species ~= Species or Pet.Level ~= Level then
		return false
	end
	return not Pet.Locked and not State.Equipped[Id]
end

-- do these ids name a legal fuse, and if so what are they all
local function FuseInput(State: Profile, Ids: { string }): Pet?
	local Base = State.Pets[Ids[1]]
	if Base == nil then
		return nil
	end

	local Counted: { [string]: true } = {}
	for _, Id in Ids do
		if Counted[Id] or not Fusable(State, Id, Base.Species, Base.Level) then
			return nil
		end
		Counted[Id] = true
	end
	return Base
end
```

Then the handlers themselves stay short.

```luau
type Handler = (State: Profile, Op: Ledger.Op) -> Profile?

local Handlers: { [string]: Handler } = {}

function Handlers.Hatch(State: Profile, Op: Ledger.Op): Profile?
	if type(Op.PetId) ~= "string" or type(Op.Species) ~= "string" then
		return nil
	end
	if State.Pets[Op.PetId] ~= nil then
		return nil
	end
	if State.Owned >= MAX_PETS or State.Coins < HATCH_COST then
		return nil
	end

	local Next = Patch(State, { Coins = State.Coins - HATCH_COST, Owned = State.Owned + 1 })
	Next = SetPath(Next, { "Pets", Op.PetId }, NewPet(Op.Species, 1))

	if State.Discovered[Op.Species] == nil then
		Next = SetPath(Next, { "Discovered", Op.Species }, true)
	end
	return Next
end

function Handlers.Feed(State: Profile, Op: Ledger.Op): Profile?
	if type(Op.PetId) ~= "string" or type(Op.Xp) ~= "number" or Op.Xp <= 0 then
		return nil
	end

	local Pet = State.Pets[Op.PetId]
	if Pet == nil then
		return nil
	end

	local Gained = Pet.Xp + Op.Xp
	local Next = SetPath(State, { "Pets", Op.PetId, "Xp" }, Gained % LEVEL_XP)
	return UpdatePath(Next, { "Pets", Op.PetId, "Level" }, function(Level: number): number
		return Level + Gained // LEVEL_XP
	end, 1)
end

function Handlers.Equip(State: Profile, Op: Ledger.Op): Profile?
	if type(Op.PetId) ~= "string" then
		return nil
	end
	if State.Pets[Op.PetId] == nil or State.Equipped[Op.PetId] then
		return nil
	end
	if State.Wearing >= State.Slots then
		return nil
	end

	local Next = Patch(State, { Wearing = State.Wearing + 1 })
	return SetPath(Next, { "Equipped", Op.PetId }, true)
end

function Handlers.Sell(State: Profile, Op: Ledger.Op): Profile?
	if type(Op.PetId) ~= "string" then
		return nil
	end

	local Pet = State.Pets[Op.PetId]
	if Pet == nil or Pet.Locked or State.Equipped[Op.PetId] then
		return nil
	end

	local Next = Patch(State, { Owned = State.Owned - 1, Coins = State.Coins + 50 * Pet.Level })
	return SetPath(Next, { "Pets", Op.PetId }, nil)
end

function Handlers.Fuse(State: Profile, Op: Ledger.Op): Profile?
	if type(Op.PetIds) ~= "table" or #Op.PetIds ~= FUSE_COUNT then
		return nil
	end
	if type(Op.PetId) ~= "string" or State.Pets[Op.PetId] ~= nil then
		return nil
	end

	local Base = FuseInput(State, Op.PetIds)
	if Base == nil then
		return nil
	end

	local Next: Profile = State
	for _, Id in Op.PetIds do
		Next = SetPath(Next, { "Pets", Id }, nil)
	end
	Next = SetPath(Next, { "Pets", Op.PetId }, NewPet(Base.Species, Base.Level + 1))

	return Patch(Next, { Owned = State.Owned - FUSE_COUNT + 1 })
end

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	local Handler = Handlers[Op.Kind]
	if Handler == nil then
		return nil
	end
	return Handler(State, Op)
end
```

Seven things in there need explaining.

**The species is `Op.Species`, and the pet id is `Op.PetId`.** `Id` and `Kind` belong to Ledger, and
`Op.Kind` here is already `"Hatch"`. Name your own fields something else or Ledger overwrites them
with a warning.

**The caller picks the id and rolls the species.** The reducer cannot call `math.random`, so both
arrive on the op. The server rolls, then writes down what it rolled.

**`Counted` in `FuseInput` is the one that matters.** Without it, `PetIds = { "a", "a", "a" }` passes every
other check. It deletes one pet and hands back one a level higher, which is a duplication exploit.
The removal loop cannot catch it either, since removing the same key three times removes it once.

**`Fuse` chains `SetPath` down its list.** Each call clones the root and `Pets` again, which is four
clones for three pets. That is fine here. If you were removing hundreds at once, clone `Pets` once by
hand and write into that instead.

**Nothing counts anything.** `Owned` and `Wearing` move with the tables they describe, so hatching the
two hundredth pet costs the same as the first.

**Every refusal is `nil`.** The caller gets `Refused` whether the player was broke, full, or holding a
locked pet. If you want to tell them which, check before you write:

```luau
if State.Coins < HATCH_COST then
	Tell(Player, "you need 250 coins")
	return
end

Session:Apply("Hatch", { PetId = HttpService:GenerateGUID(false), Species = Roll() })
```

The reducer still checks. The check in front is for the message, and the one inside is the rule.


# Apply and Commit (https://xoifaii.github.io/LedgerDocs/docs/concepts/apply-and-commit)



Both of them write an op. The difference is when you find out it stuck.

|                            | `Apply`              | `Commit`                   |
| -------------------------- | -------------------- | -------------------------- |
| Gives you                  | `(boolean, Reason?)` | `Future<boolean, Reason?>` |
| Yields                     | no                   | yes, on `:Wait()`          |
| Durable when it answers    | no                   | yes                        |
| Costs a datastore request  | no                   | yes                        |
| Sees other servers' writes | no                   | yes                        |

## Apply [#apply]

`Apply` runs your reducer against live state, updates it, tells observers, and queues the op. It
never touches the datastore. The op goes out on the next autosave, which runs every 30 seconds, or
on the next `Flush`, `Commit` or `Unload`.

```luau
local Ok, Why = Session:Apply("SpendGold", { Amount = 25 })
```

Use it by default, for whatever the player is doing right now. Spending, picking things up,
progression, stats.

The answer is local. It knows what this server has, and not what another server appended a second
ago. Normally a player writes from one server only, so that's fine.

### When the answer changes under you [#when-the-answer-changes-under-you]

`Apply` returns `true` straight away, and the op only reaches the log on the next save. If another
server wrote to that key in between, the fold can refuse your op when it finally lands, after you
already told the player it worked.

You only see it when two different ops compete for the same rule. The same op twice looks fine, since
both servers reach the same number either way. Two different ops don't:

```luau
-- 100 gold. server A spends 80, server B spends 30, neither knows about the other
A:Apply("SpendGold", { Amount = 80 })   -- A shows 20
B:Apply("SpendGold", { Amount = 30 })   -- B shows 70

-- both ops reach the log. A's lands first, so B's would take the balance negative
-- and the reducer refuses it. B's player watches 70 become 20
```

Nothing is lost or double spent, and every server agrees once it settles. The player on B still saw a
number that was never true.

Render from state, not from the return value. The correction then arrives on its own through
[`Observe`](/docs/reference/observer). Use `Commit` where a wrong number for a moment is worse than
waiting.

## Commit [#commit]

`Commit` pushes everything queued, appends the op, waits for the datastore to take it, refolds from
what came back, and only then answers.

```luau
local Ok, Why = Session:Commit("GrantReward", { Item = "Sword" }):Wait()
if Ok then
	GiveTheSword()
end
```

Use it when you're about to do something you can't take back. Handing out a purchase, calling a
webhook, telling another service the thing happened. `true` means the op is in the log, your reducer
took it, and every server will agree from here on.

The fold runs against the real record, so `Commit` sees other servers' writes. A stuck
[transaction](/docs/guides/transactions) leg on the key can still change the answer afterwards. When
that is possible, `Commit` says [`Unresolved`](/docs/concepts/reasons).

## CommitOp [#commitop]

`CommitOp` takes an op table you built yourself, so you can put a `Once` name on it or reuse an id
across a retry:

```luau
local Ok, Why = Session:CommitOp({
	Id = HttpService:GenerateGUID(false),
	Kind = "GrantReward",
	Item = "Sword",
	Once = `order:{OrderId}`,
}):Wait()
```

`Id` and `Kind` are required. `Once` is optional, and it makes the op apply at most one time on that
key. See [Once](/docs/concepts/once).

## Which one [#which-one]

Apply for gameplay, Commit for side effects.

If the player wouldn't notice a rollback, `Apply`. If someone would file a ticket about it,
`Commit`.

## Flush [#flush]

`Session:Flush()` pushes queued ops without adding one. Autosave calls it. You rarely need it
yourself, but it's there for the moment before you do something risky:

```luau
Session:Flush():Wait()
```

## Many ops, one request [#many-ops-one-request]

A flush writes the whole queue in one request. The number of ops does not change this. Use it when
one action of a player must change more than one part of their data.

| call             | requests                                |
| ---------------- | --------------------------------------- |
| `Session:Apply`  | none                                    |
| `Session:Flush`  | one, for the whole queue                |
| `Session:Commit` | one, or two when ops are already queued |
| `Store:Edit`     | one, and it takes one op                |

```luau
Session:Apply("Coins", { Amount = 500 })
Session:Apply("Sword")
Session:Flush():Wait()
```

Two ops, and one request. Three `Commit` calls cost three requests. Each `Commit` is durable before
it answers. A `Commit` also writes the queued ops first, if there are any.

The ops go in together. Each op is still folded on its own. If the reducer refuses one op, the
other ops stay applied. Write one op when a grant must be all or nothing. Let the reducer make each
change for that one op. One op cannot apply in part.


# Handling failures (https://xoifaii.github.io/LedgerDocs/docs/concepts/handling-failure)



Most code only cares about two things: did it work, and can I ask again.

```luau
local Ok, Why = Store:Edit(UserId, "GrantItem", { Item = "Sword" }):Wait()

if Ok then
	-- it went through, and a retry under the same id would answer true again
elseif Why == Ledger.Reason.Unresolved or Why == Ledger.Reason.Busy then
	-- no answer yet, ask again later with the same id
else
	-- Refused, Spent, Closed, Backlog, Full, Invalid, Behind:
	-- it didn't happen, and asking again with this id won't change that
end
```

Reads answer the same way with the value in front:

```luau
local State, Why = Store:Peek(UserId):Wait()
if State == nil then
	-- Why says which of the failures it was
	return
end
```

A key nobody has ever written folds to your `Default`, so a read never gives you `nil` on success.
`nil` always means it failed.

## Why a retry is safe [#why-a-retry-is-safe]

Every op carries an id, and an id applies at most once on a key. A retry that already went through
answers `true` and moves nothing the second time. That holds for
[`Once`](/docs/concepts/once) names, transfer ids and transaction ids.

The id has to be the same one. Build it before the call and keep it for the retry:

```luau
local OrderId = `order:{Receipt.PurchaseId}`

local Ok, Why = Store:Edit(UserId, "Grant", { ProductId = 123, Once = OrderId }):Wait()
if Why == Ledger.Reason.Unresolved then
	-- same OrderId, so the retry costs nothing if the first one applied
	Ok = Store:DidApply(UserId, OrderId):Wait() == true
end
```

Generate a new id on the retry and Ledger has nothing to match it against, so the retry applies a
second time.

## Unresolved [#unresolved]

Ledger doesn't know whether the write applied. `Unresolved` does not mean no. Treat it as a refusal
and you will eventually refuse something that already went through, which costs you money.

**Retry with the same id.** See above. Without an id you have no way to ask again safely.

**Ask instead of guessing.** [`Store:DidApply(Key, Name)`](/docs/reference/store#didapply) says
whether a `Once` name applied. Compare it against `true`, because a failed read gives `nil`.

**In `ProcessReceipt`, answer `NotProcessedYet`.** Roblox calls you again, and the next call gets a
straight answer. The full pattern is in [Once](/docs/concepts/once#processreceipt).

**For a stuck leg, [`Store:Resettle(Key)`](/docs/reference/store#resettle) settles it now** instead
of waiting for the sweep. `true` means the key has nothing unfinished on it.

## Spent [#spent]

Nothing was applied. `Spent` looks like success and it isn't.

For a transfer the money is **back with the sender**. Hand out the item on a `Spent` and you have
paid for something that was refunded.

`true` is the answer that means "already happened". Call `Transfer` again with an id that delivered,
or `Tx` again with an id that committed, and you get `true` with nothing moved.

So on `Spent`, decide what to do about a name you can't reuse. Read the keys, pick a new id, or tell
the player it didn't go through. See [Ids and retries](/docs/guides/transfers#ids-and-retries) and
[The id](/docs/guides/transactions#the-id).

## Behind [#behind]

Retrying is pointless. This server is running an older build than the one that wrote the record, so
nothing changes until the deploy finishes.

<Callout type="warn">
  Never treat `Behind` as "this player has no data". The record is fine. Writing a fresh profile over
  the top would destroy it.
</Callout>

Pass [`OnLoadFailed`](/docs/reference/ledger#onloadfailed) if you deploy while people are playing. A
rejoin puts them back on the same old server, so `Behind` wants a teleport. See
[Rolling deploys](/docs/guides/migrations#rolling-deploys).

## The rest [#the-rest]

| Reason    | What to do                                                                                                                    |
| --------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `Refused` | Your own rule said no. Tell the player.                                                                                       |
| `Busy`    | Retry in a few seconds. See [Stuck legs](/docs/guides/transactions#stuck-legs).                                               |
| `Closed`  | The session is gone. Write before `Unload`, see [Shutting down](/docs/guides/sessions#shutting-down).                         |
| `Backlog` | Saves aren't going through. Stop writing and look at the datastore, see [Autosave](/docs/guides/sessions#autosave).           |
| `Full`    | Remove something first, see [Size](/docs/limits#size).                                                                        |
| `Invalid` | A bug in the calling code. Ledger warns with the field, see [What you can store](/docs/concepts/the-fold#what-you-can-store). |


# Once (https://xoifaii.github.io/LedgerDocs/docs/concepts/once)



Every op Ledger writes already has an id, so a retry can't apply twice. The catch is that the id is
generated when the op is made, so if your code crashes and rebuilds the op, it's a different op with
a different id, and it applies again.

`Once` fixes that. You give the op a name that comes from outside your game, and Ledger applies it
at most one time on that key.

```luau
Session:CommitOp({
	Id = HttpService:GenerateGUID(false),
	Kind = "ProductGrant",
	ProductId = 123456,
	Once = `receipt:{Receipt.PurchaseId}`,
}):Wait()
```

The name is remembered inside the profile, under `_Received`, so it survives a compaction, a rejoin,
and two servers racing the same replay.

## ProcessReceipt [#processreceipt]

This is what `Once` was built for. Roblox keeps calling `ProcessReceipt` until you answer
`PurchaseGranted`. There is no timer on it. A receipt you answered `NotProcessedYet` on comes back
when the player buys another developer product on this server, or when they join any server in the
experience again.

Roblox can also fail to record your answer after you already said granted, so a retry follows a
perfectly healthy grant. Two servers can even run the same receipt at the same time if the player
joins the second one before the first answered.

<Callout type="warn">
  Assign `MarketplaceService.ProcessReceipt` as early as you can. Roblox acknowledges receipts on its
  own while no callback is assigned, and an acknowledged receipt can never be handed back. Assign it
  first and let the callback yield for your store, instead of loading the store and then assigning.
</Callout>

So the grant has to happen at most once, and you still have to say granted on every replay after
that.

```luau
MarketplaceService.ProcessReceipt = function(Receipt)
	local Player = Players:GetPlayerByUserId(Receipt.PlayerId)
	if not Player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local Session = Store:WaitForLoaded(Player)
	if not Session then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local Name = `receipt:{Receipt.PurchaseId}`
	local _, Why = Session:Commit("ProductGrant", {
		ProductId = Receipt.ProductId,
		Once = Name,
	}):Wait()

	if Why == Ledger.Reason.Unresolved or not Session:DidApply(Name) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end
```

Three things in there need explaining.

**`WaitForLoaded`, not `Get`.** The callback fires as the player joins, which can be before their
profile is loaded, and a `ProcessReceipt` callback is allowed to yield for as long as the server
runs. Answering `NotProcessedYet` because the session wasn't ready spends a whole retry, and the next
one waits for another purchase or a rejoin.

**`DidApply`, not the Commit result.** `Commit` tells you whether this call changed anything. The
first one did. Every replay after it doesn't, and every replay after it is still a granted purchase.
`DidApply` answers the question Roblox is actually asking.

```luau
Store:Edit(UserId, "ProductGrant", { ProductId = 123, Once = "receipt:abc" }):Wait()
--> true, nil

Store:Edit(UserId, "ProductGrant", { ProductId = 123, Once = "receipt:abc" }):Wait()
--> false, "Refused"

Store:DidApply(UserId, "receipt:abc"):Wait()
--> true, nil
```

A replay answers `Refused`. Your reducer answers `Refused` too, so the boolean cannot tell you which
one happened. `DidApply` can.

**Check `Unresolved` first.** It means there's no settled answer yet, so `DidApply` might be reading
a fold that a stuck transaction can still flip. Answer `NotProcessedYet` and let the retry ask again
once things are settled.

<Callout type="warn">
  Never answer `PurchaseGranted` for something you aren't sure went through. An unresolved purchase
  is never refunded, so the player loses the Robux and gets nothing.
</Callout>

## Ids you pick yourself [#ids-you-pick-yourself]

`Once` is for any id you didn't make up on the spot. A support tool order, a webhook delivery, a
gamepass unlock.

### Gamepasses [#gamepasses]

A gamepass has no `ProcessReceipt` and no receipt id. Roblox stores whether the player owns the pass,
so you don't have to. You store what the pass gave them.

`UserOwnsGamePassAsync` answers whether they own it. Two things about it cost money.

<Callout type="warn">
  `UserOwnsGamePassAsync` throws when the request fails, and it fails often under load. Wrap it in a
  `pcall`. Never turn a thrown call into `false`. `false` means "does not own it", so you would take
  the pass away from a player who paid for it.
</Callout>

Roblox caches the answer per player, per pass, per server. A purchase made in your experience updates
that cache when `PromptGamePassPurchaseFinished` fires, so you don't have to track it yourself. A
purchase made outside the experience takes several minutes to reach the cache.

So the only thing you have to add is the `nil`:

```luau
-- true owns it, false does not, nil the check failed and you should not act on it
local function OwnsPass(Player: Player, PassId: number): boolean?
	local Ok, Has = pcall(function(): boolean
		return MarketplaceService:UserOwnsGamePassAsync(Player.UserId, PassId)
	end)
	return if Ok then Has else nil
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(Player, PassId, Purchased)
	if Purchased then
		GrantPass(Player, PassId)
	end
end)
```

Handle `nil` by doing nothing and asking again later. Don't remove a perk. Don't hide the button.
Don't prompt them to buy a pass they already own.

`PromptGamePassPurchaseFinished` only fires on the server that showed the prompt.

Then grant it:

```luau
local function GrantPass(Player: Player, PassId: number)
	local Session = Store:WaitForLoaded(Player)
	if not Session then
		return
	end

	Session:Commit("GrantPass", { Pass = tostring(PassId), Once = `pass:{PassId}` }):Wait()
end
```

The reducer is what stops a second grant. Ledger forgets a `Once` name after 30 days and a gamepass
lasts forever, so the name only covers the retries:

```luau
if Op.Kind == "GrantPass" then
	if State.Passes[Op.Pass] then
		return nil
	end

	local Next = table.clone(State)
	Next.Passes = table.clone(State.Passes)
	Next.Passes[Op.Pass] = true
	Next.Gold += 1000
	return Next
end
```

`Op.Pass` is a string. A table with number keys is an array, and an array with gaps cannot be
stored. See [What you can store](/docs/concepts/the-fold#what-you-can-store).

The event misses a purchase made on another server, on the website, or before you shipped the pass.
So check on join too:

```luau
for _, PassId in PASSES do
	if OwnsPass(Player, PassId) == true then
		GrantPass(Player, PassId)
	end
end
```

`== true`, so a failed check does nothing this time. Call `GrantPass` for every pass they own. The
reducer refuses the ones they already have, so you don't have to work out which are new.

With a reducer guard like that one, the `Once` name is doing nothing you need. Keep it for a grant
your reducer can't check, like a one off currency top up, where the name is the only thing between
you and paying twice.

### Someone who isn't in this server at all [#someone-who-isnt-in-this-server-at-all]

```luau
local function GrantOffline(Store, UserId: number, ProductId: number, OrderId: string): (boolean, Ledger.Reason?)
	local Name = `order:{OrderId}`
	Store:Edit(UserId, "ProductGrant", { ProductId = ProductId, Once = Name }):Wait()

	local Applied, Why = Store:DidApply(UserId, Name):Wait()
	return Applied == true, Why
end
```

`Applied == true` rather than `if Applied then`, so a read that failed comes back as "don't know"
with a reason instead of being mistaken for "not granted".

## DidApply [#didapply]

`Session:DidApply(Name)` and `Store:DidApply(Key, Name)` both answer whether a `Once` name ever
applied on that key. The session version reads live state, returns a plain `boolean`, and can't
fail. The store version reads the record and gives you a `Future<boolean?, Reason?>`.

<Callout type="warn">
  `Store:DidApply` answers `nil` when it couldn't read the record at all, which is not the same as
  `false`. Compare against `true`, not truthiness, or a datastore hiccup reads as "never granted"
  and you hand out the reward a second time.
</Callout>

It's asking about the name, not about this call, which is exactly why it's the right thing to check
on a replay.

<Callout type="warn">
  A name lives on one key of one store. Ask `DidApply` on the store that the name was written to.

  A handler can grant on a profile store and record the sale on a second store. It then needs one
  name for each store. Check each name on its own store.

  If you ask the profile store about a name on the record store, the answer is always `false`. The
  write is refused because it is a replay. The check says that it never landed. The handler never
  finishes, and the receipt comes back for ever.
</Callout>

`Session:DidApply` reads live state. Live state includes the ops that wait for the next save.
`Apply` puts a name in that queue, so the answer is `true` before the op is written. On a receipt,
grant with `Commit`. You can also `Apply` and then `Flush`. A granted answer then means a saved
grant.

## How long a name is remembered [#how-long-a-name-is-remembered]

Long enough that you don't have to think about it, and not so long that the set grows forever.

A name is written into the applied set with the time it was applied. The next time any name is
written to that key, anything in the set older than 30 days goes. So the set is a rolling window
rather than a pile that only gets bigger.

The check for an already applied name happens before any of that, and against everything still in
the set. So a player who wanders off for two months and comes back to a receipt Roblox is still
retrying is fine: nothing was written while they were away, so nothing was swept, and the name is
still sitting there.

```luau
Store:Edit(UserId, "Grant", { Once = "old" }):Wait()

-- 40 days later, nothing written on the key in between
Store:DidApply(UserId, "old"):Wait()          --> true
Store:Edit(UserId, "Grant", { Once = "old" }):Wait()   --> false, "Refused"

-- one new name is written, which sweeps everything past the window
Store:Edit(UserId, "Grant", { Once = "fresh" }):Wait()
Store:DidApply(UserId, "old"):Wait()          --> false
Store:Edit(UserId, "Grant", { Once = "old" }):Wait()   --> true, it applies again
```

What it does not cover is a receipt still unsettled after 30 days of the same player buying other
things. That means a month of your grant failing every time, which is a bigger problem than the
dedupe.

<Callout type="warn">
  So `Once` is for retry windows, not for names that stay meaningful forever. A support ticket
  reopened two months later, or an unlock you want to be permanent, is outside the window.
  Put that rule in the reducer instead.
</Callout>

The [gamepass example](#gamepasses) above shows both halves. `pass:{PassId}` stops the retries. The
reducer refusing on `State.Passes[Op.Pass]` is what stops a second grant a year later.

## Rules [#rules]

The name has to be a non empty string. Anything else is refused with
[`Invalid`](/docs/concepts/reasons) on every surface, and nothing applies. A name usually comes from
outside your game, so a receipt id that arrives as `nil` gives you a reason to read.

Names are namespaced, so a `Once` name can't collide with a transfer id or a transaction id even if
they're spelled the same.

Your reducer never has to dedupe. By the time it runs, `Once` has already decided. Write the branch
as if it only ever runs one time, because it does.

Don't put `Once` on a [transaction](/docs/guides/transactions) leg. The transaction id already makes
every leg land at most once, and Ledger throws if you pass one anyway.


# Reasons (https://xoifaii.github.io/LedgerDocs/docs/concepts/reasons)



Anything that can fail tells you why. Writes answer `(boolean, Reason?)` and reads answer
`(value?, Reason?)`, and there are only ten reasons. They live on `Ledger.Reason`, so you can
compare against the constant instead of a string literal.

```luau
local Ok, Why = Session:Commit("SpendGold", { Amount = 25 }):Wait()
if not Ok and Why == Ledger.Reason.Refused then
	Tell(Player, "you can't afford that")
end
```

This page says what each one means. [Handling failures](/docs/concepts/handling-failure) says what to
do about them.

## Refused [#refused]

Your reducer returned `nil`. The op was legal to write, it just wasn't allowed to happen, so the
player couldn't afford it, or already owns it, or whatever your rule was. This is the only reason
that came from your own code, and it's the only one that's a normal part of gameplay.

Nothing changed. Don't retry it, the answer won't be different.

## Busy [#busy]

Someone else is in the middle of a transaction on that key and it hasn't finished yet. Nothing
changed.

Ledger puts the key on the [recovery sweep](/docs/guides/recovery#sweeping), which runs every 60
seconds. Your own retry usually gets there first, because every read and write settles what it finds
pending on the key before doing anything else. Retry in a few seconds.

`Session:Apply` also answers this when the key has hit its 1.5 MB op cap and a parked transaction is
stopping it compacting. The datastore is fine. Retry once the transaction settles.

`Tx` does not retry a `Busy` for you. Every server retrying at once would pile more load onto a key
that is already contended, so the backoff is yours to write. See
[One key at a time](/docs/limits#one-key-at-a-time).

## Spent [#spent]

That name is used up and nothing was applied.

For a transfer it means the money went **back to the sender**. The hold sat there long enough to
expire and Ledger refunded it. The id is kept afterwards so a late retry can't pay out against a
refund that already happened.

For a transaction it means the name can't be used for what you asked. Either that name already ran for
a different set of keys or a different amount, or an earlier attempt was cancelled part way. Ledger
would rather refuse than half apply it. A transfer answers `Spent` for the same reason, so asking
again under a name that already went through, for a different amount or a different key, gets `Spent`
instead of `true`.

`Spent` says this attempt changed nothing. It does not promise the name can never work again. A name
whose transaction was cancelled before any leg applied is free to use, and that is what lets a retry
finish a cancelled attempt. A name that already moved money is done.

<Callout type="warn">
  `Spent` is not success. Nothing moved, and for a transfer the money is back where it started. See
  [Spent](/docs/concepts/handling-failure#spent).
</Callout>

## Held [#held]

A transfer took the money and could not hand it over, because the receiving key was erased. This is
not "nothing happened". The amount has left the sender and is set aside with them.

Ledger gives it back on its own, and recovery follows that key until it does. Tell the sender their
money is coming back rather than that the transfer failed. Don't send it again under a new name, or
they pay twice.

A [reservation](/docs/guides/reservations) never answers it. A hold lives in MemoryStore and takes
nothing off the key, so there is nothing to be set aside.

## Unresolved [#unresolved]

Ledger doesn't know. Either the datastore call failed in a way that might still have written, or a
transaction leg is parked on the key and the fold can change once it settles.

`Session:Apply` answers this when a transaction is parked and your op only holds if that transaction
does not go through. Ledger folds both futures and only answers when they agree. Ask again once the
transaction settles.

`Unresolved` does not mean no, and it is the one that costs money if you treat it as a refusal. See
[Unresolved](/docs/concepts/handling-failure#unresolved).

## Closed [#closed]

The session is gone. The player left and it was released, or the store was destroyed. Anything you
write to it now goes nowhere.

## Backlog [#backlog]

Ops are piling up because saves aren't going through. Either 4096 ops are queued or they've hit the
1.5 MB cap on unsaved bytes. This basically only happens when the datastore is down.

Nothing changed. This is a signal to stop writing and look at what's wrong, not to retry harder.

## Full [#full]

The profile is at the 2 MB cap and the op would make it bigger. Ledger lets ops through that shrink
it, so a cleanup still works.

`Store:Edit` answers this when the key already carries 1.5 MB of ops that have not been compacted
away. That happens when a parked transaction is stopping the key compacting. It clears once the
transaction settles.

Nothing changed. You need to remove something before you can add anything.

## Invalid [#invalid]

The op can't be stored. Something in the fields isn't JSON, so an Instance, a function, a cyclic
table, a table mixing array and dictionary keys, NaN, inf. Or the fields use a name Ledger reserves,
or the kind starts with `__`. Or your reducer handed back something that wasn't a table.

`Edit`, `Apply`, `Commit` and `Tx` all answer this the same way, and for `Tx` it means one of the
legs, so nothing was prepared on any key.

Nothing changed. This is a bug in the calling code, and Ledger warns with the specific field.

## Behind [#behind]

A newer server wrote that record and this one can't read it. Either the stored format is newer than
this server's build, or the record needs a migration this build doesn't have.

Nothing changed, and retrying is pointless. `Behind` describes which version of your game this server
is running, so nothing about the datastore will change it. It clears when the deploy finishes and
every server is on the same build.

You'll only see it during a rolling deploy, and only on records a newer server already touched. If
you see it after a deploy has finished, someone is running an old build.

<Callout type="warn">
  Never treat `Behind` as "this player has no data". The record is fine. This server is the problem,
  and writing a fresh profile over the top would destroy it. See
  [Behind](/docs/concepts/handling-failure#behind).
</Callout>


# Writing a reducer (https://xoifaii.github.io/LedgerDocs/docs/concepts/reducer)



```luau
type Reducer<S> = (State: S, Op: Op) -> S?
```

The reducer takes the state and one op, and gives back the next state or `nil` to refuse. It's the
only place in your game that decides whether a change is allowed.

```luau
local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	if Op.Kind == "SpendGold" then
		if type(Op.Amount) ~= "number" or Op.Amount <= 0 then
			return nil
		end
		if Op.Amount > State.Gold then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold -= Op.Amount
		return Next
	end

	return nil
end
```

## It has to be pure [#it-has-to-be-pure]

The same `(State, Op)` has to give the same answer on every server, forever. No `os.time()`, no
`math.random()`, no `game`, no upvalues that move, no reading someone else's data. If you need the
time or a dice roll, work it out at the call site and put it on the op:

```luau
Session:Apply("DailyBonus", { At = os.time(), Roll = math.random(1, 6) })
```

A log gets folded on two servers at two different moments. If the reducer reads the clock, those two
folds disagree and your data quietly splits in half.

<Callout type="warn">
  In Studio, Ledger refolds the log after every commit and compares it against live state. If they
  don't match it warns and names the field that moved. That check doesn't run in production, so
  fix what it points at rather than shipping around it.
</Callout>

## It has to not mutate [#it-has-to-not-mutate]

Return a new table. `table.clone` is shallow, so clone each nested table you touch:

```luau
local Next = table.clone(State)
Next.Gamepasses = table.clone(State.Gamepasses)
Next.Gamepasses[Pass] = true
return Next
```

The state you get handed is deep frozen, so a mutation throws on the line that did it instead of
corrupting a fold somewhere later.

Cloning by hand stops reading well about three levels down. [Advanced
reducers](/docs/concepts/advanced-reducers) has a `SetPath` that clones only the path you name.

Freezing can't cover a buffer, because Luau has no way to freeze one. State can hold buffers, and
Ledger copies them instead of sharing them, so writing into one can't reach another server or another
session. It does still change the state you're holding, and the fold won't agree with itself
afterwards. Build a new buffer instead of writing into the one you were given.

A buffer in `Default` works, and each key gets its own copy. Ledger used to hand every key that had
not stored one yet the same buffer, so one key writing into it changed what all of them read.

Don't freeze what you hand back. Ledger freezes it for you, all the way down. A table you froze
yourself carries no promise about the tables inside it, so Ledger has to walk it in full, which costs
more than letting Ledger do the freezing.

## It has to not yield [#it-has-to-not-yield]

No `task.wait`, no `:Wait()`, no yielding datastore calls. Ledger runs the reducer inside a guard
that errors if it yields.

## It has to return a table or nil [#it-has-to-return-a-table-or-nil]

Anything else is a bug. Ledger refuses the op with [`Invalid`](/docs/concepts/reasons) and warns.

## Leave the reserved fields alone [#leave-the-reserved-fields-alone]

`table.clone(State)` carries `_Received` and `_Held` across for free, so most reducers never think
about them.

If you build the next state from scratch and drop them, Ledger puts them back, so you can't lose the
applied id set that way. It won't always catch you writing your own values into them. A store with a
`Balance` overwrites those, but a store without one keeps a hand built `_Received`, and that breaks
the dedupe.

So don't drop them, and don't write to them. Read them if you want, they're just data.

## Ops you don't know [#ops-you-dont-know]

Return `nil` for anything you don't recognise. Ledger treats that as a refusal, and it makes a
rolling deploy safe. An old server that's never heard of `NewFeatureOp` refuses it instead of
guessing at it.

That's a kind you don't know yet. A kind you've deleted is the other way round, because nothing is
ever going to accept it, and refusing one of those stops the key compacting for good. See [changing
the reducer](/docs/guides/migrations#changing-the-reducer).

## Check the fields [#check-the-fields]

Ops come from your own code, but they also come back out of a datastore that's been holding them for
weeks, possibly written by a version of your game that doesn't exist anymore. Check the types on the
way in. A reducer that does `State.Gold -= Op.Amount` without checking `Op.Amount` is a number will
happily hand you `nil` gold and take the profile with it.

Naming your ops does that checking for you. `Ledger.NewTyped` takes a map of the kind to the fields
it carries, and then `Op.Amount` is a number inside the branch that handles it. See [Typed
ops](/docs/concepts/typed-ops).

## Coming from Rodux or Redux [#coming-from-rodux-or-redux]

The shape is close enough that people reach for it straight away. An op is an action, `Op.Kind` is
`action.type`, and a handler table keyed by kind reads a lot nicer than a long `if` chain.

That part is fine. Two of the conventions are backwards here though, and both of them cost you money
rather than throwing.

### nil means refused, not unhandled [#nil-means-refused-not-unhandled]

In Redux the default case returns the state unchanged, and returning nothing is an error. Here it's
the other way round. Ledger reads any table you return as accepted, including the exact state you
were handed. Returning `nil` is the only way to refuse.

So a Redux style default case accepts every op you never wrote a handler for:

```luau
-- wrong here, right in Redux
local function Reducer(State, Op)
	local Handler = Handlers[Op.Kind]
	if Handler == nil then
		return State  -- Ledger reads this as "yes, applied"
	end
	return Handler(State, Op)
end
```

That isn't a harmless no-op. An op carrying a [`Once`](/docs/concepts/once) name gets that name
written into the applied set the moment your reducer hands back a table, so the receipt is marked
granted while nothing was granted. `DidApply` says true, the retry never comes, and the player is
out the Robux. A transaction leg does the same thing and commits on a key that did nothing.

The fix is one word:

```luau
local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	local Handler = Handlers[Op.Kind]
	if Handler == nil then
		return nil  -- refused
	end
	return Handler(State, Op)
end
```

Every handler in the table returns `nil` to refuse too, same as it would inline.

### combineReducers can't refuse [#combinereducers-cant-refuse]

`combineReducers` builds a fresh table out of every slice on every action. It therefore always
returns a table, which here means it always accepts. A slice that wanted to refuse has no way to say
so, because the combined result is a table either way.

It's worse than losing the refusal. In Lua, a slice returning `nil` assigns `nil` into the combined
table, which deletes that key. So the refusal doesn't just get swallowed, it takes the field with
it.

Route by kind instead and let `nil` come straight back up:

```luau
local Slices = {
	SpendGold = function(State, Op)
		if Op.Amount > State.Gold then
			return nil
		end
		local Next = table.clone(State)
		Next.Gold -= Op.Amount
		return Next
	end,

	UnlockGamepass = function(State, Op)
		if State.Gamepasses[Op.Pass] then
			return nil
		end
		local Next = table.clone(State)
		Next.Gamepasses = table.clone(State.Gamepasses)
		Next.Gamepasses[Op.Pass] = true
		return Next
	end,
}

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	local Slice = Slices[Op.Kind]
	return if Slice then Slice(State, Op) else nil
end
```

Each handler still owns one field, which is what you wanted `combineReducers` for. It just returns
the whole state rather than a slice of it, so a refusal is still a refusal.

### The rest of Rodux doesn't come with it [#the-rest-of-rodux-doesnt-come-with-it]

Don't build a `Rodux.Store`. Ledger is the store, state lives in the log, and `Session:Observe()` is
your subscribe. Two stores holding the same data is how they drift apart.

No middleware and no thunks. The reducer can't yield, so anything async happens before you call
`Apply` or `Commit`, and the result rides in on the op.

No Immer style drafts either. State is deep frozen, so mutating it throws on the line that did it.
Clone what you touch.

One convention does carry over cleanly. Redux asks you to keep actions serializable by convention.
Ledger enforces it, because ops go in a datastore, and an op that isn't JSON is refused with
[`Invalid`](/docs/concepts/reasons) instead of failing at save time.

## Balance and transactions [#balance-and-transactions]

If the store names a `Balance` field, Ledger wraps your reducer with the transfer ops
(`__TransferReserve`, `__TransferDeliver` and the rest) before it ever reaches you. You never handle
those kinds and you'll never see them in your `if` chain. Same goes for transaction bookkeeping and
`Store:Reset`.


# The fold (https://xoifaii.github.io/LedgerDocs/docs/concepts/the-fold)



Every key Ledger owns holds a record, not a state table. A record is a snapshot plus the ops that
have been appended since that snapshot was taken.

```luau
State = fold(Snapshot, Ops)
```

Reading a key means loading the record and replaying its ops through your reducer. Writing a key
means appending one op. Nothing ever overwrites state.

## Why that gets rid of the lock [#why-that-gets-rid-of-the-lock]

Two servers appending to the same key isn't a conflict, because neither append overwrites the other.
Both ops end up in the log, the datastore settles what order they're in, and every server that folds
that log later walks them in that same order and gets the same state.

This replaces the session lock. A lock stops the second writer. A fold takes both writes and decides
afterwards, the same way on every server.

<Callout type="info">
  The datastore settles the order once, at the moment of the append. It isn't decided per server and
  it doesn't depend on anyone's clock.
</Callout>

## Refusing is part of it [#refusing-is-part-of-it]

Your reducer returns `nil` to refuse an op. The op is still in the log, it just doesn't contribute
anything. So when two servers both try to spend the same last 100 gold:

1. Server A appends `SpendGold{100}`, server B appends `SpendGold{100}`.
2. The log holds both of them, in whatever order the datastore settled on.
3. Every fold applies the first and refuses the second, because by then the balance is 0.

Both servers see the same thing. The player spent 100 gold once.

## Compaction [#compaction]

A log that only ever grows would eventually hit the 4 MB value limit. Once a log gets long or heavy,
Ledger folds it down into a fresh snapshot and drops the ops it just absorbed. Autosave does this on
its own, and `Session:Compact()` forces it.

Your reducer never sees any of that. Compaction must not lose the op ids it has already applied, or a
retry afterwards would apply twice. Ledger keeps them inside the state itself, under `_Received`.

## Reserved fields [#reserved-fields]

Ledger keeps its own bookkeeping in the state table, under keys starting with an underscore.

`_Received` holds applied op ids, namespaced so a transfer, a transaction and a
[Once](/docs/concepts/once) name can't collide. `_Held` holds money set aside by a
[transfer](/docs/guides/transfers) that hasn't finished yet.

`Ledger.New` throws if your `Default` declares any key starting with `_`. Your reducer will see both
fields on `State`, and `table.clone` carries them across without you doing anything. Drop them by
accident and Ledger puts them back. Write your own values into them and you can break the dedupe.

## What you can store [#what-you-can-store]

Whatever a datastore can hold, so JSON. Tables, strings, numbers, booleans. No Instances, no
Vector3, no functions, no cyclic tables, no tables that mix array and dictionary keys, no NaN or
inf. Buffers are fine. Ledger checks this on the way in and refuses the op with
[`Invalid`](/docs/concepts/reasons) instead of letting the save fail later.

Use string keys for ids:

```luau
State.Owners[Op.UserId] = true              -- an array with millions of gaps
State.Owners[tostring(Op.UserId)] = true    -- a dictionary
```

A table with only number keys is an array, and an array with gaps cannot be stored. Ledger checks
each op on its own, and each op passes, so nothing goes wrong at first. The key then fails to compact
and Ledger warns you that your reducer built state a datastore cannot hold. If a number is a name,
make it a string.


# Typed ops (https://xoifaii.github.io/LedgerDocs/docs/concepts/typed-ops)



An op is `{ Id, Kind, ...whatever you passed }`. Ledger can't know which fields a kind carries, so
`Op.Amount` reads as `unknown` in strict mode and a misspelled `Kind` is a refusal you find while
playing.

Name your ops and both of those become build errors.

## Naming them [#naming-them]

A map of the kind to the fields that kind carries:

```luau
export type Profile = {
	Gold: number,
	Items: { [string]: boolean },
}

export type Ops = {
	Buy: { Item: string },
	Sell: { Item: string },
	AddGold: { Amount: number },
}
```

Then build the store with `Ledger.NewTyped` and hand it both:

```luau
local Store = Ledger.NewTyped<<Profile, Ops>>({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {} },
	Reducer = Reducer,
})
```

## What gets checked [#what-gets-checked]

```luau
Session:Apply("Buy", { Item = "Sword" }) -- fine
Session:Apply("Byu", { Item = "Sword" }) -- no kind by that name
Session:Apply("Buy", { Item = 42 })      -- Item is a string
Session:Apply("Buy", { Amount = 5 })     -- those are AddGold's fields
```

A call that matches no kind lists the ones that do. The error names every op your store writes.

`Session:Commit` and `Store:Edit` take the same check. `Edit` has the key first.

A field your kind doesn't name rides along rather than failing. That's what keeps `Once` working:

```luau
Session:Apply("Buy", { Item = "Sword", Once = "order1" })
```

So a misspelled field is caught when it means the real one is missing, which is the usual way you
make that mistake, and a spare field next to a complete set is not.

## The reducer [#the-reducer]

`Ledger.Op<Ops>` is the op as one of your kinds. Testing `Op.Kind` narrows to that kind, and its
fields come out typed:

```luau
local function Reducer(State: Profile, Op: Ledger.Op<Ops>): Profile?
	if Op.Kind == "Buy" then
		local Cost = Prices[Op.Item]
		if Cost == nil or Cost > State.Gold then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold -= Cost
		Next.Items = table.clone(State.Items)
		Next.Items[Op.Item] = true
		return Next
	elseif Op.Kind == "AddGold" then
		local Next = table.clone(State)
		Next.Gold += Op.Amount
		return Next
	end

	return nil
end
```

`Op.Item` is a string and `Op.Amount` is a number. There's no `type(Op.Amount) == "number"` and no
`Op.Item :: string` anywhere. Reading a field off the wrong kind is an error where you read it:

```luau
if Op.Kind == "Buy" then
	return Op.Amount -- Key 'Amount' not found in { Id: string, Item: string, Kind: "Buy" }
end
```

An op is there to be read, so its fields are read only and writing one stops the build:

```luau
Op.Item = "Shield" -- Property Item of table '{ read Id: string, read Item: string, read Kind: "Buy" }' is read-only
```

Nothing reads an op after your reducer has it, so a write was only ever going to be lost. The state
you are handed is frozen for the same reason, except that one shows up while you play, as a
[`Refused`](/docs/concepts/reasons) op rather than an error where you wrote it.

## An op with no fields [#an-op-with-no-fields]

A kind takes its fields whether or not it has any:

```luau
export type Ops = {
	Prestige: {},
}

Session:Apply("Prestige", {})
```

## Your state gets checked too [#your-state-gets-checked-too]

The `Field` argument to `Reserve`, `Bump` and `Total` has to name a number field on your state:

```luau
Store:Reserve(UserId, "Gold", 1, "order1") -- fine
Store:Reserve(UserId, "Glod", 1, "order1") -- no field by that name
Store:Reserve(UserId, "Name", 1, "order1") -- Name isn't a number
```

That threw at the call before. Now it doesn't build.

Your reducer is held to giving back your state or `nil` as well, so one that hands back something
else stops building instead of having its answer thrown away at runtime.

## What doesn't change [#what-doesnt-change]

Everything else on the store. `Peek`, `Transfer`, `Reserve`, `Tx` and the rest keep the signatures
they have on an untyped store, and a typed store loads, folds, saves and recovers through the same
code. Nothing about it differs at runtime.

The call shape doesn't change either. Both views take the kind and the fields as two arguments, so
moving a store to `NewTyped` doesn't touch a call site.

`Ledger.New` is unchanged. A store built with it takes any kind with any fields. That's what you
want while the ops are still moving around, and naming them is something you do when you want it.

## Types [#types]

`Ledger.TypedStore<D, O>` and `Ledger.TypedSession<S, O>` name the two views, the same way
`Ledger.Store<D>` and `Ledger.Session<S>` name the open ones.

```luau
local function Buy(Session: Ledger.TypedSession<Profile, Ops>, Item: string)
	return Session:Apply("Buy", { Item = Item })
end
```

See [Types](/docs/reference/types).


# Entity stores (https://xoifaii.github.io/LedgerDocs/docs/guides/entity-stores)



A store with `Keys = "String"` isn't about players. The keys are names you pick, and the data
underneath belongs to nobody in particular.

```luau
local MAX_MEMBERS = 50

local Clans = Ledger.New({
	Name = "Clans",
	Keys = "String",
	Default = { Members = {}, Count = 0, Treasury = 0, Level = 1 },
	Balance = "Treasury",
	Reducer = function(State, Op)
		if Op.Kind == "Join" then
			local Who = tostring(Op.UserId)
			if State.Members[Who] then
				return nil
			end
			if State.Count >= MAX_MEMBERS then
				return nil
			end

			local Next = table.clone(State)
			Next.Members = table.clone(State.Members)
			Next.Members[Who] = true
			Next.Count += 1
			return Next
		end

		return nil
	end,
})
```

Two lines in there are easy to get wrong.

**`tostring(Op.UserId)`, not `Op.UserId`.** A table with only number keys is an array. A UserId is a
huge number, so `Members` becomes an array with millions of gaps. A datastore cannot store that.
Ledger checks each op on its own, and each op passes, so the writes keep working. The key then fails
to compact and the log grows forever. String keys make `Members` a dictionary.

**`State.Count`, not `#State.Members`.** `#` gives `0` on a dictionary, so the cap never applies. The
clan above fills to sixty.

This is where not having a lock matters most. Twenty servers can be writing to the same clan at the
same time, and the fold decides the membership cap the same way on all of them. There's no owner
server, no lease, and nothing to recover if a server dies mid write.

## Working with them [#working-with-them]

There are no sessions, because nobody is logged in to a clan. You write with `Edit` and read with
`Peek`:

```luau
local Ok, Why = Clans:Edit("cool-guys", "Join", { UserId = Player.UserId }):Wait()
if not Ok and Why == Ledger.Reason.Refused then
	Tell(Player, "that clan is full")
end

local State, Why = Clans:Peek("cool-guys"):Wait()
if State == nil then
	warn(`could not read that clan: {Why}`)
	return
end
print(State.Level)
```

A clan nobody has created yet folds to your `Default`, so `nil` there always means the read itself
failed rather than the clan being missing.

Every method that takes a `Key` works. `Transfer`, `Tx`, `DidApply`, `History`, `PeekVersion`,
`Reset` and `Erase` all behave the same way they do on a player store.

The session methods don't. `Load`, `Unload`, `Get`, `Expect`, `IsLoaded`, `WaitForLoaded` and `Read`
all throw on a string keyed store, because there's no player to hang a session on.

## Keys [#keys]

A key is a string of 1 to 50 characters and it has to be valid UTF-8. Roblox sets that limit, so
Ledger can't raise it.

A key cannot hold a `#`. Ledger puts a `#` between a tally name and its shard number, so a key that
holds one could read as a shard of something else. `Ledger` throws where you wrote the call when a
key holds one.

Pick keys that come from something stable. A clan id, a listing id, a slug. Don't build them out of
anything that might change, because there's no rename.

## How much one key holds [#how-much-one-key-holds]

A clan or a listing takes writes from every player at once. Ledger writes down the name of every
`Tx` leg and every `Transfer` that goes through. It keeps each name for 30 days. That is about
1,700 a day on one key before those names fill the state cap.

`Edit` writes no name. A clan that only takes `Edit` has nothing to plan around. `Reserve` and
`Confirm` write none either.

Above that rate, give the entity more than one key. One key per guild rather than one for all of
them. See [Limits](/docs/limits#applied-names).

## Caching [#caching]

`Peek` reads the record every time you call it. There's no cache, because with twenty servers
writing to the key a cached copy would be out of date almost immediately. It does mean you shouldn't
call it in a loop or per frame.

Read it once, hold onto it, and read again after you write.

## Naming their ops [#naming-their-ops]

An entity store takes [`NewTyped`](/docs/concepts/typed-ops) the same way a player store does, and
its keys stay strings:

```luau
export type Ops = {
	Join: { UserId: string },
	Donate: { Amount: number },
}

local Clans = Ledger.NewTyped<<Clan, Ops>>({
	Name = "Clans",
	Keys = "String",
	Balance = "Treasury",
	Default = { Members = {}, Count = 0, Treasury = 0, Level = 1 },
	Reducer = Reducer,
})

Clans:Edit("cool-guys", "Join", { UserId = tostring(Player.UserId) })
```

Writing `UserId: string` in the map turns the rule at the top of this page into one the checker
holds. Passing `Player.UserId` straight in stops the build, instead of storing a number key that
only goes wrong when the key first tries to compact.

`Tx` is unchanged either way. Its legs take any kind on any store, which is what the next section
needs.

## Mixing them [#mixing-them]

A transaction can touch a player store and an entity store in the same commit, which is the usual
reason to have both:

```luau
Players:Tx(`donate:{OrderId}`, {
	{ UserId = Player.UserId, Kind = "SpendGold", Fields = { Amount = 500 } },
	{ Store = Clans, Key = "cool-guys", Kind = "Donate", Fields = { Amount = 500 } },
}):Wait()
```

Both sides move or neither does. See [Transactions](/docs/guides/transactions).


# Migrations (https://xoifaii.github.io/LedgerDocs/docs/guides/migrations)



A migration is a function that takes the old state and gives back the new one. You add them to the
end of the list and never touch the ones already there.

```luau
local Store = Ledger.New({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {}, Pets = {} },
	Reducer = Reducer,
	Migrations = {
		-- 1: Coins became Gold
		function(State)
			local Next = table.clone(State)
			Next.Gold = State.Coins or 0
			Next.Coins = nil
			return Next
		end,

		-- 2: pets, which is additive
		{
			Compatible = true,
			Apply = function(State)
				local Next = table.clone(State)
				Next.Pets = {}
				return Next
			end,
		},
	},
})
```

The number of migrations in the list is the version. A record remembers which version it was written
at, and when a server loads one that's behind, it runs the missing steps in order before folding.

Migrations only run on the snapshot, at load. They never see ops.

## New fields don't need one [#new-fields-dont-need-one]

Ledger reconciles the folded state against `Default` on every load, so a field you add to `Default`
shows up on old profiles with its default value automatically. You only need a migration when you're
changing something that's already there, like renaming a field or reshaping it.

## Rolling deploys [#rolling-deploys]

This is the part that actually needs thinking about. During a deploy you have old servers and new
servers running at the same time, on the same data.

New servers write records stamped with the new version. An old server that reads one and doesn't
recognise the version refuses to fold it, and errors instead. That's on purpose. The alternative is
an old server quietly folding a record it doesn't understand and writing back a version of the
profile with the new fields stripped out.

`Compatible = true` is how you say a step is safe for that. It means the migration only adds things,
so an old server can read the record, ignore what it doesn't know, and write back without losing
anything.

Ledger keeps track of the last step that wasn't compatible. Any record at or above that point can be
read by an older server. Anything below it can't, and the old server answers
[`Behind`](/docs/concepts/reasons) instead of guessing.

```luau
-- new build, two migrations, the first of them not compatible
Version = 2, Floor = 1

-- old build with one migration reads it
Store:Peek(UserId):Wait()   --> nil, "Behind"
Store:Reset(UserId):Wait()  --> false, "Behind"
```

The version sits on the snapshot, so a key gets one the first time it compacts. Before that the
record is only ops, and an older server reads it normally.

The floor doesn't wait for a compaction. Every write stamps it, so a key can start turning an old
server away before it has ever compacted:

```luau
Store:Edit(UserId, "Add", { Amount = 5 }):Wait()   --> false, "Behind"
```

The floor is checked first, inside the transform, so nothing reaches the log. The write doesn't
half happen and there's nothing queued behind it. The deploy clears it.

An older server can never compact one of these records, so it can never write a snapshot in the old
shape.

`Behind` is the one reason it's pointless to retry, because it isn't about the datastore. It says
this server is running an older build than the one that wrote the record, and it clears when the
deploy finishes. Never fall back to a fresh profile on `Behind`, the stored data is fine and writing
over it is how you lose it.

So:

Adding a field, adding a table, adding a default. Mark it `Compatible = true` and old servers keep
working straight through the deploy.

Renaming, deleting, or reshaping a field. Leave it plain. Old servers will refuse those records,
which is what you want, and the errors stop as soon as the deploy finishes.

## Don't drop something Default still declares [#dont-drop-something-default-still-declares]

If a migration removes a field but `Default` still lists it, the reconcile puts it straight back on
every load and your migration does nothing. Nothing warns about this. Ledger cannot tell a field you
meant to drop from one you meant to keep.

Take it out of `Default` at the same time you write the migration to remove it.

## Rules [#rules]

Migrations have to be pure and can't yield, same as the reducer.

They have to return a table. Returning anything else errors on load with the step number.

Leave anything starting with an underscore alone. Those are Ledger's own fields, the money set aside
for a transfer, the applied names, the units reserved and the tally. A migration that rebuilds the
state from scratch drops them, so Ledger puts them back after every step and names the step that did
it. Copy the state and change what you meant to change:

```luau
-- keeps everything it did not mean to touch
function(State)
	local Next = table.clone(State)
	Next.Gold = State.Coins or 0
	Next.Coins = nil
	return Next
end

-- drops Ledger's bookkeeping along with the old fields
function(State)
	return { Gold = State.Coins or 0 }
end
```

Never reorder them, never delete one, never edit one that's already shipped. The list index is the
version, so changing it changes what every existing record means.

Version numbers only go up. A record written at a version newer than this server knows is either
read through the compatible path or refused, never folded down.

## Changing the reducer [#changing-the-reducer]

Ledger puts no version on the reducer. A migration changes the snapshot, not the ops. Each server
folds a log with the reducer that it runs now, so a change to the reducer changes what the older ops
do.

Add a kind for a new rule. You can widen a kind to accept ops that it refused before. Do not narrow
one, do not change what one does, and never use a name twice.

A branch is not dead code. It builds part of the state of every record whose log still holds one of
its ops. Keep it when the feature goes, and keep it correct through later migrations:

```luau
-- pets were taken out of the game. the ops are still in the logs, so the rule stays
if Op.Kind == "BuyPet" then
	if type(Op.Cost) ~= "number" or Op.Cost > State.Gold then
		return nil
	end

	local Next = table.clone(State)
	Next.Gold -= Op.Cost
	Next.Pets = table.clone(State.Pets)
	Next.Pets[Op.PetId] = true
	return Next
end
```

Delete it and the fold leaves out that gold and that pet, the key stops compacting with a warning
naming the kind, and the log grows until writes answer [`Full`](/docs/concepts/reasons). Put the
branch back and both return.

`Reset` does not get a key out of that. It writes the default state as another op, so the op it cannot
apply is still the oldest one and the log still cannot compact. It says so when you try. Only a build
that folds the op, or erasing the key, clears it.

Do not swap it for a branch that accepts the op and changes nothing. The state goes the same way,
and this time the key compacts, so the snapshot keeps that result:

```luau
-- wrong. the fold drops what the op did, and a compaction writes that down for good
if Op.Kind == "BuyPet" then
	return table.clone(State)
end
```

Only a loaded session compacts, and only when the log is long enough, so an offline key holds its
ops until you deploy a build that folds them.

A change to the reducer does not move the floor, because Ledger cannot see it. Two builds then fold
one log by different rules during a deploy. Add a migration that gives back its state unchanged when
the change is not safe for both:

```luau
Migrations = {
	-- ...
	function(State) return State end,  -- 3: SpendGold now checks a daily cap
}
```

An old server then gets [`Behind`](/docs/concepts/reasons).


# Recovery (https://xoifaii.github.io/LedgerDocs/docs/guides/recovery)



## History [#history]

Roblox keeps 30 days of versions for every datastore key, and `History` lists them.

```luau
local Rows, Why = Store:History(UserId, 25):Wait()
if Rows == nil then
	warn(`could not list that history: {Why}`)
	return
end

for _, Entry in Rows do
	print(Entry.Version, os.date("%c", Entry.At), Entry.Deleted)
end
```

You get back newest first. `Version` is the string you hand to `PeekVersion`, `At` is a Unix
timestamp in seconds, and `Deleted` says whether that version was a delete.

The limit is clamped between 1 and 100 and defaults to 25.

## PeekVersion [#peekversion]

```luau
local Was = Store:PeekVersion(UserId, Entry.Version):Wait()
if Was then
	print(Was.Gold)
end
```

This folds that old record the same way a load would, so migrations run and you get real state, not
raw storage.

It's read only, and there is no restore. Writing an old snapshot back over a live profile would wipe
whatever happened in between, including money that arrived from a transfer. To roll something back,
look at what changed and write ops that undo it.

## Reset [#reset]

`Reset` puts a key back to `Default`.

```luau
local Ok, Why = Store:Reset(UserId):Wait()
```

It's an op like any other, so it goes in the log and every server sees it. It keeps `_Received` and
`_Held` across. Wiping the applied id set would let an old retry apply again, and wiping the holds
would destroy money that is part way through a transfer.

A server won't reset a record written at a version it doesn't know, so you can't accidentally
downgrade a profile during a deploy.

It can answer [`Unresolved`](/docs/concepts/reasons) if a stuck transaction leg on that key would
change the outcome. Ask again. The reset has not failed.

## Erase [#erase]

`Erase` throws the record away. This is your GDPR button.

```luau
local Gone, Why = Store:Erase(UserId):Wait()
if not Gone then
	warn(`that key is still there: {Why}`)
end
```

Check the answer. If you are erasing to satisfy a deletion request, `false` means it did not happen
and you have not finished the job.

First it passes on whatever this key still owes somebody else, so a normal erase doesn't take
something with it that was on its way out. That means money set aside for a transfer that has not
finished, and units a `Reserve` set aside with a `To`. If a receiver won't take one of them, Ledger
names what was left and how much, and you settle that one yourself.

Money arriving is a different problem, because another server can be delivering to this key while you
erase it. So an erase leaves a tombstone in place of the record instead of removing the key. Anything
sent to a tombstoned key is refused and the sender keeps the money set aside.

**The tombstone lasts 8 days.** A write to the key does not clear it. That is the point: the erase
has to outlast anything still in flight to the key, and a session on another server has no idea the
erase happened. By the end of the window no transfer can still be unfinished.

A key can still be written to and read while it holds a tombstone. It folds from `Default` like a
fresh profile. Only money sent to it is turned away.

The tombstone holds a timestamp, your `Default`, and the applied names the key had built up. It holds
no other player data. To remove the key outright, call `Erase` again after the 8 days.

Keeping the names matters more than it sounds. `ProcessReceipt` retries until you answer
`PurchaseGranted`, and Roblox can retry one you already granted. If an erase dropped the names, that
retry would read as never granted and pay out a second time. So a read of an erased key comes back as
a fresh profile, and a receipt already paid out is still refused.

The refund to a turned away sender is not immediate. Their money stays set aside until the transfer
is overdue, which is the same 8 days, and then the recovery sweep gives it back. Forcing
`RecoverTransfers` on the sender before that does nothing, on purpose: a refund paid early could
still be delivered afterwards and pay twice.

Erasing a player who's still in the server warns. Unload them first:

```luau
Store:Unload(Player)
Store:Erase(Player.UserId):Wait()
```

A session on **another** server knows nothing about the erase, and it cannot bring the key back. A
session is fenced to the tombstone as it stood when it took the key. Its writes are turned away and it
closes itself. `Flush`, `Release` and `Commit` answer [`Refused`](/docs/concepts/reasons) rather than
report a save that never happened.

Whatever that session had queued dies with it, so get the player off every server before you erase
them. Ledger warns on the erased key when a write arrives, which tells you somebody is still holding
it.

The erase is still a version, so `History` shows it and the data is recoverable through `PeekVersion`
for 30 days. Roblox keeps that history whatever Ledger does, so know about it before you erase
someone for a legal reason.

## Sweeping [#sweeping]

Ledger runs a background sweeper that finishes stranded transfers, settles stuck transaction legs,
and tidies up old transaction markers. It picks up keys it saw a problem on, so most of the time it
sorts itself out and you never notice.

`Ledger.Sweep()` forces a pass right now. It's useful in a test, or in a live incident when you want
something dealt with immediately instead of on the next tick.

## Support tooling [#support-tooling]

The store methods that take a key all work on players who aren't here, so a support tool doesn't
need the player online:

```luau
local State, Why = Store:Peek(UserId):Wait()
if State == nil then
	warn(`could not read that profile: {Why}`)
	return
end

Store:Edit(UserId, "GrantItem", {
	Item = "Sword",
	Once = `support:{TicketId}`,
}):Wait()

local Applied = Store:DidApply(UserId, `support:{TicketId}`):Wait() == true
```

Put a `Once` name on anything a support tool writes. Someone will click the button twice.

It stops the double click, and it stops a retry minutes or days later. It does not stop the same
ticket being fulfilled again months later, because the name is only remembered for a rolling 30 days.
If a reopened ticket has to stay fulfilled for good, record that in the state your reducer can see
and refuse on it there. See [how long a name is remembered](/docs/concepts/once#how-long-a-name-is-remembered).

## Editing storage directly [#editing-storage-directly]

A datastore editor plugin shows you Ledger's record, not the player's data:

```luau
{
	Snapshot = { Gold = 100 },   -- the state as of the last compaction
	Ops = { ... },               -- changes since then, not folded in yet
	Seen = { ... },              -- op ids already applied
	Version = 3, Floor = 1, Envelope = 1
}
```

The number someone came looking for is inside `Snapshot`, and on its own it is not the current value,
because everything in `Ops` still replays over it.

<Callout type="warn">
  Replacing the value with a plain state table wipes the player. With no `Snapshot` field, Ledger
  folds from your `Default` and reads them as a brand new profile. What you typed sits on the record
  as a field nothing looks at, until the next compaction drops it.
</Callout>

The rest, in the order they cost you:

* **Editing `Snapshot` while `Ops` has anything in it.** Your edit goes in, then the ops replay over
  the top. Set gold to 1000 with a pending spend of 50 and the fold answers 950.
* **Deleting `Seen`.** That is the dedupe window for ops already compacted away, so an old retry can
  apply a second time.
* **Removing an op that has a `Tx` field.** That is a parked [transaction](/docs/guides/transactions)
  leg. The marker still counts it, so the transaction can half apply or sit stuck until it is reaped.
* **Clearing `_Held` or `_Received` inside `Snapshot`.** `_Held` is money set aside for a transfer
  that has not finished, so deleting it destroys that money. `_Received` is the delivery evidence, so
  deleting it lets the same transfer pay twice.
* **Raising `Envelope`** is the one safe mistake. Every server answers
  [`Behind`](/docs/concepts/reasons) and refuses to touch the record rather than misreading it.

Use the api instead. It goes through your reducer and the log rather than around them, and it works
whether or not the player is online or on this server:

```luau
Store:Inspect(UserId):Wait()   -- see what is actually on the key first
Store:Edit(UserId, "GrantItem", { Item = "Sword", Once = `support:{TicketId}` }):Wait()
Store:Reset(UserId):Wait()     -- back to Default, keeping _Received and _Held
```

`Reset` keeps the two reserved fields, which hand editing would not. `Once` makes the double click
safe.

One last thing if you do edit storage. A live session does not see it until its next autosave refold,
so up to 30 seconds, and the ops it has already queued were worked out against the state before your
edit.


# Reservations and totals (https://xoifaii.github.io/LedgerDocs/docs/guides/reservations)



Two problems look like they need a transaction and don't.

The first is a limit: 500 copies of a sword, 40 raid places, one seat per table. The second is a
total: an event pot, a kill counter, a donation tally.

Both are cheaper and simpler on a single key than across two, and each has its own tool.

## Reserve, Confirm, Release [#reserve-confirm-release]

A reservation holds units of a number field on one key. The hold lives in MemoryStore, not on the
key: the field still reads what it was, and `Holds` says how much of it is spoken for. A second
buyer is turned away at `Reserve`, before checkout rather than at it.

```luau
local Shop = Ledger.New({
	Name = "Shop",
	Keys = "String",
	Default = { Stock = 0 },
	Reducer = Reducer
})

Shop:Edit("sword", "Restock", { Amount = 500 }):Wait()

local Ok = Shop:Reserve("sword", "Stock", 1, OrderId):Wait()
if not Ok then
	Tell(Player, "sold out")
	return
end
```

`Stock` still reads 500, `Holds("sword", "Stock")` reads 1, and the next `Reserve` sees 499 to give.
Two things can happen to the hold:

```luau
Shop:Confirm("sword", OrderId, "Sell", { Count = 1 }):Wait()   -- your op spends the unit, stock is 499
Shop:Release("sword", OrderId):Wait()                           -- the hold goes, stock was never touched
```

`Confirm` takes the kind and fields of your own op, the ones you would give `Edit`. Your reducer
decides what a checkout takes off the key and refuses one the field cannot cover:

```luau
-- in your reducer
if Op.Kind == "Sell" then
	if State.Stock < Op.Count then
		return nil
	end
	return { Stock = State.Stock - Op.Count }
end
```

That reducer is the gate. A hold is advice about who gets to checkout first, and it is not in the
fold, so an `Edit` can spend units somebody holds and their `Confirm` is then `Refused`. A hold that
was lost, or never made because the MemoryStore was down, costs the same: one refused checkout and
never an oversell. Show players `Holds` rather than the field when "3 left" has to mean it.

Asking to reserve under a name that already holds something answers `true` and holds nothing extra,
so a retry is safe. Confirming twice spends once, since the op's id comes from the name. Once a hold
has gone, the same name can be used again.

### One key is one item [#one-key-is-one-item]

`"sword"` and `"shield"` are separate keys with separate records, so they hold separate stock.
`Default` is not a template for an item. It is the starting state of a key nothing has written yet,
and the stock of each item arrives as an op like anything else:

```luau
-- in your reducer
if Op.Kind == "Restock" then
	return { Stock = Op.Amount }
end
```

```luau
Shop:Edit("sword", "Restock", { Amount = 500 }):Wait()
Shop:Edit("shield", "Restock", { Amount = 1000 }):Wait()
```

Start the default at zero. A key nobody has written still folds to it, so a default of 500 means a
misspelled item id has 500 in stock and `Reserve` says yes to all of it. Give the restock a
[`Once`](/docs/concepts/once) name if it should land one time however many servers run it.

The second argument to `Reserve` is a field, so one key can hold several pools. Keep that for units
that share a limit. One key is one write queue, and putting every item on one key makes every
purchase wait behind every other.

### Nobody has to clean up [#nobody-has-to-clean-up]

A hold lasts 15 minutes and then runs out on its own. Nothing has to give it back, because nothing
was taken. `Hold` on the options sets a shorter one. Fifteen minutes is the cap as well as the
default, so `Hold` can only shorten a hold. A `Hold` above the cap throws where you wrote the call.

A checkout that stays open longer calls `Reserve` again under the same Id. That moves the end of the
hold out and holds nothing extra. Call `Release` when the player walks away, so the next buyer does
not wait the 15 minutes.

One key holds 256 at once. Past that `Reserve` answers [`Refused`](/docs/concepts/reasons), which in
practice means they are being made faster than they are being confirmed or released.

The stock a hold is judged against is what the key read last. A refusal reads the key again before
it answers, so a restock is seen. `Reserve` needs MemoryStore, which in Studio means API access on.
Without it `Reserve` answers [`Unresolved`](/docs/concepts/reasons) and checkout falls to first come,
which the reducer enforces.

## Handing the units to another key [#handing-the-units-to-another-key]

`Confirm` spends the units where they are. `Transfer` with a field moves them somewhere else:

```luau
Shop:Transfer("sword", tostring(Player.UserId), 1, OrderId .. ":unit", "Stock"):Wait()
```

That is the same three op transfer a balance takes, on the field you name, so it is escrowed on the
way, deduped by its id, and finished or given back by the recovery sweep if the server dies between
the legs. See [Transfers](/docs/guides/transfers).

A transfer id belongs to one transfer, and the field is part of what it means, so the price and the
unit of a purchase carry two ids. The same id on a different field answers
[`Spent`](/docs/concepts/reasons).

## The buying sequence [#the-buying-sequence]

The order matters, because a server can die between any two calls. This order recovers from all of
them:

```luau
Shop:Reserve("sword", "Stock", 1, OrderId):Wait()
Bank:Transfer(tostring(Player.UserId), "shop", 250, OrderId .. ":price"):Wait()
Shop:Transfer("sword", tostring(Player.UserId), 1, OrderId .. ":unit", "Stock"):Wait()
```

`Bank` is a store with `Keys = "String"`, and the player's key on it is `tostring(Player.UserId)`.
A transfer moves a field between two keys of one store, so both keys have to suit that store's key
mode. A player keyed store cannot hold a key called `"shop"`, and a string keyed store cannot take a
`UserId` as a number. Ledger throws at the call when a key does not suit the store.

Both transfers are idempotent under their ids, so running the whole thing again after a crash lands
each exactly once. A transfer under a name that already moved answers finished. The hold runs out on
its own once the unit has left the shop, or sooner if you `Release` it.

Die before the payment and nothing was taken. Die between the two transfers and running the sequence
again pays nothing twice and hands the unit over once.

A purchase that stays on one key is simpler: `Confirm` with your own op, and put a
[`Once`](/docs/concepts/once) name on any op that grants something elsewhere so `DidApply` can answer
whether it went through. Don't use the reservation name for that. Once the key compacts, a repeat `Confirm`
answers [`Unresolved`](/docs/concepts/reasons), and a confirmed, a released and an expired hold all
leave the same absence.

## Bump and Total [#bump-and-total]

A total is the other shape. Nothing is limited, a lot of servers add to it, and you want the sum.

One key can only be written by one server at a time, so a key that every server writes spends its
time retrying. `Bump` spreads the total over 16 keys and gives each server its own, so they stop
queueing behind each other.

```luau
local Events = Ledger.New({
	Name = "Events",
	Keys = "String",
	Default = { Gold = 0 },
	Reducer = Reducer
})

Events:Bump("summerpot", "Gold", 25):Wait()

local Pot = Events:Total("summerpot", "Gold"):Wait()
```

`Total` reads all 16 shards, so it costs 16 requests. Read it on a timer and cache it.

`Total` answers what has been added, not what the 16 keys hold. `Bump` keeps its own running count on
each shard and never touches the field your reducer owns, so the `Default` never counts toward the
total. A tally nobody has added to reads 0.

### A total can only go up [#a-total-can-only-go-up]

`Bump` refuses anything that is not positive. No shard can see the others, so no shard knows the sum,
and nothing can hold a limit across them.

That is the whole difference between the two tools. A reservation can hold a limit because everything
is on one key. A total gives that up to get the writes.

If you need both, split the stock into fixed pools and reserve against a pool. Each pool holds its
own share, so the limit survives. One pool empties before another, so fall through to the next.

## Which one, and when it really is a transaction [#which-one-and-when-it-really-is-a-transaction]

|                                                              |                                       |
| ------------------------------------------------------------ | ------------------------------------- |
| The limit is a property of one key                           | `Reserve` and `Confirm`               |
| Units held on one key end up on another                      | `Reserve` and `Transfer` with a field |
| Add only, no limit, many servers                             | `Bump`                                |
| A balance moves between two keys                             | [`Transfer`](/docs/guides/transfers)  |
| Two keys must change together and one change can't be undone | [`Tx`](/docs/guides/transactions)     |

The question that sorts them is what an undo would look like. If you can describe it, you want a
reservation or a transfer. If the undo is asking the other player to give the sword back, you want a
transaction.

Trading a sword for a shield is a real transaction. Selling a sword from a shop is not.

## What this costs [#what-this-costs]

Measured on the fake datastore, 100 limited stock purchases:

|                                      | Requests |
| ------------------------------------ | -------- |
| A transaction across buyer and shelf | 800      |
| Reserve and confirm                  | 201      |

`Reserve` and `Release` cost no datastore request at all, two MemoryStore request units each, and the
first hold on a key reads it once. `Confirm` costs one request and two units. Moving the units to
another key is a transfer, three requests.

A hold never queues on the key, so 500 buyers reserving at once are answered by MemoryStore and only
the ones who got a hold go on to write. That is what the transaction version could not do.


# Sessions (https://xoifaii.github.io/LedgerDocs/docs/guides/sessions)



A session is one player's data live on this server. You get one from `Load` and it stays around
until `Unload` or the store is destroyed.

## The lifecycle [#the-lifecycle]

```luau
Players.PlayerAdded:Connect(function(Player)
	Store:Load(Player)
end)

Players.PlayerRemoving:Connect(function(Player)
	Store:Unload(Player)
end)

game:BindToClose(function()
	Ledger.CloseAll()
end)
```

`Load` yields while it reads the record and folds it. If that fails, the player gets kicked with a
message asking them to rejoin, which is better than letting them play on a blank profile and
overwrite the real one. If you want to answer differently depending on why it failed, pass
[`OnLoadFailed`](/docs/reference/ledger#onloadfailed) when you build the store.

Calling `Load` twice for the same player warns and does nothing the second time. If the player
leaves while the load is still going, Ledger notices and releases the session instead of leaving it
hanging around.

`Unload` cancels the autosave timer, pushes everything queued, and yields until it's durable.

A session you kept a reference to still answers after that. It refuses every write with
[`Closed`](/docs/concepts/reasons):

```luau
Store:Unload(Player)
Session:Apply("Add", { Amount = 1 })   --> false, "Closed"
```

`Ledger.CloseAll()` releases every session, so the same applies after a shutdown.

## Getting the session [#getting-the-session]

There are four ways, and which one you want depends on whether you can cope with it not being there.

`Store:Get(Player)` gives you the session or `nil`. Use it when not loaded is a normal thing that can
happen.

`Store:Expect(Player)` gives you the session or throws. Use it in code that only runs after you know
the player is loaded, so you get an error instead of a silent `nil` if you're wrong.

`Store:IsLoaded(Player)` is just the boolean.

`Store:WaitForLoaded(Player)` yields until the session is there and gives it back, or gives `nil` if
the player left before it finished. This is the one for callbacks that fire during a join, like
`ProcessReceipt`.

There's also `Store:Read(Player)`, which gives you the state table directly or `nil`, for when you
only want to look at something.

```luau
Store:IsLoaded(Player)        --> false
Store:Get(Player)             --> nil
Store:Expect(Player)          --> throws, data for Name is not loaded

Store:Load(Player)

Store:IsLoaded(Player)        --> true
Store:Read(Player)            --> { Gold = 0 }
```

These seven take the `Player`: `Load`, `Unload`, `Get`, `Expect`, `IsLoaded`, `WaitForLoaded` and
`Read`. Every other method takes a key, so pass `Player.UserId`. `Store:Peek(Player)` throws and says
what it wanted.

## Autosave [#autosave]

Every session autosaves on a 30 second timer. It pushes queued ops, and if the log has gotten long
or heavy it compacts as well.

If the server is out of datastore budget, the autosave is skipped and Ledger warns. That's the point
where ops start piling up, and if it keeps going you'll start seeing
[`Backlog`](/docs/concepts/reasons) on writes.

A session with nothing queued and no transaction parked on its key reads every two minutes instead.
It has nothing to write, so it only checks what other servers wrote. That read is how a player who
was sent gold or traded with finds out.

[`Store:Stale()`](/docs/reference/store#stale) names each key this server changes, so you can flush
that session at once rather than wait for the read. See
[Transactions](/docs/guides/transactions#a-live-session-does-not-know-a-leg-wrote-to-it).

## Log size [#log-size]

`Session.LogSize` is how many ops are in the stored log, and `Session.LogBytes` is roughly how many
bytes those ops plus the queued ones take. Both are read only and mostly useful for a debug readout.

A queued op counts in `LogBytes` but not in `LogSize`, because it is not in the stored log yet:

```luau
Session.LogSize, Session.LogBytes   --> 0, 0
Session:Apply("Add", { Amount = 5 })
Session.LogSize, Session.LogBytes   --> 0, 54
```

You don't need to watch them. Autosave compacts on its own. `Session:Compact()` is there if you want
to force it, like right before you do something that's about to write a lot.

## Shutting down [#shutting-down]

`Ledger.CloseAll()` is the whole shutdown path. It stops the background sweeper, tells every store's
queue to skip ahead to the last write, saves every live session, and yields until all of it is done.

Put it in `BindToClose` and don't put anything else there. Roblox gives you a limited window on
shutdown, and `CloseAll` is already built to spend it in the right order.

`Store:Destroy()` does the same for one store and takes it out of the registry, so you can build
another one with that name. You mostly want this in tests.

## Watching state [#watching-state]

```luau
local Connection = Session:Observe():Subscribe(function(State)
	UpdateHud(Player, State)
end)
```

It fires on every change that goes through, which includes ones that came from another server and
turned up when a transfer or transaction settled. It does not fire for a refused op, because nothing
changed.

A listener here runs on the thread doing the write and must not yield. `Store:Stale()` is the one
stream that lets a listener yield.

Nothing disconnects your listeners for you. A released session stops pushing, so they never fire
again, and if you didn't store the connection anywhere it gets collected with the session. If you
did store it, disconnect it yourself. See [Observer](/docs/reference/observer).


# Testing (https://xoifaii.github.io/LedgerDocs/docs/guides/testing)



## The mock [#the-mock]

`Mock = true` puts a store on an in memory datastore. No API access, no published place, no network.

```luau
local Store = Ledger.New({
	Name = "Test",
	Default = { Gold = 0 },
	Reducer = Reducer,
	Mock = true,
})
```

### Sizing it [#sizing-it]

Pass a table instead of `true` to say what size of server to pretend to be.

`Players` is how many players to size the request budget for, since Roblox's budget formula is a base
plus a per player allowance. Set it to what a real server of yours looks like.

There are two budgets. One is for this server and one is for the whole experience. `Players` sizes the
first, `CCU` sizes the second, and `CCU` defaults to `Players`. The smaller one stops you first:

```luau
Mock = { Players = 30 }                --> 900 writes, 1260 reads, 65 lists
Mock = { Players = 30, CCU = 10000 }   --> 1260 writes, 1260 reads, 65 lists
```

Leave `CCU` alone to test against the tighter of the two. Raise it to see what a server does once the
experience budget is no longer the limit.

`Throttled` defaults to true and is what makes the mock worth using. With it on you get real request
budgets, real refill rates, real queueing, and a real throughput cap per key. Turn it off with
`Throttled = false` when you're testing logic and don't want to wait around.

The fake datastore is sized once. The first store built with `Mock` sets it, and a later one asking for
a different size throws where it was written. A plain `Mock = true` joins whatever is already there.

<Callout type="warn">
  The mock is stricter than Studio on purpose. Studio hands you request budgets a live server never
  gets, so code that's fine in Studio can fall over the moment it's on a real server with 40 people
  in it. If it passes against the mock it'll pass live.
</Callout>

What the mock keeps from the real thing: the 50 character name and key limits, the 4 MB value limit,
30 versions of history, JSON only values, and paged listing.

## Studio checks [#studio-checks]

Some checks only run in Studio, because they cost too much to run live.

Ledger refolds the log after every commit and compares it against live state. If they don't match,
your reducer isn't deterministic, and the warning names the field that moved.

That is a bug to fix. The check only runs in Studio, so on a live server you get no warning and the
same broken behaviour.

## Writing tests [#writing-tests]

The pattern that works is: build the store on the mock, drive it, assert on `Peek`.

```luau
local Store = Ledger.New({
	Name = "Test",
	Default = { Gold = 100 },
	Reducer = Reducer,
	Balance = "Gold",
	Mock = { Players = 8, Throttled = false },
})

Store:Edit(1, "SpendGold", { Amount = 30 }):Wait()
assert(Store:Peek(1):Wait().Gold == 70)

Store:Destroy()
```

`Store:Destroy()` frees the name, so the next test can build a store called `Test` again. Without it
you'll get a name clash.


# Transactions (https://xoifaii.github.io/LedgerDocs/docs/guides/transactions)



`Tx` writes to several keys at once and guarantees all of them took it or none of them did. The keys
can be in two different stores, and none of them have to be online.

```luau
local Ok, Why = Store:Tx(`trade:{TradeId}`, {
	{ UserId = Seller, Kind = "GiveItem",  Fields = { Item = "Sword" } },
	{ UserId = Buyer,  Kind = "SpendGold", Fields = { Amount = 500 } },
}):Wait()
```

If the buyer can't afford it, the seller doesn't lose the sword. If the seller doesn't have the
sword, the buyer doesn't lose the gold. There's no window where one of those is true and the other
isn't.

<Callout type="warn">
  A transaction is the most expensive thing Ledger does, and a lot of the work it gets handed belongs
  somewhere cheaper. Selling limited stock, holding a place, counting a pot: those are all one key.
  Read [Reservations and totals](/docs/guides/reservations) first.

  What sorts them is whether two keys really have to change together, and whether either change could
  be undone afterwards. Trading a sword for a shield needs this. Selling a sword from a shop does not.
</Callout>

## The id [#the-id]

The id comes first and it's required. It has to be a stable name derived from the thing you're
settling, so a trade id, an order id, a match id. Never build it from the clock, and never mint one
inside the `Tx` call.

A stable id is what makes a retry safe. Running the same id again doesn't do it twice. It finds every leg
already settled and answers `true` having moved nothing, so an `Unresolved` you want to chase is just
the same call again:

```luau
local Ok, Why = Store:Tx(`trade:{TradeId}`, Legs):Wait()
if Why == Ledger.Reason.Unresolved then
	Ok, Why = Store:Tx(`trade:{TradeId}`, Legs):Wait()
end
```

The legs have to match on every attempt. Ledger records what a name meant next to the name, so the
same id run again for a different set of keys or a different amount answers
[`Spent`](/docs/concepts/reasons) rather than `true`. That holds however long ago the first one ran.
Pass the same legs on the retry and you get the `true` you are chasing.

Ids are 1 to 50 characters.

### Where the id comes from [#where-the-id-comes-from]

Two of the three you get handed, one you have to invent.

**A purchase** gives you `ReceiptInfo.PurchaseId`. Roblox keeps calling `ProcessReceipt` with the same
one until you return `PurchaseGranted`, so it survives a server restart as well as a retry.

**A trade** gives you nothing, so mint the id when the trade opens rather than when it commits:

```luau
local function OpenTrade(A: Player, B: Player)
	return {
		Id = HttpService:GenerateGUID(false),   -- once, here
		A = A,
		B = B
	}
end

-- later, when both sides confirm
Store:Tx(`trade:{Trade.Id}`, Legs):Wait()
```

A GUID is fine there because it's minted once and held. What breaks is generating one inside the `Tx`
call, since every retry would be a new transaction and apply the money again.

**Anything from outside**, a webhook or your own website, should use the sender's order id. They're
the ones who retry, so their id is the one that stays the same when they do.

The rule underneath all three: the id has to live at least as long as whatever might retry it. For a
purchase Roblox holds it. For a trade only the hosting server would retry, so that server's memory is
enough. If you can't name what would retry, you don't need a durable id at all.

## The legs [#the-legs]

Between two and four legs. Each one names a key and an op.
[Limits](/docs/limits#transactions) explains where those two numbers come from. Read it before you
reach for a fourth leg.

```luau
{
	Store = Clans,          -- optional, defaults to the store you called Tx on
	UserId = 12345,         -- for a player store
	Key = "cool-guys",      -- for a string keyed store
	Kind = "Donate",
	Fields = { Amount = 500 },
}
```

Use `UserId` when the target store uses player keys and `Key` when it uses string keys. Ledger
checks which one the target store wants and throws if you gave it the wrong one.

A transaction can only touch a key once, so two legs pointing at the same key is an error rather
than something it tries to merge.

Don't put `Once` on a leg. The transaction id already makes every leg land at most one time, and
Ledger throws if it sees one.

### A leg will not land on an erased key [#a-leg-will-not-land-on-an-erased-key]

A key that was [erased](/docs/guides/recovery) turns a leg away for the 8 days its tombstone lasts,
and the whole transaction answers [`Refused`](/docs/concepts/reasons) with a warning naming the key.
Nothing is applied to any of the other keys.

```luau
Store:Erase("shop"):Wait()

Store:Tx("order1", {
	{ Key = "player", Kind = "Pay", Fields = { Amount = 25 } },
	{ Key = "shop", Kind = "Take", Fields = { Amount = 25 } },
}):Wait()   --> false, Refused
```

Once the tombstone runs out the key takes legs again.

### A leg reads what is stored, not what a session is holding [#a-leg-reads-what-is-stored-not-what-a-session-is-holding]

Every leg folds the record on the datastore. A live session that has taken ops through
[`Apply`](/docs/concepts/apply-and-commit) has not written them yet, so a leg on that player's key
does not see them.

That bites hardest on a player who just joined. Grant them something with `Apply`, list it for sale a
few seconds later, and the leg reads a key that has never been written, which folds to your `Default`.
The reducer sees an empty inventory and a new player, refuses, and the whole transaction answers
[`Refused`](/docs/concepts/reasons).

```luau
-- the session says the item is there, the stored record does not
Session:Apply("GrantItem", { Item = ItemId })

Store:Tx(`listing:{ListingId}`, {
	{ Key = "market", Kind = "AddListing", Fields = { Item = ItemId } },
	{ Store = Players, UserId = Seller, Kind = "ListItem", Fields = { Item = ItemId } },
}):Wait()   --> false, Refused
```

Two ways round it. Flush first if the session is on this server:

```luau
Session:Flush():Wait()
```

Or write it durably in the first place, which is what `Commit` is for:

```luau
Session:Commit("GrantItem", { Item = ItemId }):Wait()
```

Prefer `Commit` for anything a transaction will later depend on. A flush only works while the session
is on the server running the transaction, and the seller may be on another one or offline.

Waiting does not fix it. An autosave writes what was queued when it ran, so the newest applies are
still unwritten whenever the transaction lands.

### A live session does not know a leg wrote to it [#a-live-session-does-not-know-a-leg-wrote-to-it]

The record carries the change the moment `Tx` answers `true`. A session already open on that key does
not. It holds its own copy and only picks an outside write up when it folds the record again.

A session with nothing queued and nothing parked reads every two minutes, so a player who just bought
something waits that long to see it arrive. Nothing is wrong and nothing is at risk. They are reading
a copy that has not caught up.

[`Store:Stale()`](/docs/reference/store#stale) carries the keys this server has changed. Subscribe
once, and flush the session on every key it names:

```luau
Profiles:Stale():Subscribe(function(Key)
	local Person = Players:GetPlayerByUserId(tonumber(Key) or 0)
	if Person == nil then
		return
	end

	local Session = Profiles:Get(Person)
	if Session then
		Session:Flush():Wait()
	end
end)
```

That re-reads the key, folds it again, and pushes anything the session still had queued. It also
fires [`Observe`](/docs/reference/session), so a UI bound to the session updates on its own.

The stream names every key the transaction touched, so the buyer and the seller both refresh. It
costs one request per key with a session here, and only on a purchase.

A cross store transaction pushes each leg onto its own store's stream, so subscribe on both stores.

This listener yields, which the stale stream allows. The ones on `Session:Observe()` may not. See
[Observer](/docs/reference/observer#listeners-that-may-yield).

A player on another server is not on this stream. Their server holds them, so their server does the
flush, and the next section is how you ask it to.

### Telling another server to refresh [#telling-another-server-to-refresh]

Ledger can't reach another server. Your game can, so send the key over `MessagingService` and let the
server holding that player do the flush.

Drive it from the same stream. Flush a key with a session here, and publish one without:

```luau
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")

local REFRESH = "LedgerRefresh"

local function Refresh(Key: string): boolean
	local Person = Players:GetPlayerByUserId(tonumber(Key) or 0)
	if Person == nil then
		return false
	end

	local Session = Profiles:Get(Person)
	if Session then
		Session:Flush():Wait()
	end
	return true
end

MessagingService:SubscribeAsync(REFRESH, function(Message)
	Refresh(Message.Data)
end)

Profiles:Stale():Subscribe(function(Key)
	if Refresh(Key) then
		return
	end

	pcall(function()
		MessagingService:PublishAsync(REFRESH, Key)
	end)
end)
```

The buyer sees the purchase in a moment either way. Without this they wait for the ordinary two
minute read.

**Send the key and nothing else.** The other server re-reads the key itself, so the record stays the
only thing either server believes. A message carrying the new inventory would be a second copy of the
truth, and a dropped or repeated one would put the two servers out of step.

**Treat it as a nudge, not a guarantee.** `MessagingService` is best effort and rate limited, and
`PublishAsync` throws once you hit a limit, which is why the call above is wrapped. A message that
never arrives costs that player the ordinary two minute read. Nothing is lost either way, so there is
no need to confirm delivery or retry.

Publishing only when the player isn't here keeps most purchases off the topic entirely.

### What throws and what answers [#what-throws-and-what-answers]

The shape of a leg is your code, so getting it wrong throws where you wrote it. A key the target
store won't take, a missing or oversized id, the wrong number of legs, the same key twice, a `Once`
on a leg, a `Store` that Ledger didn't build.

What's *in* `Fields` is data, so it answers instead:

```luau
local Ok, Why = Store:Tx(`trade:{TradeId}`, {
	{ UserId = A, Kind = "Give", Fields = { Amount = Price * Quantity } },
	{ UserId = B, Kind = "Take", Fields = { Amount = Price * Quantity } }
}):Wait()

if Why == Ledger.Reason.Invalid then
	-- a field can't be stored, so an Instance, a NaN from that multiply, a reserved name
end
```

That's the same split `Edit` uses, and the same [`Invalid`](/docs/concepts/reasons). Nothing is
prepared on any key when it happens, so there's nothing to clean up.

## How it decides [#how-it-decides]

Each leg gets prepared on its key first. A prepared op is written into the log but carries a stamp
that makes the fold skip it, so it's sitting there doing nothing.

Once every leg is prepared, Ledger writes the outcome to a marker key. That single write is the
moment the transaction commits, and there's exactly one of them, so two servers racing the same
transaction can't disagree about what happened.

Committing takes the stamps off, which is what makes the ops start counting. Aborting removes them.

If any leg's reducer refuses during prepare, the whole thing aborts and every other leg gets its op
pulled back out.

## Stuck legs [#stuck-legs]

If the server dies between preparing a leg and writing the outcome, that leg sits there stamped.
Anything that reads the key sees a pending leg, so it can't just pretend it isn't there.

A few things clear it. Any read or write on that key tries to settle it first. The background
sweeper picks up keys it knows have pending legs. And a transaction that's older than a minute is
considered dead, so another server will abort it on its behalf.

While it's stuck, writes to that key answer [`Busy`](/docs/concepts/reasons), and `Edit` or `Reset`
can answer `Unresolved` when the stuck leg would change the verdict. Neither means it failed. Both
mean ask again in a moment.

Ask again yourself. `Tx` does not retry a `Busy` internally, because a key under contention is the
last place to send more traffic:

```luau
local Ok, Why
for _ = 1, 6 do
	Ok, Why = Store:Tx(`trade:{TradeId}`, Legs):Wait()
	if Ok or Why ~= Ledger.Reason.Busy then
		break
	end
	task.wait(0.2 + math.random() * 0.3)
end
```

A key every player writes to is a throughput limit rather than a correctness one. See
[One key at a time](/docs/limits#one-key-at-a-time).

You can force a pass with `Ledger.Sweep()`.

## Marker cleanup [#marker-cleanup]

Committed markers get tidied up in the background once they're old enough that nothing could still
be asking about them. That happens on the store named `<YourStore>_Tx`, which Ledger creates
alongside yours.

That's also why store names cap at 47 characters instead of the datastore's 50. Ledger needs the
three for `_Tx`.

## Mixing stores [#mixing-stores]

```luau
local Ok, Why = Players:Tx(`donate:{OrderId}`, {
	{ UserId = Player.UserId, Kind = "SpendGold", Fields = { Amount = 500 } },
	{ Store = Clans, Key = "cool-guys", Kind = "Donate", Fields = { Amount = 500 } },
}):Wait()
```

Both stores have to have been built by `Ledger.New` in this server. A leg naming something else
throws.

## When not to reach for it [#when-not-to-reach-for-it]

If you're moving one balance one direction, use a [transfer](/docs/guides/transfers). It's one
protocol instead of two phases, it self heals, and it doesn't leave a key `Busy` while it runs.

`Tx` is for when two different kinds of change have to happen together.


# Transfers (https://xoifaii.github.io/LedgerDocs/docs/guides/transfers)



A transfer moves a number out of one key and into another. It works whether either side is online,
on another server, or offline, and it can't lose money or make any.

```luau
local Store = Ledger.New({
	Name = "PlayerData",
	Default = { Gold = 100 },
	Balance = "Gold",
	Reducer = Reducer,
})

local Ok, Why = Store:Transfer(FromUserId, ToUserId, 250):Wait()
```

`Balance` names the field it moves. It has to be a number field that's already in `Default`, and
without it `Transfer` throws.

## What actually happens [#what-actually-happens]

It's three steps, not one write.

**Reserve.** Ledger appends an op to the sender that takes the money out of the balance and puts it
in `_Held` under a transfer id. If the sender doesn't have enough, your reducer never even sees it,
the reserve is refused and you get `Refused`.

**Deliver.** It appends an op to the receiver that adds the money and records the transfer id in
their `_Received`.

**Settle.** It goes back to the sender and drops the hold, because the money has arrived.

Money is only ever in one of three places: the sender's balance, the sender's `_Held`, or the
receiver's balance. There's no moment where it's in two, and no moment where it's in none. That's
what makes it safe to crash halfway.

## Crashing halfway [#crashing-halfway]

If the server dies between reserve and deliver, the money is sitting in the sender's `_Held`. It's
out of their balance so they can't spend it twice, and it hasn't arrived yet.

Ledger picks that up on its own. A background sweeper notices held money and finishes the job, and
the sender's next load kicks off a recovery too. You don't have to write a cron job for this and you
shouldn't call `RecoverTransfers` by hand in normal operation.

If the receiver turns out to be gone or the delivery keeps failing, the hold eventually expires and
the money goes back to the sender.

## Ids and retries [#ids-and-retries]

By default each transfer gets a fresh id, which means calling it twice moves the money twice. That's
usually what you want for a trade.

When it's a retry of the same logical transfer, name it:

```luau
local Ok, Why = Store:Transfer(From, To, 250, `trade:{TradeId}`):Wait()
```

Now a second call with that id doesn't move anything again. You get `true` back, because the transfer
already went through. That's the answer to retry on, and it stays `true` however many times you ask.

The amount and the receiver have to match on every attempt. A name that already went through, asked
again for a different amount or a different key, answers [`Spent`](/docs/concepts/reasons). Ledger
records what a name meant next to the name, so it can tell an honest retry from the same name being
reused for something else.

Ids are 1 to 64 characters. The id has to be the same string on every attempt, so make it once and
keep it somewhere the retry can read it:

```luau
-- wrong, a new id each attempt, so a retry sends the money a second time
Store:Transfer(From, To, 250, HttpService:GenerateGUID(false)):Wait()

-- right, the id was made when the trade opened and lives on the trade
Store:Transfer(From, To, 250, `trade:{Trade.Id}`):Wait()
```

The second line uses a GUID too. It works because the GUID was made once and the retry reads the same
one. Making a GUID at the call site is what breaks. Every attempt is then a different transfer, so
Ledger has nothing to match it against and the money moves again.

`TradeId` is whatever already names that trade. If nothing names it yet, make the id when the trade
opens and store it on the trade, next to the two players and the offer. An order id, a match id and a
receipt id all work the same way.

Never build an id from the clock. Never build one from the amount and the two keys either. The same
two players can trade the same amount twice, and you would swallow the second trade as a duplicate.

[Where the id comes from](/docs/guides/transactions#where-the-id-comes-from) covers the three cases
and how long each id has to survive.

## Reading the answer [#reading-the-answer]

`true` means the money moved and both sides are settled.

`Refused` means the sender didn't have it. An amount that isn't positive and finite throws at the call
site instead, because that's a bug in the caller rather than an answer about the money.

`Spent` means the hold sat there long enough to expire and the money went **back to the sender**.
Nothing moved and that id is finished, so don't hand anything over on it. A transfer that actually
went through answers `true`, not this.

`Busy` means a transaction is holding the sender's key. Ledger has already scheduled a cleanup pass,
try again shortly.

`Unresolved` means the reserve went through but the delivery didn't finish. The money is set aside
and Ledger will either finish it or refund it on its own. Don't retry with a new id, that would move
it twice, and don't tell the player it failed.

## Housekeeping [#housekeeping]

Delivered transfer ids sit in the receiver's `_Received` so a redelivery can't pay twice. They're
dropped after 30 days, which is well past the point any retry could still turn up.

`Store:ClearDelivered(Key)` forces that pass early. You basically never need it.

`Store:RecoverTransfers(Key)` forces a recovery on one key. The sweeper already does this, so it's
here for a support tool, or for a live incident where you want one key dealt with right now.

Both are about money moving between keys, so both want a store that names a `Balance` field. On a
store without one they throw where you called them.

<Callout type="warn">
  `Store:Erase(Key)` passes on any money the key was sending out, including money recovery had
  stopped retrying because the key could still have been given it back. After that it turns away
  anything sent to the key and answers [`Held`](/docs/concepts/reasons), so the sender gets it back
  instead of losing it. That lasts a full 8 days, and a write to the key does not cut it short. If a
  receiver won't take one, it names what was left and you settle that one yourself. See
  [Erase](/docs/guides/recovery#erase).
</Callout>

## When to use a transaction instead [#when-to-use-a-transaction-instead]

A transfer moves one balance one way. If you need two different things to move together, like gold
one way and an item the other, that's a [transaction](/docs/guides/transactions).


# Using Ledger from TypeScript (https://xoifaii.github.io/LedgerDocs/docs/guides/typescript)



Ledger is on npm as `@xoifail/ledger`. It's the same Luau you get from Wally with a declaration file
sitting next to it, so nothing is compiled, nothing is wrapped, and it behaves exactly the way the
rest of these pages describe. Every type is there under `Ledger.`, with the names the
[reference](/docs/reference/types) uses.

```
npm install @xoifail/ledger
```

## Getting it into the place [#getting-it-into-the-place]

roblox-ts only syncs `node_modules/@rbxts` on its own. This package lives under `@xoifail`, so if
you don't tell Rojo about that folder the require fails at runtime with a module it can't find. Add
one line to `default.project.json`, next to the `@rbxts` one:

```json
"node_modules": {
	"$className": "Folder",
	"@rbxts": { "$path": "node_modules/@rbxts" },
	"@xoifail": { "$path": "node_modules/@xoifail" }
}
```

Then import it in a server script. It still asserts it's on the server, same as in Luau.

```ts
import Ledger from "@xoifail/ledger";
```

## Calling it [#calling-it]

There's nothing to learn here. The declaration knows which methods take a self, so you write dot
calls everywhere and the compiler puts the colon in where Ledger wants one. Futures still have
`Wait`, and the `(boolean, Reason?)` every write answers with comes out as a pair you destructure:

```ts
const [ok, why] = session.Apply("SpendGold", { Amount: 25 });
const [state, readWhy] = store.Peek(userId).Wait();
```

`Ledger.Reason` is both the type and the constants, so `why === Ledger.Reason.Busy` works the same
way it does in Luau, and a `switch` over it can end in `never`.

The one thing to decide is where the state type comes from. `Ledger.New` reads it off the reducer or
off `Default`, whichever you've annotated. When both are inline, say it yourself:

```ts
const Store = Ledger.New<Profile>({ Name: "PlayerData", Default: { Gold: 100 }, Reducer });
```

## Typed ops [#typed-ops]

This is where the declaration earns its place. Name the ops as an interface and hand `NewTyped`
both types:

```ts
interface Profile {
	Gold: number;
	Items: { [item: string]: boolean };
}

interface Ops {
	Buy: { Item: string };
	AddGold: { Amount: number };
	Prestige: {};
}

const Store = Ledger.NewTyped<Profile, Ops>({
	Name: "PlayerData",
	Default: { Gold: 100, Items: {} },
	Reducer: (state, op) => {
		if (op.Kind === "Buy") {
			if (state.Items[op.Item]) return undefined;
			return { ...state, Items: { ...state.Items, [op.Item]: true } };
		}
		if (op.Kind === "AddGold") return { ...state, Gold: state.Gold + op.Amount };
		return undefined;
	},
});
```

`op.Kind === "Buy"` narrows `op` to that arm, so `op.Item` is a string in there and `op.Amount` is
an error. Every write is held against the map, and the refusals are the ones the
[typed ops](/docs/concepts/typed-ops) page lists:

```ts
session.Apply("Buy", { Item: "Sword" });                 // fine
session.Apply("Buy", { Item: "Sword", Once: "order1" }); // fine, Once rides along
session.Apply("Byu", { Item: "Sword" });                 // no kind by that name
session.Apply("Buy", { Item: 42 });                      // Item is a string
session.Apply("Buy", { Amount: 5 });                     // those are AddGold's fields
store.Reserve(userId, "Items", 1, "order1");             // Items isn't a number field
```

There's one check the Luau side doesn't have. A kind that doesn't name its fields as an object,
`Buy: string`, stops the build at `NewTyped` rather than being ignored.

On a store built with `New`, the op's fields all read as `unknown`, so narrow them with `typeIs`
the way the Luau examples use `type()`.

## The fields you can't pass [#the-fields-you-cant-pass]

`Id`, `Kind` and `OnceAt` belong to Ledger. In Luau, passing one in `Fields` warns and gets
overwritten. In TypeScript it doesn't build. `Once` is the one that's yours, and it's allowed on
every write, typed or not.

## Migrations [#migrations]

A migration step gets `unknown`, because the stored shape is whatever an older build wrote and the
declaration can't know it. Annotate the parameter with the shape you know it had and the body is
checked against that:

```ts
interface Legacy {
	Coins?: number;
}

Migrations: [
	(state: Legacy) => ({ Gold: state.Coins ?? 0, Items: {} }),
	{ Compatible: true, Apply: (state: Legacy) => ({ ...state, Pets: {} }) },
],
```

## Waiting with a timeout [#waiting-with-a-timeout]

`Wait()` gives you the values. `Wait(seconds)` can give you nothing at all, so in that overload
every value in the pair is optional and the checker makes you deal with it. The
[Future](/docs/reference/future) page says why you don't want a timeout on a write anyway.

## Two names [#two-names]

`Ledger.Record<D>` is what `Inspect` hands back, the same as in Luau. It shadows TypeScript's own
`Record` inside the `Ledger` namespace, which nothing in there needs.

`Ledger.OpMap` is what every op map is held against. You never write it yourself. If you're seeing it
in an error, one of your kinds isn't naming its fields as an object.

## What isn't checked [#what-isnt-checked]

Which methods a store takes still depends on `Keys`, and that's not in the type. `Load`, `Get` and
the other player methods throw at the call on a string keyed store, and `Bump` and `Total` throw on a
player one, exactly as they do in Luau.


# Future (https://xoifaii.github.io/LedgerDocs/docs/reference/future)



Anything in Ledger that touches the datastore gives you a `Future` rather than yielding on the spot.

```luau
local Job = Store:Peek(UserId)   -- already running
local State = Job:Wait()         -- yields here
```

The important part is that the work starts when you call the method, not when you call `Wait`. The
callback is spawned straight away on its own thread. `Wait` only parks your thread until it's done.

## Running two at once [#running-two-at-once]

Because they're eager, starting several and waiting afterwards runs them together:

```luau
local A = Store:Peek(FirstUserId)
local B = Store:Peek(SecondUserId)

print(A:Wait().Gold + B:Wait().Gold)
```

Both reads are already running while you sit on the first `Wait`. Writing it as
`Store:Peek(First):Wait() + Store:Peek(Second):Wait()` costs you two round trips instead of one.

## Wait [#wait]

```luau
Job:Wait(Timeout: number?) -> T...
```

Yields until the callback finishes and gives you whatever it returned. If it's already finished,
`Wait` returns immediately without yielding at all, so don't lean on it as a way to give up a frame.

Waiting more than once is fine, and so is waiting from several threads.

<Callout type="warn">
  `Wait` returns **nothing** if the callback errored or the timeout ran out. Not `false`, not `nil`
  as a deliberate answer, just no values at all, which lands in your locals as `nil`.
</Callout>

Every Ledger method answers with a [reason](/docs/concepts/reasons) rather than throwing, so in
normal use you don't hit this. A failed `Peek` gives you `(nil, Unresolved)`, not nothing at all:

```luau
local State, Why = Store:Peek(UserId):Wait()
if State == nil then
	warn(`could not read that profile: {Why}`)
	return
end
```

A timeout still bites, and so does any Future you build yourself. In both cases the missing first
return is `nil`, which is falsy, so `if Ok then` and `if State == nil then` both do the right thing.
You lose `Why` though. It comes back `nil` as well, so a timeout reads exactly like a failure.
`Happened` answers `false` for both, so it cannot tell them apart either.

## Timeout [#timeout]

```luau
local Ok, Why = Store:Edit(UserId, "GrantItem", { Item = "Sword" }):Wait(10)
```

After 10 seconds your thread resumes with no values. The work carries on in the background, it isn't
cancelled, and if it finishes later the result is still there for a second `Wait`.

<Callout type="warn">
  Don't put a timeout on a write. `(nil, nil)` looks the same as a refusal, so a caller reads a
  timeout as "it didn't happen" and asks again under a new name, which moves the money twice. The
  timeout doesn't cancel the write either. Call `Wait()` with no timeout to get the real answer, and
  let the [reason](/docs/concepts/reasons) tell you what happened.
</Callout>

## Happened [#happened]

```luau
Job:Happened(Wait: boolean?) -> boolean
```

Whether the callback ran to completion without erroring.

Called while the job is still going it gives you `false` straight away rather than waiting. So the
plain form is for after you already waited:

```luau
local Job = Store:Peek(UserId)
local State = Job:Wait()

if not Job:Happened() then
	warn("that read failed")
end
```

Pass `true` and it waits for the answer first. That's the one to use when you only care whether it
worked and never wanted the value:

```luau
local Job = Store:ClearDelivered(UserId)

-- ... do other things while it runs ...

if not Job:Happened(true) then
	warn("that housekeeping pass failed, the next one picks it up")
end
```

`Happened(true)` yields exactly like `Wait` does, so don't reach for it somewhere that can't yield.

This is the only way to tell an empty result apart from a failure.

<Callout type="warn">
  `Happened` answers whether the callback ran, not whether what you asked for worked. A refused
  `Edit` gives you a future that ran perfectly well and answered `(false, Refused)`, so
  `Happened()` is `true`. Read the boolean for the outcome, `Happened` for whether there is an
  outcome at all.
</Callout>

It has one rough edge. A job that's still running and a job that failed both report
`false`, so straight after a `Wait` that timed out you get `false` from a job that's doing fine and
will finish a moment later. If you used a timeout, use `Happened(true)`. It waits for the job before
it answers, so the answer means something.

## Errors don't propagate [#errors-dont-propagate]

A callback that throws is caught. Ledger warns with `Future callback errored:` and the message, the
future settles as not happened, and `Wait` gives you nothing. It will not rethrow into your thread,
so a `pcall` around `:Wait()` catches nothing useful.

If you want a failed read to throw in your own code, check `Happened` and raise it yourself.

## Fire and forget [#fire-and-forget]

You don't have to wait at all. The work still runs.

```luau
Store:ClearDelivered(UserId)  -- no :Wait(), still happens
```

Reasonable for maintenance calls. Not reasonable for anything you're about to act on, since you have
no idea whether it worked.


# Ledger (https://xoifaii.github.io/LedgerDocs/docs/reference/ledger)



```luau
local Ledger = require(ServerStorage.Ledger)
```

## Ledger.New [#ledgernew]

```luau
Ledger.New<D>(Options: Config<D>) -> Store<D>
```

Builds a store. Throws on anything wrong with the options, at build time, rather than letting it
misbehave later.

| Option         | Type                                                                 |                                                                                                    |
| -------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `Name`         | `string`                                                             | Required. The datastore name, 1 to 47 characters.                                                  |
| `Reducer`      | `(State, Op) -> State?`                                              | Required. See [Writing a reducer](/docs/concepts/reducer).                                         |
| `Default`      | `D`                                                                  | Required. The fresh state table.                                                                   |
| `Balance`      | `string?`                                                            | Names a number field for [transfers](/docs/guides/transfers).                                      |
| `Migrations`   | `{ Migration }?`                                                     | See [Migrations](/docs/guides/migrations).                                                         |
| `Keys`         | `"Player" \| "String"`                                               | Defaults to `"Player"`.                                                                            |
| `OnLoadFailed` | `((Player, Reason) -> boolean)?`                                     | What to do when a load fails. See below.                                                           |
| `Mock`         | `boolean \| { Players: number?, CCU: number?, Throttled: boolean? }` | Puts this store on an in memory datastore, sized how you ask. See [Testing](/docs/guides/testing). |

The name caps at 47 rather than the datastore's 50 because Ledger also creates `<Name>_Tx` for
transaction markers.

`Default` can't declare any key starting with `_`, and it has to be storable: numbers, strings,
booleans, tables and buffers.

Two stores can't share a name in one server. Call `Store:Destroy()` first if you need to rebuild
one.

### OnLoadFailed [#onloadfailed]

A load that fails kicks the player with "Your data failed to load, please rejoin". `OnLoadFailed`
takes that decision instead. It gets the player and the [reason](/docs/concepts/reasons), and returns
whether it dealt with them. `true` and Ledger leaves them alone, `false` and it kicks.

```luau
local Store = Ledger.New({
	Name = "PlayerData",
	Reducer = Reducer,
	Default = { Gold = 0 },
	OnLoadFailed = function(Player: Player, Why: Ledger.Reason): boolean
		if Why == Ledger.Reason.Behind then
			-- this server is running an old build, send them to one that isn't
			TeleportService:Teleport(game.PlaceId, Player)
			return true
		end
		return false
	end
})
```

`Behind` means a newer build wrote the record, so a rejoin puts them on the same old server and fails
again. `Unresolved` is usually a datastore outage, where a rejoin is the right answer.

It can yield, so a teleport works. Anything waiting in `WaitForLoaded` is released before it runs.

If it throws, Ledger warns and kicks. If it returns `true` and the player is still in the server with
no data, Ledger warns about that too.

Only for `Keys = "Player"` stores. Passing it on a `Keys = "String"` store throws at build time.

## Ledger.NewTyped [#ledgernewtyped]

```luau
Ledger.NewTyped<D, O>(Options: TypedConfig<D, O>) -> TypedStore<D, O>
```

Builds a store that knows what its ops carry. `D` is your state and `O` is a map of the kind to the
fields that kind carries. Give it both:

```luau
export type Ops = {
	Buy: { Item: string },
	AddGold: { Amount: number },
}

local Store = Ledger.NewTyped<<Profile, Ops>>({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {} },
	Reducer = Reducer,
})
```

`Apply`, `Commit` and `Edit` then check the kind against the ones you named and the fields against
what that kind carries. Your reducer gets `Ledger.Op<Ops>`, which narrows on `Op.Kind`.

It takes every option `Ledger.New` takes and validates them the same way. The store it builds is the
same object and behaves identically at runtime. See [Typed ops](/docs/concepts/typed-ops).

## Ledger.Reason [#ledgerreason]

The ten reasons, as constants. See [Reasons](/docs/concepts/reasons).

```luau
Ledger.Reason.Refused
Ledger.Reason.Busy
Ledger.Reason.Spent
Ledger.Reason.Held
Ledger.Reason.Unresolved
Ledger.Reason.Closed
Ledger.Reason.Backlog
Ledger.Reason.Full
Ledger.Reason.Invalid
Ledger.Reason.Behind
```

## Ledger.Sweep [#ledgersweep]

```luau
Ledger.Sweep() -> ()
```

Forces a background maintenance pass right now: finish stranded transfers, settle stuck transaction
legs, tidy up old markers. The sweeper does this on its own, so this is for tests and incidents.

## Ledger.CloseAll [#ledgercloseall]

```luau
Ledger.CloseAll() -> ()
```

Shuts everything down. Stops the sweeper, tells every queue to skip ahead to the last write, saves
every live session, and yields until it's all done.

Put this in `BindToClose` and nothing else.

```luau
game:BindToClose(function()
	Ledger.CloseAll()
end)
```

## Exported types [#exported-types]

```luau
Ledger.Store<D>
Ledger.TypedStore<D, O>
Ledger.Session<S>
Ledger.TypedSession<S, O>
Ledger.Op
Ledger.Op<O>
Ledger.OpOf<O, K>
Ledger.OpMap
Ledger.Reducer<S, O>
Ledger.Reason
Ledger.KeyLike
Ledger.KeysMode
Ledger.TxLeg
Ledger.HoldOptions
Ledger.Migration
Ledger.Config<D>
Ledger.TypedConfig<D, O>
Ledger.Record<D>
Ledger.HistoryEntry
Ledger.Future<T...>
Ledger.Observer<T>
```

See [Types](/docs/reference/types).


# Observer (https://xoifaii.github.io/LedgerDocs/docs/reference/observer)



```luau
Session:Observe():Subscribe(function(State)
	UpdateHud(Player, State)
end)
```

An observer is a stream of values you can subscribe to. Ledger pushes the new state onto one every
time a change goes through, and it hands you that same stream from `Session:Observe()`.

`Store:Stale()` is the other stream Ledger gives you. It carries the keys this server has changed
rather than a state table. Everything on this page works on both.

## Subscribe [#subscribe]

```luau
Observer:Subscribe(Listener: (T) -> ()) -> Connection
```

The connection has a `Connected` boolean and a `Disconnect` method:

```luau
local Connection = Session:Observe():Subscribe(function(State)
	print(State.Gold)
end)

Connection:Disconnect()
```

It fires on every accepted change, including ones that came from another server and turned up when a
transfer or transaction settled. It does not fire for a refused op, since nothing changed.

It does not fire on subscribe either. If you need the current value first, call `Session:Get()`
yourself.

## Listeners run inline [#listeners-run-inline]

Your listener is called on the thread doing the write, not on a fresh one. Two consequences.

It must not yield. No `task.wait`, no `:Wait()`. Ledger runs it inside a guard that errors if it
does. If you need to yield, hand the work to `task.spawn` and get out.

A listener that throws is caught and warned, and the rest of the listeners still run. One broken HUD
update won't stop the others.

Listeners are called over a snapshot of the list, so subscribing or disconnecting from inside a
listener is safe and takes effect on the next push rather than partway through this one.

### Listeners that may yield [#listeners-that-may-yield]

`Store:Stale()` is the one stream that does not work this way. Ledger calls each of its listeners on
a fresh thread, so they can yield. A `Flush` or a `PublishAsync` inside one is fine.

Ledger warns when a listener runs for 10 seconds without returning. Every pushed key holds a thread
until its listener returns, so one that never returns costs a thread per write.

## Map [#map]

```luau
Observer:Map(Transform: (T) -> U) -> Observer<U>
```

```luau
Session:Observe():Map(function(State)
	return State.Gold
end):Subscribe(function(Gold)
	GoldLabel.Text = tostring(Gold)
end)
```

## Filter [#filter]

```luau
Observer:Filter(Predicate: (T) -> boolean) -> Observer<T>
```

```luau
Session:Observe():Filter(function(State)
	return State.Gold == 0
end):Subscribe(ShowBrokeMessage)
```

## Changed [#changed]

```luau
Observer:Changed(Equals: ((T, T) -> boolean)?) -> Observer<T>
```

Drops a value when it's the same as the one before it. Without an `Equals` it compares with `==`.

<Callout type="warn">
  Calling `Changed()` straight on `Session:Observe()` filters nothing. Every fold builds a new state
  table, so `==` is comparing identity and no two pushes are ever equal.
</Callout>

Compare the thing you actually care about, either with a comparer:

```luau
Session:Observe():Changed(function(Was, Now)
	return Was.Gold == Now.Gold
end):Subscribe(UpdateGoldLabel)
```

or by mapping down to it first, which is usually what you meant:

```luau
Session:Observe()
	:Map(function(State) return State.Gold end)
	:Changed()
	:Subscribe(UpdateGoldLabel)
```

## Use [#use]

```luau
Observer:Use(Middleware: (Value: T, Emit: (U) -> ()) -> ()) -> Observer<U>
```

The general form the other three are built on. Emit as many times as you like, or not at all:

```luau
Session:Observe():Use(function(State, Emit)
	for _, Item in State.Items do
		Emit(Item)
	end
end):Subscribe(print)
```

## Chains are lazy [#chains-are-lazy]

`Map`, `Filter`, `Changed` and `Use` don't do anything until something subscribes to the end of the
chain. The first subscriber wires it up to the source, and the last one to disconnect tears it back
down.

So building a chain and never subscribing costs nothing, and a chain whose subscribers have all gone
stops pulling from the session on its own.

## Cleaning up [#cleaning-up]

Nothing disconnects your listeners for you. The session does not clear its observers when the player
leaves, it only stops pushing to them, so they stay connected and never fire again.

In practice that's fine. Ledger drops the session when the player leaves, and if you didn't keep the
connection anywhere it gets collected along with it.

If you did store connections somewhere long lived, disconnect them yourself:

```luau
local Connections: { [Player]: any } = {}

Players.PlayerAdded:Connect(function(Player)
	Store:Load(Player)
	Connections[Player] = Store:Expect(Player):Observe():Subscribe(function(State)
		UpdateHud(Player, State)
	end)
end)

Players.PlayerRemoving:Connect(function(Player)
	local Connection = Connections[Player]
	if Connection then
		Connection:Disconnect()
		Connections[Player] = nil
	end
	Store:Unload(Player)
end)
```

## Destroy [#destroy]

```luau
Observer:Destroy() -> ()
```

Drops every listener and runs the teardown.

<Callout type="warn">
  Don't call this on `Session:Observe()`. It hands back the session's own stream rather than a copy,
  so destroying it kills change notifications for everything else watching that player. Destroy your
  own chains if you want, never the source.
</Callout>


# Session (https://xoifaii.github.io/LedgerDocs/docs/reference/session)



You get one from `Store:Get`, `Store:Expect` or `Store:WaitForLoaded`. Sessions only exist on player
keyed stores.

## Fields [#fields]

### LogSize [#logsize]

```luau
Session.LogSize: number
```

How many ops are in the stored log. Read only.

### LogBytes [#logbytes]

```luau
Session.LogBytes: number
```

Roughly how many bytes the stored ops plus the queued ones take. Read only.

## Reading [#reading]

### Get [#get]

```luau
Session:Get() -> S
```

Live state. Every table in it is frozen, at every depth, so a mutation throws on the line that did it:

```luau
local State = Session:Get()
State.Gold = 99                --> attempt to modify a readonly table
State.Bag.Items[1] = "sword"   --> attempt to modify a readonly table
```

### Observe [#observe]

```luau
Session:Observe() -> Observer<S>
```

Fires on every change that goes through, including ones from another server that turned up when a
transfer or transaction settled. Doesn't fire for a refused op.

```luau
Session:Observe():Subscribe(function(State)
	UpdateHud(Player, State)
end)
```

This is the session's own stream, not a copy, so `Session:Observe() == Session:Observe()`. `Destroy`
on it removes Ledger's own subscribers too, so don't call it. See
[Observer](/docs/reference/observer) for the chain methods and cleanup.

### DidApply [#didapply]

```luau
Session:DidApply(Id: string) -> boolean
```

Whether a [`Once`](/docs/concepts/once) name ever applied on this key. Reads live state, so it
doesn't yield.

<Callout type="warn">
  Live state includes the ops that wait for the next save. `Apply` puts a name in that queue, so
  `DidApply` gives `true` before the op is written. It tells you that the name applied. It does not
  tell you that the name is saved. To be sure that it is saved, use `Commit`, or use `Apply` and
  then `Flush`.
</Callout>

## Writing [#writing]

### Apply [#apply]

```luau
Session:Apply(Kind: string, Fields: { [any]: any }?) -> (boolean, Reason?)
```

Instant and local. Runs the reducer, updates state, tells observers, queues the op for the next save.
Never touches the datastore.

Use it for gameplay. See [Apply and Commit](/docs/concepts/apply-and-commit).

On a session from a [typed store](/docs/concepts/typed-ops) the `Kind` and the `Fields` are checked
against the ops you named. `Commit` and `CommitOp` take the same check.

### Commit [#commit]

```luau
Session:Commit(Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>
```

Pushes everything queued, appends the op, waits for the datastore, refolds, then answers. `true`
means it's durable and every server will agree.

Use it for anything you can't take back.

### CommitOp [#commitop]

```luau
Session:CommitOp(Op: Op) -> Future<boolean, Reason?>
```

Same as `Commit` but you build the op. Needs a string `Id` and a string `Kind`. A `Once` field, if
you give one, has to be a non empty string.

```luau
Session:CommitOp({
	Id = HttpService:GenerateGUID(false),
	Kind = "ProductGrant",
	ProductId = 123456,
	Once = `receipt:{Receipt.PurchaseId}`,
}):Wait()
```

`Id`, `Kind` and `OnceAt` belong to Ledger. Passing them in `Fields` through `Apply` or `Commit`
warns and gets overwritten.

## Saving [#saving]

### Flush [#flush]

```luau
Session:Flush() -> Future<boolean, Reason?>
```

Pushes queued ops without adding one. What autosave calls. `false` comes with a
[reason](/docs/concepts/reasons) and the ops stay queued for next time.

### Compact [#compact]

```luau
Session:Compact() -> Future<boolean, Reason?>
```

Folds the log down into a fresh snapshot and drops the ops it absorbed. Autosave does this when the
log gets long, so you rarely need it.

### Release [#release]

```luau
Session:Release() -> Future<boolean, Reason?>
```

Marks the session closed and pushes what's left. `Apply`, `Commit` and `CommitOp` then answer
[`Closed`](/docs/concepts/reasons). `Flush` still works, it adds no op.

Use `Store:Unload` instead. `Release` closes the session and tells the store nothing, so `IsLoaded`
stays `true`, `Get` still hands back the closed session, and the autosave timer keeps running.
`Unload` does both halves.


# Store (https://xoifaii.github.io/LedgerDocs/docs/reference/store)



A store owns one datastore name, every key under it, and every session live on this server.

Methods marked player only throw on a store with `Keys = "String"`.

## Sessions [#sessions]

### Load [#load]

```luau
Store:Load(Player: Player) -> ()
```

Player only. Yields while it reads and folds the record, then starts a 30 second autosave. Kicks the
player if the load fails.

Calling it twice for the same player warns and does nothing. If they leave mid load, the session is
released instead of being left around.

### Unload [#unload]

```luau
Store:Unload(Player: Player) -> ()
```

Player only. Cancels the autosave, pushes queued ops, yields until they're durable.

### Get [#get]

```luau
Store:Get(Player: Player) -> Session<D>?
```

Player only. The session, or `nil` if they aren't loaded.

### Expect [#expect]

```luau
Store:Expect(Player: Player) -> Session<D>
```

Player only. The session, or throws. For code that already knows they're loaded.

### IsLoaded [#isloaded]

```luau
Store:IsLoaded(Player: Player) -> boolean
```

Player only.

### WaitForLoaded [#waitforloaded]

```luau
Store:WaitForLoaded(Player: Player) -> Session<D>?
```

Player only. Yields until the session exists. Gives `nil` if the player left first. This is the one
for `ProcessReceipt`.

### Read [#read]

```luau
Store:Read(Player: Player) -> D?
```

Player only. The state table, or `nil`. Shorthand for `Get` then `Get()`.

## Reading any key [#reading-any-key]

### Peek [#peek]

```luau
Store:Peek(Key: KeyLike) -> Future<D?, Reason?>
```

Reads the record and folds it. Works on anyone, online here, elsewhere, or offline. No cache, so it
costs a request every time.

A key nobody has written folds to your `Default`, so `nil` always means the read failed and the
reason says why. `Behind` means a newer server wrote it, anything else is worth another go.

### DidApply [#didapply]

```luau
Store:DidApply(Key: KeyLike, Id: string) -> Future<boolean?, Reason?>
```

Whether a [`Once`](/docs/concepts/once) name ever applied on that key.

`nil` means it could not read the record, which is not the same as `false`. Compare against `true`
rather than trusting truthiness, or a failed read reads as "never granted" and you grant twice.

### History [#history]

```luau
Store:History(Key: KeyLike, Limit: number?) -> Future<{ HistoryEntry }?, Reason?>
```

Up to 30 days of versions, newest first. `Limit` is clamped to 1 through 100 and defaults to 25.
`nil` means the listing failed.

### PeekVersion [#peekversion]

```luau
Store:PeekVersion(Key: KeyLike, Version: string) -> Future<D?, Reason?>
```

Folds an old version. Read only, there's no restore. See [Recovery](/docs/guides/recovery).

## Writing any key [#writing-any-key]

### Edit [#edit]

```luau
Store:Edit(Key: KeyLike, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>
```

Appends one op to any key and waits for the answer. Works whether or not the target is online.

If the key has a live session on this server, `Edit` still goes through the log, so the session picks
it up on its next fold.

Can answer `Unresolved` when a stuck transaction leg would change the verdict. An edit that leg can't
affect answers straight away.

On a store built with [`NewTyped`](/docs/concepts/typed-ops) the `Kind` is held against the kinds you
named and the `Fields` against what that kind carries.

### Transfer [#transfer]

```luau
Store:Transfer(From: KeyLike, To: KeyLike, Amount: number, Id: string?, Field: string?) -> Future<boolean, Reason?>
```

Moves `Amount` of a number field from one key to another. `Field` names it, and has to be a number
field your `Default` declares. Leave it out to move the `Balance` field, which needs the store to
name one.

`From` and `To` have to be different. `Amount` has to be positive and finite. `Id` is 1 to 64
characters when given, and giving one makes a retry safe. A name belongs to one transfer: the same
`Id` with a different field, amount or pair of keys answers [`Spent`](/docs/concepts/reasons).

A delivery into a key that was erased answers [`Held`](/docs/concepts/reasons). The money left the
sender and waits with them until recovery gives it back.

See [Transfers](/docs/guides/transfers).

### Reserve [#reserve]

```luau
Store:Reserve(Key: KeyLike, Field: string, Amount: number, Id: string, Options: {
	Hold: number?
}?) -> Future<boolean, Reason?>
```

Holds `Amount` of a number field on one key, under the name `Id`, in MemoryStore. The key itself
does not change: `Peek` shows the full field, and `Holds` shows what is held. `Field` has to name a
number field your `Default` declares. `Id` is 1 to 64 characters.

On a [typed store](/docs/concepts/typed-ops) that rule is checked, so a `Field` that isn't a number
field of your state stops the build rather than throwing at the call. `Bump`, `Total`, `Holds` and
`Transfer` take the same check.

Asking again under a name already held answers `true` and holds nothing extra. Once a hold has gone,
confirmed, released or run out, the same name can be used again.

Asking for more than the field has, counting what is already held, answers `Refused`. So does asking
while a key already holds 256 at once, which means they are being made faster than they are being
confirmed or released. The stock a hold is judged against is what the key read last, and a refusal
reads the key again before it answers, so a restock is seen.

`Hold` is how long to keep it, in seconds. The cap and the default are both 15 minutes, so `Hold`
can only shorten a hold. A `Hold` above the cap throws where you wrote the call. Reserve again under
the same Id to move the end of a hold out. A hold nobody takes runs out on its own. Nothing gives it
back, since nothing was taken.

A hold is not in the fold. An `Edit` can spend units another player holds, and that player's
`Confirm` is then `Refused`. Nothing is oversold, one checkout fails.

MemoryStore has to be reachable, which in Studio means API access on. A store with no MemoryStore, or
one whose MemoryStore is down, answers [`Unresolved`](/docs/concepts/reasons) and holds nothing. The
reducer still refuses at checkout, so a lost hold costs a refused checkout and never an oversell.

The first hold on a key costs one datastore read and four MemoryStore request units. Every hold after
that costs two units, and a `Release` costs two.

See [Reservations](/docs/guides/reservations).

### Holds [#holds]

```luau
Store:Holds(Key: KeyLike, Field: string) -> Future<number?, Reason?>
```

Answers how many units of `Field` are held on `Key` right now. A key nothing holds answers `0`.
Costs one MemoryStore request unit.

`nil` and [`Unresolved`](/docs/concepts/reasons) mean the MemoryStore could not be read, never that
nothing is held.

### Confirm [#confirm]

```luau
Store:Confirm(Key: KeyLike, Id: string, Kind: string, Fields: table?) -> Future<boolean, Reason?>
```

Spends what `Id` holds, with your own op. `Kind` and `Fields` are what you would give `Edit`, so your
reducer decides what a checkout takes off the key and refuses one the field cannot cover. The op's id
derives from `Id`, so a retry lands once. The hold is let go once the op has gone through.

A confirm needs no hold behind it. The reducer is the gate whether a hold stood or not, so a checkout
whose hold ran out, or was never made because the MemoryStore was down, still sells what is there.

On a [typed store](/docs/concepts/typed-ops) `Kind` and `Fields` are checked the way `Edit` checks
them.

`Fields` cannot carry a `Once`. The booking name already makes the op land once, and a `Once` would
leave a name on the key for every sale.

Once the op has been folded into the snapshot, asking again answers
[`Unresolved`](/docs/concepts/reasons). The record cannot say any more whether that op took or was
turned away. The units were still spent exactly once.

Costs one datastore request and two MemoryStore request units.

### Release [#release]

```luau
Store:Release(Key: KeyLike, Id: string) -> Future<boolean, Reason?>
```

Lets go of what `Id` holds. Nothing on the key changes, since nothing was taken.

Answers `Refused` when nothing is held under that name, and [`Unresolved`](/docs/concepts/reasons)
when the MemoryStore could not be read to find out. Costs two MemoryStore request units.

### Bump [#bump]

```luau
Store:Bump(Name: string, Field: string, Amount: number) -> Future<boolean, Reason?>
```

String keyed stores only. Adds `Amount` to a total spread over 16 keys, named `<Name>#0` to
`<Name>#15`. Each server writes its own shard, so servers do not queue behind each other on one key.

`Amount` has to be positive. A total is spread over keys that cannot see each other, so nothing can be
taken back out of one. Anything with a limit belongs on a single key, where `Reserve` can hold it.

### Total [#total]

```luau
Store:Total(Name: string, Field: string, MaxAge: number?) -> Future<number?, Reason?>
```

Answers the sum cached in MemoryStore while that sum is under a minute old, for one request unit.
Once it is older, one server reads all 16 shards and caches the sum again while every other server
keeps answering the old one, so a total from another server is at most about a minute and a quarter
behind. Your own server's bumps show in its totals at once. `MaxAge` answers this server's own last
sum without any call while it is younger than that many seconds, so a pot drawn every five seconds
costs nothing between its own ticks.

It answers what has been added, not what the keys hold. Every shard starts at whatever your `Default`
says the field is, and there are 16 of them, so that baseline is taken back off. A tally nobody has
added to reads 0 whatever the `Default` is.

MemoryStore has to be reachable, which in Studio means API access on. A store whose hook has no
MemoryStore, or whose MemoryStore is down, reads the 16 shards every time and answers the same sum,
and says so once.

### Tx [#tx]

```luau
Store:Tx(Id: string, Legs: { TxLeg }) -> Future<boolean, Reason?>
```

Commits 2 to 4 legs all or nothing. `Id` comes first and is required, 1 to 50 characters, and has to
be stable across retries. Running the same id again answers `true` and moves nothing.

A leg's shape throws, so a bad key, a duplicate key, a `Once` on a leg. A leg's `Fields` answer
[`Invalid`](/docs/concepts/reasons) instead, the same as `Edit`, and nothing is prepared when they do.

Before it drives, a transaction leases each of its keys in MemoryStore for ten seconds. A second
server after the same keys answers `Busy` at once, for one request unit and no datastore call,
instead of driving into the first server's legs and learning the same `Busy` eight requests later.
The lease only orders who tries. The marker still decides, no server waits on another, a server that
cannot reach MemoryStore drives as before, and a lease nobody lets go of answers `Busy` for at most
ten seconds. A two leg transaction spends 8 request units on its leases.

See [Transactions](/docs/guides/transactions).

### Reset [#reset]

```luau
Store:Reset(Key: KeyLike) -> Future<boolean, Reason?>
```

Puts the key back to `Default`, keeping `_Received` and `_Held`. A record written at a version this
server doesn't know answers [`Behind`](/docs/concepts/reasons) rather than `Refused`, because
nothing turned the write down, this server just can't read what's there.

A key with a transaction parked on it answers [`Busy`](/docs/concepts/reasons). Resetting it would
throw away a leg the transaction still counts as committed. Settle it with `Resettle` first.

### Inspect [#inspect]

```luau
Store:Inspect(Key: KeyLike) -> Future<Record?, Reason?>
```

The record itself rather than the state it folds to: the snapshot, the ops not yet compacted into it,
the applied ids, and the version. `Peek` answers what the player has, `Inspect` answers what is on
the key.

```luau
local Record = Store:Inspect(UserId):Wait()
if Record then
	print(`{#Record.Ops} op(s) waiting on top of the snapshot`)
	for _, Op in Record.Ops do
		print(Op.Id, Op.Kind)
	end
end
```

What it hands back is frozen, like everything else Ledger gives you. To change a key, use `Edit`,
`Reset` or `Erase`.

### Erase [#erase]

```luau
Store:Erase(Key: KeyLike) -> Future<boolean, Reason?>
```

Throws the record away and leaves a tombstone. Anything the key still owes someone else goes first:
money it was part way through sending, and units a `Reserve` set aside with a `To`. Ledger names
whatever it could not pass on before the key went. For 8 days the tombstone refuses anything sent to
the key, so money still being sent returns to whoever sent it.
See [Erase](/docs/guides/recovery#erase).

The tombstone holds for the full 8 days even if the key is written to again. A session on another
server knows nothing about the erase and keeps saving, and those writes no longer cancel the
tombstone. Ledger warns when one arrives, because it means the player is still live somewhere. Get
them off every server before erasing them.

A key with a transaction parked on it answers [`Busy`](/docs/concepts/reasons), the same as `Reset`.

`false` means the record is still there. Check it before you tell anyone their data is gone.

## Watching writes [#watching-writes]

### Stale [#stale]

```luau
Store:Stale() -> Observer<string>
```

A stream of the keys this server has changed. Ledger pushes a key onto it once the write has gone
through, so you can refresh a session on that key at once.

```luau
Store:Stale():Subscribe(function(Key)
	print(`{Key} changed`)
end)
```

These writes push a key:

| method                             | what it pushes                           |
| ---------------------------------- | ---------------------------------------- |
| `Edit`, `Confirm`, `Bump`, `Reset` | the key it wrote                         |
| `Transfer`                         | both keys                                |
| `Tx`                               | every leg key, onto that leg's own store |

Nothing else pushes. A write the reducer refuses pushes nothing, and so does a read, an `Erase` and
every maintenance method.

`Session:Apply` and `Session:Commit` push nothing either. That session already holds the change, so
it has nothing to catch up on.

The key is a string. A player store keys on the `UserId`, so call `tonumber` on it before you look
the player up.

Listeners on this stream run on their own thread and may yield, which the ones on
`Session:Observe()` may not. See [Observer](/docs/reference/observer#listeners-that-may-yield).

Use it to flush a session the moment another part of your game writes to its key. See
[Transactions](/docs/guides/transactions#a-live-session-does-not-know-a-leg-wrote-to-it).

## Maintenance [#maintenance]

### Resettle [#resettle]

```luau
Store:Resettle(Key: KeyLike) -> Future<boolean, Reason?>
```

Settles any transaction leg parked on the key and finishes any transfer set aside on it. `true` means
nothing is left unfinished. `Busy` means a leg is still waiting on a decision, so try again later.

The recovery sweep calls this for you every minute. It is here for the case the sweep warns about,
where it is already following its limit of keys or has given up on one after five goes.

### RecoverTransfers [#recovertransfers]

```luau
Store:RecoverTransfers(Key: KeyLike) -> Future<boolean, Reason?>
```

Forces stranded transfers on one key to finish or refund. The sweeper already does this, so it's for
support tools.

### ClearDelivered [#cleardelivered]

```luau
Store:ClearDelivered(Key: KeyLike) -> Future<boolean, Reason?>
```

Drops delivered transfer ids older than 30 days from the key. Happens on its own.

Both this and `RecoverTransfers` work on any store, since a transfer can move any number field.

### Destroy [#destroy]

```luau
Store:Destroy() -> ()
```

Saves every live session, frees the name, and takes the store out of the registry. Every method
throws afterwards.


# Types (https://xoifaii.github.io/LedgerDocs/docs/reference/types)



Everything here is exported off the top level module, so `Ledger.Op`, `Ledger.Store` and so on.

## Op [#op]

```luau
type Op = {
	Id: string,
	Kind: string,
	[any]: unknown,
}
```

One change. `Id` and `Kind` are Ledger's, everything else is yours.

`Ledger.Op` is the open op above and every field on it reads as `unknown`. `Ledger.Op<Ops>` is the op
as one of the kinds you named, so testing `Op.Kind` narrows to that kind and its fields come out
typed. See [Typed ops](/docs/concepts/typed-ops).

`Id`, `Kind` and `OnceAt` are reserved. Passing any of them in `Fields` warns and gets overwritten.

`Once` is yours to set, and it's what makes the op apply at most one time on that key. See
[Once](/docs/concepts/once).

Every method that can fail answers `(value?, Reason?)` or `(boolean, Reason?)`. Nothing in Ledger
throws into a Future, so `Wait` never comes back empty on you. See
[Reasons](/docs/concepts/reasons).

## OpOf [#opof]

```luau
type OpOf<O, K> = { Id: string, Kind: K } & index<O, K>
```

One kind out of your op map, for a reducer that gives each kind its own function. See [with named
ops](/docs/concepts/advanced-reducers#with-named-ops).

```luau
local function SpendGold(State: Profile, Op: Ledger.OpOf<Ops, "SpendGold">): Profile?
	return SetPath(State, { "Gold" }, State.Gold - Op.Amount)
end
```

## Reducer [#reducer]

```luau
type Reducer<S, O = any> = (State: S, Op: Op<O>) -> S?
```

See [Writing a reducer](/docs/concepts/reducer).

## Reason [#reason]

```luau
type Reason =
	"Refused" | "Busy" | "Spent" | "Unresolved" | "Closed"
	| "Backlog" | "Full" | "Invalid" | "Behind" | "Held"
```

Compare against `Ledger.Reason.Refused` and friends rather than the literals. See
[Reasons](/docs/concepts/reasons).

## KeyLike [#keylike]

```luau
type KeyLike = number | string
```

A UserId on a player store, a key string on an entity store. Ledger checks which one the store wants
and throws with what it expected.

## KeysMode [#keysmode]

```luau
type KeysMode = "Player" | "String"
```

## Config [#config]

```luau
type Config<D> = {
	read Name: string,
	read Reducer: (State: D, Op: Op) -> unknown,
	read Default: D,
	read Balance: string?,
	read Migrations: { Migration }?,
	read Keys: KeysMode?,
	read OnLoadFailed: ((Player: Player, Why: Reason) -> boolean)?,
}
```

What `Ledger.New` takes. See [Ledger.New](/docs/reference/ledger#ledgernew).

## TypedConfig [#typedconfig]

```luau
type TypedConfig<D, O> = {
	read Name: string,
	read Reducer: (State: D, Op: Op<O>) -> D?,
	read Default: D,
	read Balance: string?,
	read Migrations: { Migration }?,
	read Keys: KeysMode?,
	read OnLoadFailed: ((Player: Player, Why: Reason) -> boolean)?,
}
```

What `Ledger.NewTyped` takes. The reducer gets the op as one of the kinds you named, and it has to
give back your state or `nil`. See [Typed ops](/docs/concepts/typed-ops).

## TypedStore and TypedSession [#typedstore-and-typedsession]

```luau
type TypedStore<D, O>
type TypedSession<S, O>
```

What `Ledger.NewTyped` hands back, and what `Store:Expect` gives you on one. They carry the same
methods as `Store<D>` and `Session<S>`, with `Apply`, `Commit` and `Edit` checked against the ops you
named.

```luau
local function Buy(Session: Ledger.TypedSession<Profile, Ops>, Item: string)
	return Session:Apply("Buy", { Item = Item })
end
```

## OpMap [#opmap]

```luau
type OpMap = { [string]: { [any]: any } }
```

The shape a map of ops has: the kind, and the fields that kind carries. Annotate your own map with it
to catch a malformed entry where you write it.

```luau
export type Ops = {
	Buy: { Item: string },
	AddGold: { Amount: number },
}
```

## Record [#record]

```luau
type Record<D> = {
	Snapshot: D?,
	Bytes: number?,
	Ops: { Op },
	Seen: { string },
	Version: number?,
	Floor: number?,
	Envelope: number?,
	Erased: number?,
}
```

What [`Store:Inspect`](/docs/reference/store) hands back. It's a frozen copy, so nothing you do to it
reaches what the server folds from.

## Migration [#migration]

```luau
type Migration =
	((State: any) -> any)
	| { Apply: (State: any) -> any, Compatible: boolean? }
```

A plain function, or a table when you need `Compatible`. See
[Migrations](/docs/guides/migrations).

## TxLeg [#txleg]

```luau
type TxLeg = {
	Store: Store<any>?,
	UserId: number?,
	Key: string?,
	Kind: string,
	Fields: { [any]: any }?,
}
```

One leg of a transaction. `Store` defaults to the one you called `Tx` on. Use `UserId` for a player
store and `Key` for a string keyed one.

## HoldOptions [#holdoptions]

```luau
type HoldOptions = {
	Hold: number?,
}
```

The options table [`Store:Reserve`](/docs/reference/store) takes last. `Hold` is how long to keep the
units, in seconds, and defaults to 15 minutes. See [Reservations](/docs/guides/reservations).

## HistoryEntry [#historyentry]

```luau
type HistoryEntry = {
	Version: string,
	At: number,
	Deleted: boolean,
}
```

`At` is Unix seconds. `Version` is what you hand to `PeekVersion`.

## Future [#future]

What every method that touches the datastore hands back. The work starts at the call, `:Wait()`
parks your thread until it's done.

```luau
local Job = Store:Peek(UserId)
DoSomethingElse()
local State = Job:Wait()
```

See [Future](/docs/reference/future) for timeouts, error handling, and why a failed read gives you
`nil`.

## Observer [#observer]

What `Session:Observe()` and `Store:Stale()` hand back. Subscribe for every change that goes
through, and chain with `Map`, `Filter` and `Changed`.

```luau
Session:Observe():Subscribe(function(State)
	UpdateHud(Player, State)
end)
```

See [Observer](/docs/reference/observer).

## Typing your own state [#typing-your-own-state]

Write the state type yourself and let the store carry it:

```luau
export type Profile = {
	Gold: number,
	Items: { string },
}

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	-- ...
end

local Store: Ledger.Store<Profile> = Ledger.New({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {} } :: Profile,
	Reducer = Reducer,
})
```

`Session:Get()` then gives you a `Profile`, and the reserved fields stay out of your type. They're
there at runtime, your reducer passes them through with `table.clone`, and you don't have to declare
them.
