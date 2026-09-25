# Getting started (https://xoifaii.github.io/LedgerDocs/docs/getting-started)



## Install [#install]

<Tabs items={['Wally', 'Rojo', 'Model file', 'roblox-ts']}>
  <Tab value="Wally">
```toml
[dependencies]
Ledger = "xoifaii/ledger@6.2.0"
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

You can put Ledger where the client can also see it, next to shared type definitions. It still only
runs on the server, because only the server can reach a datastore. Requiring it from a client throws
an error.

### If you code with an AI agent [#if-you-code-with-an-ai-agent]

Ledger ships an agent skill. It tells the agent which call fits each job, which calls are safe to run
on a live player's key, and what a bug that duplicates money without an error looks like in your code.

```
npx skills add XoifaiI/Ledger
```

It installs for Claude Code, Codex, Cursor, Copilot, Gemini and the rest in one go, and it carries a
copy of these docs, so it still works when the agent can't reach the web.

## Build a store [#build-a-store]

A store is one datastore name plus the rules for everything under it. Build it once, near the top of
a server script.

Start simple: one field, the ops that change it, and a reducer that returns the next state or `nil`
to refuse:

```luau
local Ledger = require(ServerStorage.Ledger)

export type Profile = {
	Gold: number,
}

export type Ops = {
	AddGold: { Amount: number },
	SpendGold: { Amount: number },
}

local function Reducer(State: Profile, Op: Ledger.Op<Ops>): Profile?
	if Op.Kind == "AddGold" then
		if Op.Amount <= 0 then
			return nil
		end
		return { Gold = State.Gold + Op.Amount }
	end

	if Op.Kind == "SpendGold" then
		if Op.Amount <= 0 or Op.Amount > State.Gold then
			return nil
		end
		return { Gold = State.Gold - Op.Amount }
	end

	return nil
end

local Store = Ledger.New<<Profile, Ops>>({
	Name = "PlayerData",
	Default = { Gold = 100 },
	Reducer = Reducer,
	Balance = "Gold",
})
```

`Ops` lists each kind of op and the fields it carries. Every write is checked against it, so a
misspelled kind or a missing field is an error where you wrote it, and the reducer reads
`Op.Amount` as a number. See [Typed ops](/docs/concepts/typed-ops).

The reducer takes the state and one op and returns the next state, or `nil` to refuse it. It has to
be pure. [Writing a reducer](/docs/concepts/reducer) covers the rules and what breaks when you
don't keep them.

`Balance` is optional. You only need it for [transfers](/docs/guides/transfers), and it names a
number field that's already in `Default`.

### Once there is more than one field [#once-there-is-more-than-one-field]

Writing the next state out by hand stops working as soon as `Default` grows. Any field you don't
mention is not in the state you returned, so it is gone from that moment on.

Copy the state and change what you need instead:

```luau
export type Profile = {
	Gold: number,
	Items: { string },
}

export type Ops = {
	AddGold: { Amount: number },
	PickUp: { Item: string },
}

local function Reducer(State: Profile, Op: Ledger.Op<Ops>): Profile?
	if Op.Kind == "AddGold" then
		if Op.Amount <= 0 then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold += Op.Amount
		return Next
	end

	if Op.Kind == "PickUp" then
		local Next = table.clone(State)
		Next.Items = table.clone(State.Items)
		table.insert(Next.Items, Op.Item)
		return Next
	end

	return nil
end
```

`table.clone` is shallow, so `Items` needs a copy of its own before you touch it. The state you were
given is deep frozen, so writing into it throws on the line that did it rather than breaking a fold
somewhere later.

When state is nested more than one level deep, the copying gets hard to read. [Advanced
reducers](/docs/concepts/advanced-reducers#changing-nested-state) has a helper for it.

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
next save. It returns `(boolean, Reason?)`, and `false` means either your reducer refused it or
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

This fires on every change the session applies. A write from somewhere else, such as a transfer or
a transaction, fires it only once the session reads the key again. That happens at the next autosave
while it has ops queued, within two minutes while it has none, or when you call `Flush`. See
[Transactions](/docs/guides/transactions#a-live-session-does-not-know-a-leg-wrote-to-it).

## Running without a datastore [#running-without-a-datastore]

`Mock = true` puts a store on an in memory datastore and it never touches `DataStoreService`. Real
limits, no API access, no published place.

```luau
local Store = Ledger.New<<Profile, Ops>>({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {} },
	Reducer = Reducer,
	Mock = true,
})
```

The mock is stricter than Studio on purpose, because Studio has request budgets a live server never
gets. See [Testing](/docs/guides/testing).

## A store that takes any op [#a-store-that-takes-any-op]

Leave out the two types, `Ledger.New(Options)`, and the store takes any kind with any fields. That
suits a store whose ops are still changing. The reducer then gets `Ledger.Op`, every field reads as
`unknown`, and the reducer has to check each field's type before it uses it. See
[Typed ops](/docs/concepts/typed-ops).


# Overview (https://xoifaii.github.io/LedgerDocs/docs)



Ledger stores player data as a log of changes, not as one document that each save overwrites. You
don't set state directly. You write an op that describes a change, your reducer decides whether it
is allowed, and the state is what you get from applying every op in order.

```luau
export type Profile = { Gold: number }

export type Ops = {
	Earn: { Amount: number },
	SpendGold: { Amount: number },
}

local Store = Ledger.New<<Profile, Ops>>({
	Name = "PlayerData",
	Default = { Gold = 100 },
	Reducer = function(State, Op)
		if Op.Kind == "Earn" then
			if Op.Amount <= 0 then
				return nil
			end
			return { Gold = State.Gold + Op.Amount }
		end

		if Op.Kind == "SpendGold" then
			if Op.Amount <= 0 or Op.Amount > State.Gold then
				return nil -- refused on every server
			end
			return { Gold = State.Gold - Op.Amount }
		end

		return nil -- a kind this reducer doesn't handle
	end,
})

Store:Load(Player)
Store:Expect(Player):Apply("SpendGold", { Amount = 25 })
```

If two servers both spend the same 100 gold, both writes land. The reducer accepts the first and
refuses the second. Every server replays the same log, so every server gets the same result.

## No session locks [#no-session-locks]

Most datastore libraries lock a player's data to one server at a time. That has three costs:

- A server that crashes keeps the lock until it expires.
- A player waits at the join screen while another server holds the lock.
- No server can write to a player who is offline or on another server.

Ledger doesn't lock. Your reducer refuses any op that would break your rules, so bad state is never
written, and a crash leaves nothing to unlock. In return, every change has to be a named op, and you
have to write the reducer.

## What's in it [#whats-in-it]

<Cards>
  <Card title="The fold" href="/docs/concepts/the-fold">
    State is the log replayed through your reducer, so every server gets the same result without a lock.
  </Card>
  <Card title="Apply and Commit" href="/docs/concepts/apply-and-commit">
    Apply changes state on this server immediately. Commit waits for the datastore and tells you whether your op went through.
  </Card>
  <Card title="Cross server writes" href="/docs/reference/store">
    Edit, Transfer and Tx write to any key, whether the player is on this server, another one, or offline.
  </Card>
  <Card title="Entity stores" href="/docs/guides/entity-stores">
    String keys for data no single player owns, like clans, listings and world records.
  </Card>
  <Card title="Transfers" href="/docs/guides/transfers">
    Move a balance between two keys. Each transfer has an id, so it applies once and finishes after a crash.
  </Card>
  <Card title="Transactions" href="/docs/guides/transactions">
    Change two to four keys all or nothing. The keys can be in different stores.
  </Card>
  <Card title="Once" href="/docs/concepts/once">
    Name an op after a receipt or an order, and it applies only once.
  </Card>
  <Card title="Migrations" href="/docs/guides/migrations">
    Change the shape of your data in numbered steps. Safe to roll out one server at a time.
  </Card>
  <Card title="Typed ops" href="/docs/concepts/typed-ops">
    Declare what each op carries, and every write is type checked against it.
  </Card>
</Cards>

## What Ledger doesn't do [#what-ledger-doesnt-do]

Ledger runs on the server only. It doesn't send data to clients, and it has no leaderboards or
ordered stores. It also can't fix a reducer that is wrong. If your reducer reads `os.time()` or
`math.random()`, two servers replaying the same log get different state. Ledger warns about this in
Studio.


# Limits (https://xoifaii.github.io/LedgerDocs/docs/limits)



Some of these are Roblox's and some are Ledger's. You can't change the Roblox ones. The Ledger ones
are set below the real limit so you get a clean refusal instead of a failed save.

## Names and keys [#names-and-keys]

| | Cap | |
| --- | --- | --- |
| Store name | 47 characters | Ledger, so `<Name>_Tx` fits in the datastore's 50 |
| Entity key | 50 characters | Roblox |
| Transfer id | 64 characters | Ledger |
| Transaction id | 50 characters | Ledger |

Player keys are the UserId, so they always fit. Entity keys have to be valid UTF-8.

## Size [#size]

| | Cap | |
| --- | --- | --- |
| Stored value | 4 MB | Roblox |
| Folded state | 2 MB | Ledger |
| One op | 1 MB | Ledger |
| Unsaved ops | 1.5 MB | Ledger |
| Queued ops | 4096 | Ledger |
| Reservations on one key | 256 | Ledger |

State can hold numbers, strings, booleans, tables and buffers. A buffer counts as about a third more
than its length. The datastore stores a buffer at that size, and these caps count the same size.

State caps at 2 MB rather than 4, which leaves room for the ops stored alongside the snapshot.

An op that would push state over the cap is refused with [`Full`](/docs/concepts/reasons). Ops that
shrink it are still allowed, so a cleanup works when you're already over.

Size also decides how often a key can be written. Roblox lets one key take 4 MB of writes a minute,
and every write stores the whole record again. An active player saves twice a minute. A player key
near the 2 MB cap then uses its whole per minute write limit on autosaves, and a `Commit` waits
behind them. Keep an active player key under about 1 MB.

A key many servers write to reaches the same limit sooner. Once it has taken 2,048 ops, its list of
seen op ids alone is about 55 KB. At that size, the 4 MB a minute allows about 70 writes a minute
before the rest of the state is counted.

Hitting the unsaved caps returns [`Backlog`](/docs/concepts/reasons), and in practice that only
happens when the datastore is down.

Ledger keeps two tables of its own in the state, and they clear on different rules:

| | Holds | Clears after |
| --- | --- | --- |
| `_Received` | names already applied | 30 days |
| `_Held` | units set aside for a transfer | 7 days to deliver, 8 to give back |

A reservation is not one of them. A hold lives in MemoryStore and uses no space on the key.

Neither grows with uptime. Each is bounded by how much happened inside its own window.

## Applied names [#applied-names]

The set of applied names lives in the state, so it counts against the state cap. It does not grow
without bound. Ledger keeps the applied names in one bucket per day. Every time one is written,
Ledger drops every day's bucket older than 30 days, for every kind of applied name. An applied name
lasts 30 to 31 days.

A write copies only the bucket for its own day. The cost of a write does not grow with the names on
the key.

One applied name is about 37 bytes when Ledger picked the id, and more if you chose the id yourself.
A rolling 30 day window is nowhere near the state cap for any real player. An applied name also
carries a short fingerprint of the terms. The fingerprint lets an id reused for a different amount
return [`Spent`](/docs/concepts/reasons) instead of `true`.

`ClearDelivered` drops the day buckets older than 30 days now, rather than at the next write of an
applied name. It never drops a delivery id younger than 30 days. A sender can ask for a refund up to
that point, and the refund needs the evidence that the delivery happened.

A key that many players write to fills as fast as all of them write to it. Every `Tx` leg and every
`Transfer` adds one applied name of about 37 bytes, kept for 30 days. That is about 1,900 a day on
one key before the applied names alone fill the state cap. A transfer into or out of a full key then
returns [`Full`](/docs/concepts/reasons), and the money stays where it was. The key still takes
other writes, and it takes transfers again as old day buckets run out.

`Reserve` adds no name. `Confirm` adds one only when you give it a [`Once`](/docs/concepts/once).
Stock sold without one has no such ceiling.

While the traffic keeps up, the key stays at the cap. Each day bucket that runs out makes room, and
the next legs and transfers fill it again. `ClearDelivered` cannot help, because nothing on the key
is older than 30 days. Spread the entity over several keys before that point, the same way `Bump`
spreads a total. See [Entity stores](/docs/guides/entity-stores).

A short id such as `tip:8412` takes fewer bytes than a random string, which keeps this set smaller.

## Transactions [#transactions]

Between 2 and 4 legs, and a key can only appear once.

One key doesn't need a transaction, which is why two is the minimum. `Edit` already applies to a
single key or refuses it.

The maximum is four because each leg blocks its key while it waits. A leg is written to its key
first and stays parked there, and anything else writing to that key meanwhile returns
[`Busy`](/docs/concepts/reasons). If the server running the transaction dies, another one has to
abort it, and it may not do that until the marker has been unchanged for 30 seconds per leg. Four
legs can block four keys for two minutes.

Committed markers get tidied up in the background about an hour later.

A transaction id ages out after 30 days, the same as every other applied name. A transaction lives at
most an hour, so 30 days covers the whole protocol many times over. It does not cover an id reused a
month later, which applies again. Derive ids from the thing the transaction is for, and they are
never reused.

### One key at a time [#one-key-at-a-time]

A key takes one transaction at a time. While a leg is parked on it, every other transaction touching
that key returns [`Busy`](/docs/concepts/reasons) and stops. `Tx` does not retry a `Busy` for you,
because every server retrying at once would multiply the load on a key that is already contended.

Retry it yourself with a short backoff. Measured on the mock, with 32 servers each starting a two leg
transaction on one bank key at the same moment:

| | went through | datastore requests | MemoryStore units |
| --- | --- | --- | --- |
| With MemoryStore | 1 | 8 | 101 |
| Without MemoryStore | 2 | 130 per success | 0 |

With MemoryStore, the first server to lease the keys drives the transaction. The others return `Busy`
at once, having spent about 3 units each and no datastore request. Without MemoryStore, every server
drives its transaction and they race on the key.

Plan around this for anything every player writes to, such as a guild bank, a global shop or an event
total. Spread the writes across keys where you can, for example one key per guild rather than one for
all of them. Correctness never suffers from contention, only throughput.

### What an operation costs [#what-an-operation-costs]

Measured on the mock, for the path where nothing fails.

| operation | datastore requests |
| --- | --- |
| `Peek`, `Edit`, `EditOp`, `Bump` | 1 |
| `Bump`, with `BumpEvery` | 0, and one per total per window |
| `Peek` with a `MaxAge`, from this server's copy | 0 |
| `Peek` with a `MaxAge`, from the shared copy | 0, and one MemoryStore unit |
| `Peek` with a `MaxAge`, refilling the copy | 1, and five units, on one server a minute |
| `Reserve`, the first hold on a key | 1, and four MemoryStore units |
| `Reserve`, `Release` | 0, and two MemoryStore units |
| `Confirm` | 1, and three MemoryStore units |
| `Holds` | 0, and one MemoryStore unit |
| `Transfer` | 3, or 4 with your own `Id` |
| `Tx`, 2 legs | 8, and eight MemoryStore units |
| `Tx`, 4 legs | 12, and sixteen MemoryStore units |
| `Total`, from this server's own sum | 0 |
| `Total`, from the cached sum | 0, and one MemoryStore unit |
| `Total`, cold | 16, and five units, on one server a minute |

A transaction spends 4 requests on its marker whatever the leg count, so the marker is half the cost
of a two leg transaction. It also spends 4 MemoryStore units a leg to lease its keys, so two servers
do not drive one key at once. A `Transfer` with your own `Id` reads the receiver first, to tell a
retry from a new transfer. A limit that lives on one key is a reservation, not a transaction. See
[Reservations and totals](/docs/guides/reservations).

Roblox gives an experience `UpdateAsync` budget of `300 + 20 per CCU` a minute, which works out at
about 20 writes per player per minute at any real player count. So a player can average roughly 6
transfers or 2 two leg transactions a minute across the whole experience, before autosave takes its
share. Autosave itself is cheap and does not scale with how busy a player is. See
[Timing](#timing).

## Transfers [#transfers]

Recovery resends an unfinished transfer for 7 days. After that it expires and the sender gets the
money back. Delivered ids stay in the receiver's applied names for 30 days so a late retry can't pay
twice.

Recovery handles up to 32 holds per pass, so a key with many unfinished transfers takes a few passes.

## Reservations and totals [#reservations-and-totals]

A hold lasts 15 minutes. That is both the default and the cap. `Hold` sets a shorter time per
reservation, and `Reserve` throws above the cap. A checkout that stays open longer calls `Reserve`
again under the same Id. A hold lives in MemoryStore, so it uses no space on the key and expires on
its own. One key holds 256 at once.

Holds share the experience's MemoryStore quota, `1000 + 120 × concurrent users` request units a
minute, with totals, transaction leases and followed keys. A `Reserve` or `Release` is two units,
and the first hold on a key is four units and one request. A `Confirm` is three. A `Holds` is one. A
transaction is four a leg. A key read through
[`Follow`](/docs/guides/entity-stores#following-a-key) costs one unit per tick on each server that
follows it. A tick is every 30 seconds, and slows to every 4 minutes while the key does not change.
`Follow` and `Peek` with a `MaxAge` read a copy of the key kept in MemoryStore. The one server that
refills that copy spends five units and one request each minute. The copy has to fit one MemoryStore
item, 32 KB of your fields. A bigger key is read from the record by every server, and Ledger warns
about it at most once every 30 seconds.

A total is spread over 16 keys, or the `Shards` the store names, 1 to 99. `Total` returns a sum
cached in MemoryStore, for one request unit. A server that read the sum inside the `MaxAge` you pass,
60 seconds by default, returns its own copy and spends nothing. Each server treats the cached sum as
stale after its own time between 60 and 75 seconds. Only one server then refills it: it reads every
shard, one request each, and caches the sum again. The other servers return the cached sum
meanwhile. `Bump` costs one request and no units. With `BumpEvery` a server pays one request per
total per window, however many times it bumps.

Each server bumps one shard key, and one shard key takes about 80 writes a minute. With a
`BumpEvery` of 60, that is about 80 servers on each shard. Set `Shards` to the number of servers
that bump the total, divided by 80. The default of 16 covers about 1,300 servers. Without
`BumpEvery`, every bump is its own write, so count bumps a minute instead of servers. Raise `Shards`
before you need it. Never lower it.

See [Reservations and totals](/docs/guides/reservations).

## Timing [#timing]

Autosave runs every 30 seconds per session, and compacts as well when the log has gotten long.

A session with nothing queued and no transaction parked on it reads on every fourth autosave. An idle
player then costs one request every two minutes rather than one every 30 seconds. A session with ops
queued still writes at the next autosave. Only the read for what other servers did waits.

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

There's no lock, so no cap on how many servers write the same key at once. Every server folds the
same log, so they all agree on the result. A busy key is still limited by throughput: by the write
rate under [Size](#size), and by one transaction at a time under
[One key at a time](#one-key-at-a-time).


# Releases (https://xoifaii.github.io/LedgerDocs/docs/releases)



`+` is new, `-` is gone, `!` is something you have to know about before you upgrade.

## 6.2.0 [#620]

A transaction makes one datastore call fewer, and a session notices an erase when it compacts. Most
of this release is internal cleanup that you cannot see.

```diff
+ A transaction makes one datastore call fewer. A two leg transaction now makes 8 calls instead of 9
+ Session:Compact on a key another server erased closes the session and returns false with Refused, instead of true
+ A store with BumpEvery does less work for each Bump that waits for its window
+ An applied name from before 6.0 with no time Ledger can read counts as run out at once, instead of after the next write

! The error Session:Apply throws when your reducer yields is an error object now, not a string. Call tostring on it before you match its text
! A 6.2 server does not look for a transaction marker that a 6.0.0 or older server wrote. Read Upgrading if a server still runs 6.0.0
```

### Upgrading [#upgrading]

Install the new version. Your data needs no migration, and 6.2 servers can run beside 6.0.1 and 6.1
servers.

If a server still runs 6.0.0 or older, finish that deploy first. Those servers write each
transaction marker under the transaction Id, and a 6.2 server does not look there. While both run, a
6.2 server that drives an Id that an older server is still driving returns `Busy`. That lasts until
the older run times out, about a minute later. Money is safe either way.

If you `pcall` `Session:Apply` and read the error as a string, call `tostring` on it first.

## 6.1.0 [#610]

There is now one `Ledger.New`. Give it your state and op types for a typed store, or call it plain
for a store that takes any op. This release also closes a few ways a retry or a race could give the
wrong result.

```diff
+ Ledger.New<<Profile, Ops>>(Options) builds a typed store. Ledger.New(Options) still builds an open one
- Ledger.NewTyped. Use Ledger.New<<Profile, Ops>> instead
+ EditOp, CommitOp and Confirm take IdAt, the time you first sent an op with your own Id. A retry that arrives after the key has dropped that id returns Unresolved instead of applying again
+ Session:Commit compacts a full log once and tries again before it returns Full
+ Session:Commit returns Unresolved when a parked transaction could still change whether its op applies, instead of true
+ A write that arrives while a second Erase removes the key returns Busy instead of being lost
+ A transaction whose marker takes minutes to write stays on the cleanup list, so its legs are still settled if the server stops

! Ledger.NewTyped is gone. Rename each call to Ledger.New, with the same type arguments and options
! Session:Commit can return Unresolved while a transaction is parked on the key. Don't call Commit again, read the key once it settles
```

### Upgrading [#upgrading]

Rename `Ledger.NewTyped` to `Ledger.New`. The arguments are the same, so nothing else changes. In
TypeScript, `Ledger.NewTyped<Profile, Ops>(...)` becomes `Ledger.New<Profile, Ops>(...)`.

Your data needs no migration, and 6.1 and 6.0 servers can run side by side. Until the deploy
finishes, a 6.0 server ignores `IdAt` and the mark a second `Erase` leaves, and when it compacts a
key it drops the record of which ids that key has forgotten. A 6.1 server starts that record again at
its next compaction of the key, so finish the deploy before you rely on `IdAt`.

If you retry `EditOp`, `CommitOp` or `Confirm` with your own `Id`, send `IdAt` with it. See
[Why a retry is safe](/docs/concepts/handling-failure#why-a-retry-is-safe).

## 6.0.1 [#601]

A small release. `Default` now only reaches new players, and cleaning up after transactions costs
less.

```diff
+ Changing a value in Default no longer changes players who already have data. It only reaches new players
+ A migration now reaches every player, including one whose data has not been compacted yet
+ The reaper removes a transaction marker in one try instead of spending budget on retries
+ Each run of a transaction gets a marker of its own, so the reaper only ever removes the one it checked
+ The reaper checks that a marker has not changed since it looked before it removes it
+ A transaction Id whose old marker is being cleaned up can run again straight away instead of answering Busy
```

### Upgrading [#upgrading]

Install the new version. Your data needs no migration.

6.0.1 records a player's starting values the first time it saves them. Install it before you change
a value in `Default`, so players who already have data keep the values they started with. A player
that 6.0.1 has not saved yet takes the `Default` in place at that first save.

A transaction Id reused for different terms answers `Busy` while its first run is still in progress,
and `Spent` once that run went through.

## 6.0.0 [#600]

Most of this release is guard rails. Ledger now stops more mistakes before they reach your data, and
a busy shared key gets a lot cheaper.

```diff
+ A busy shared key folds about 30 times faster, and its applied names take about a quarter less room
+ A key that is full answers Full to a transfer instead of growing until it stops taking writes
+ Erase waits for money that is still on its way to another player, instead of taking it with the key
+ A transfer Id that two senders share can no longer settle against the wrong delivery
+ Calling Erase twice can no longer let a transfer be paid back after it arrived
+ A migration that edits Ledger's own fields gets them put back, with a warning that names the step
+ A session stops when another server erases its key, instead of showing an empty profile
+ A player who joins twice in one server keeps their data when the older copy leaves
+ Totals stay right while a deploy raises Shards
+ A copy never goes back to an older state than this server already wrote
+ Warnings show their full message instead of a table address
+ Warnings no longer blame an erase or the datastore when another server simply wrote first
+ A transaction the reaper is already cleaning up cannot be committed late
+ What Peek with a MaxAge and Follow give you is frozen, like every other read
+ A server keeps at most 256 copies of keys that nobody follows

! 6.0 writes records in a new format that 5.x cannot read. Do not run the two side by side
! Erase can answer Busy now. It means money on the key is still being sent. Try again later
! What Peek with a MaxAge and Follow give you is frozen. Clone it before you change it
```

### Upgrading [#upgrading]

Stop every 5.x server before you start 6.0, the same way you would for any shutdown. A 5.x server
cannot read a key that 6.0 has written, so a mixed deploy fails to load some players.

Your data needs no migration. Each key moves to the new format by itself the next time it is written.

Two small things to check in your own code:

- If you change a value you got from `Peek` with a `MaxAge` or from `Follow`, clone it first.
- If you call `Erase`, treat `Busy` as "not yet" and call it again later. A transfer that cannot be
  delivered is given back after 8 days, and then the erase goes through.

## 5.4.1 [#541]

```diff
+ Fixed Ledger.Frozen refusing a state that holds a map or array of tables
```

### Upgrading [#upgrading]

Install the new version.

## 5.4.0 [#540]

```diff
+ A typed reducer can return a state whose nested tables are typed read only
+ Ledger.Frozen types a state as read only at every level, in Luau and in TypeScript
```

### Upgrading [#upgrading]

Install the new version.

## 5.3.0 [#530]

```diff
+ Transaction terms escape commas, brackets, = and %, so two different sets of fields never read as the same
+ Fixed a reaper bug that could half apply a transaction retried under its Id
+ Fixed WaitForLoaded answering nil for a player who rejoined mid load
- Removed redundant checks

! A transaction retried on 5.3.0 after it ran on an older server answers Spent if a leg string holds a comma, a bracket, = or %. Read the keys before you run it again under a new Id
```


# Advanced reducers (https://xoifaii.github.io/LedgerDocs/docs/concepts/advanced-reducers)



[Writing a reducer](/docs/concepts/reducer) covers the rules. This page is for a reducer with deep
state and many op kinds, where one long `if` chain and cloning by hand get hard to read.

It uses one small module, `Drafts`, which you copy into your project. Ledger does not ship it. The
full source is at the [end of the page](#the-drafts-module).

## One handler per op kind [#one-handler-per-op-kind]

Write a table with one function for each kind in your `Ops`, and give it to `Drafts.Reducer`:

```luau
local Drafts = require(ReplicatedStorage.Drafts)
local Open = Drafts.Open

type Pet = { Name: string, Level: number }

type Profile = {
	Gold: number,
	Title: string?,
	Items: { string },
	Stats: { Level: number, Best: { Score: number } },
	Pets: { [string]: Pet },
	Boost: { Until: number }?,
}

type Ops = {
	AddGold: { Amount: number },
	Buy: { Item: string },
	Score: { Score: number },
	Feed: { Pet: string },
	Boost: { For: number },
}

local Kinds: Drafts.Handlers<Profile, Ops> = {
	AddGold = function(State, Op)
		State.Gold += Op.Amount
		State.Title = "Rich"
		return State
	end,

	Buy = function(State, Op)
		table.insert(Open(State).Items, Op.Item)
		return State
	end,

	Score = function(State, Op)
		local Stats = Open(State).Stats
		Stats.Level += 1
		local Best = Open(Stats).Best
		Best.Score = math.max(Best.Score, Op.Score)
		return State
	end,

	Feed = function(State, Op)
		local Pets = Open(State).Pets
		if Pets[Op.Pet] == nil then
			return nil
		end
		Open(Pets)[Op.Pet].Level += 1
		return State
	end,

	Boost = function(State, Op)
		local Boost = Open(State).Boost
		if Boost == nil then
			State.Boost = { Until = Op.For }
		else
			Boost.Until += Op.For
		end
		return State
	end,
}

local Store = Ledger.New<<Profile, Ops>>({
	Name = "PlayerData",
	Default = {
		Gold = 0,
		Items = {},
		Stats = { Level = 1, Best = { Score = 0 } },
		Pets = {},
	},
	Reducer = Drafts.Reducer<<Profile, Ops>>(Kinds),
})
```

Each handler gets a copy of the state and the op, already narrowed to its kind, so `Op.Amount` in
`AddGold` is a number. Return the state to accept the op, or `nil` to refuse it.

- **Annotate the table.** `Kinds` has to be a local annotated `Drafts.Handlers<Profile, Ops>`.
  Without the annotation its functions are not typed.
- **Every kind needs a handler.** A kind in `Ops` with no handler is a type error. An op of a kind
  the table does not have is refused, which is what an older server should do with a kind it has
  never seen. See [ops you don't know](/docs/concepts/reducer#ops-you-dont-know).
- **The op is read only.** Writing to a field of `Op` is a type error.

<Callout type="warn">
  Don't start your own kinds with `__`. Ledger reserves that prefix for its transfer and transaction
  ops, and `Apply` refuses them with [`Invalid`](/docs/concepts/reasons).
</Callout>

## Changing nested state [#changing-nested-state]

A handler can write top level fields directly, like `State.Gold` above. Nested tables are read only.
Writing `State.Stats.Level` is a type error, and it throws at runtime if the type checker misses it.

`Open` makes a nested table writable. `Open(State).Items` copies `Items`, puts the copy back into
`State`, and returns the copy. Open once for each level you go down:

```luau
local Best = Open(Open(State).Stats).Best
Best.Score += 10
```

For a map, open the map and then the entry you change:

```luau
Open(Open(State).Pets)[PetId].Level += 1
```

- Only the tables you open are copied. Everything else is shared with the old state.
- Opening the same table again returns the same copy, so no write is lost.
- A field that can be `nil`, like `Boost`, opens to `nil` when it is missing. Assign a new table to
  the field on `State` instead, as the `Boost` handler does above.
- To add or remove an entry, open the table that holds it: `Open(State).Pets[PetId] = nil`.

### Helpers that read the state [#helpers-that-read-the-state]

A handler's state is not a `Profile`, because its nested tables are read only. A helper that takes
`State: Profile` does not accept it. Type the helper's parameter `Drafts.View<Profile>` instead:

```luau
local function CanAfford(State: Drafts.View<Profile>, Cost: number): boolean
	return State.Gold >= Cost
end
```

`View` is read only, so the helper cannot change the state by mistake.

## What folding costs [#what-folding-costs]

The reducer does not run once per op. It runs once when you `Apply`. It runs again for every op in
the log, on every read that folds the record. In Studio it runs a third time, when Ledger folds the
log again to check the reducer is pure.

A handler that loops over a table in the state repeats that loop for every op of its kind in the
log. One fold then costs the number of ops times the size of the table. Counting a collection to
enforce a cap is the usual cause:

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

A log of 128 ops against a profile holding 200 pets is 25,600 loop steps per fold, on a path that
runs on every read. Store the count as a field instead, and update it in the handler that adds or
removes an entry.

## Keep the result storable [#keep-the-result-storable]

Whatever the reducer returns is written as JSON. No metatables, no functions, no NaN, no mixing
array and string keys in one table, and no gaps in an array.

A gap is easy to make by mistake. Setting an array entry to `nil` leaves one:

```luau
Open(State).Items[Index] = nil -- leaves a gap
```

Use `table.remove`, so the array stays dense:

```luau
table.remove(Open(State).Items, Index)
```

Ledger will not compact a record whose state it cannot store, and it warns with the field name.
Nothing is lost. The log keeps growing until you fix it.

## Refuse with nil, don't throw [#refuse-with-nil-dont-throw]

Check the values on the op and return `nil` to refuse:

```luau
if Op.Amount <= 0 then
	return nil
end
```

A handler that throws is a bug. Ledger catches it, warns with the error message, and returns
`Refused`. See [check the fields](/docs/concepts/reducer#check-the-fields).

## A worked example [#a-worked-example]

A pet game, with an inventory cap, equip slots, and fusing three pets of the same species into one a
level higher.

```luau
local Drafts = require(ReplicatedStorage.Drafts)
local Open = Drafts.Open

type Pet = {
	Species: string,
	Level: number,
	Xp: number,
	Locked: boolean,
}

type Profile = {
	Coins: number,
	Pets: { [string]: Pet },
	Owned: number,
	Equipped: { [string]: true },
	Wearing: number,
	Slots: number,
	Discovered: { [string]: true },
}

type Ops = {
	Hatch: { PetId: string, Species: string },
	Feed: { PetId: string, Xp: number },
	Equip: { PetId: string },
	Sell: { PetId: string },
	Fuse: { PetIds: { string }, PetId: string },
}

local MAX_PETS = 200
local FUSE_COUNT = 3
local HATCH_COST = 250
local LEVEL_XP = 100

local function NewPet(Species: string, Level: number): Pet
	return { Species = Species, Level = Level, Xp = 0, Locked = false }
end

-- can this one pet go into a fuse of this species at this level
local function Fusable(State: Drafts.View<Profile>, Id: string, Species: string, Level: number): boolean
	local Pet = State.Pets[Id]
	if Pet == nil then
		return false
	end
	if Pet.Species ~= Species or Pet.Level ~= Level then
		return false
	end
	return not Pet.Locked and not State.Equipped[Id]
end

-- do these ids name a legal fuse, and if so which pet are they all
local function FuseInput(State: Drafts.View<Profile>, Ids: { string }): Pet?
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
	return { Species = Base.Species, Level = Base.Level, Xp = Base.Xp, Locked = Base.Locked }
end

local Kinds: Drafts.Handlers<Profile, Ops> = {
	Hatch = function(State, Op)
		if State.Pets[Op.PetId] ~= nil then
			return nil
		end
		if State.Owned >= MAX_PETS or State.Coins < HATCH_COST then
			return nil
		end

		State.Coins -= HATCH_COST
		State.Owned += 1
		Open(State).Pets[Op.PetId] = NewPet(Op.Species, 1)
		if State.Discovered[Op.Species] == nil then
			Open(State).Discovered[Op.Species] = true
		end
		return State
	end,

	Feed = function(State, Op)
		if Op.Xp <= 0 or State.Pets[Op.PetId] == nil then
			return nil
		end

		local Pet = Open(Open(State).Pets)[Op.PetId]
		local Gained = Pet.Xp + Op.Xp
		Pet.Xp = Gained % LEVEL_XP
		Pet.Level += Gained // LEVEL_XP
		return State
	end,

	Equip = function(State, Op)
		if State.Pets[Op.PetId] == nil or State.Equipped[Op.PetId] then
			return nil
		end
		if State.Wearing >= State.Slots then
			return nil
		end

		State.Wearing += 1
		Open(State).Equipped[Op.PetId] = true
		return State
	end,

	Sell = function(State, Op)
		local Pet = State.Pets[Op.PetId]
		if Pet == nil or Pet.Locked or State.Equipped[Op.PetId] then
			return nil
		end

		State.Owned -= 1
		State.Coins += 50 * Pet.Level
		Open(State).Pets[Op.PetId] = nil
		return State
	end,

	Fuse = function(State, Op)
		if #Op.PetIds ~= FUSE_COUNT or State.Pets[Op.PetId] ~= nil then
			return nil
		end

		local Base = FuseInput(State, Op.PetIds)
		if Base == nil then
			return nil
		end

		local Pets = Open(State).Pets
		for _, Id in Op.PetIds do
			Pets[Id] = nil
		end
		Pets[Op.PetId] = NewPet(Base.Species, Base.Level + 1)
		State.Owned -= FUSE_COUNT - 1
		return State
	end,
}

local Store = Ledger.New<<Profile, Ops>>({
	Name = "Pets",
	Default = { Coins = 1000, Pets = {}, Owned = 0, Equipped = {}, Wearing = 0, Slots = 3, Discovered = {} },
	Reducer = Drafts.Reducer<<Profile, Ops>>(Kinds),
})
```

`Owned` and `Wearing` are counts of `Pets` and `Equipped`. They are stored so no handler has to walk
either table.

Notes on the example:

**The fields are `PetId` and `Species`, not `Id` and `Kind`.** `Id` and `Kind` belong to Ledger,
and `Op.Kind` here is already `"Hatch"`. Name your own fields something else.

**The caller picks the id and the random species.** The reducer cannot call `math.random`, so the
server picks both before the write and puts them on the op.

**`Counted` in `FuseInput` rejects repeated ids.** Without it, `PetIds = { "a", "a", "a" }` passes
every other check. The fuse then removes one pet and adds a pet one level higher, so the player
gets a higher level pet without spending the other two. The removal loop cannot catch it either,
since removing the same key three times removes it once.

**`Fusable` and `FuseInput` take `Drafts.View<Profile>`.** They only read, and a handler's state is
not a `Profile`. See [helpers that read the state](#helpers-that-read-the-state).

**No handler loops over a table to count it.** `Owned` and `Wearing` change in the same handlers as
the tables they count, so hatching the two hundredth pet costs the same as the first.

**Every refusal is `nil`.** The call returns `Refused` whether the player had too few coins, had no
free slot, or chose a locked pet. To tell them which, check before you write:

```luau
if State.Coins < HATCH_COST then
	Tell(Player, "you need 250 coins")
	return
end

Session:Apply("Hatch", { PetId = HttpService:GenerateGUID(false), Species = Roll() })
```

The reducer still checks. The check before `Apply` only chooses the message. The check in the
reducer enforces the rule.

## The Drafts module [#the-drafts-module]

Copy this into a ModuleScript called `Drafts`, anywhere your reducer can require it.

```luau
--!strict
--!optimize 2

--[=[

	Drafts: Writes a reducer as one handler per op kind, on a copy of the state.

	Each handler gets the state with its top level copied, so it can write top level fields and
	return it. Nested tables stay read only. Open copies one nested table, puts the copy into its
	parent and returns it writable. A table that is already open is not frozen, so a second Open
	returns the same copy and keeps the first writes. The handler table has to be an annotated local, or its functions are not typed. View is
	the state as a helper reads it. A draft is not the state type, since its nested tables are read
	only, so a helper that only reads takes View.

	Return type: A table with Reducer and Open. The types are Handlers, View, Opener and Op.
	Example usage:
		local Kinds: Drafts.Handlers<Profile, Ops> = { AddGold = function(State, Op) ... end }
		local Reducer = Drafts.Reducer<<Profile, Ops>>(Kinds)
--]=]

export type function Op(Map: type): type
	local Arms = {}
	for Kind, Held in Map:properties() do
		local Fields = Held.read
		if Fields == nil then
			continue
		end
		if not Fields:is("table") then
			error(`op kind '{tostring(Kind)}' has to name the fields it carries, as a table, and it names {tostring(Fields)}`)
		end

		local Arm = types.copy(Fields)
		for Name in Fields:properties() do
			Arm:setwriteproperty(Name, nil)
		end
		Arm:setreadproperty(types.singleton("Kind"), Kind)
		Arm:setreadproperty(types.singleton("Id"), types.string)
		table.insert(Arms, Arm)
	end

	if #Arms == 0 then
		return types.never
	end
	if #Arms == 1 then
		return Arms[1]
	end
	return types.unionof(table.unpack(Arms))
end

export type function View(Shape: type): type
	local function Frozen(Held: type, Depth: number): type
		if Depth > 16 then
			return Held
		end
		if Held:is("union") or Held:is("intersection") then
			local Parts = {}
			for _, Part in Held:components() do
				table.insert(Parts, Frozen(Part, Depth + 1))
			end
			return if Held:is("union") then types.unionof(table.unpack(Parts)) else types.intersectionof(table.unpack(Parts))
		end
		if not Held:is("table") then
			return Held
		end

		local Out = types.newtable(nil, nil, Held:metatable())
		for Name, Field in Held:properties() do
			if Field.read ~= nil then
				Out:setreadproperty(Name, Frozen(Field.read, Depth + 1))
			end
		end
		local Indexer = Held:readindexer()
		if Indexer ~= nil then
			Out:setindexer(Indexer.index, Frozen(Indexer.result, Depth + 1))
		end
		return Out
	end

	return Frozen(Shape, 0)
end

export type function Handlers(Shape: type, Map: type): type
	local function Frozen(Held: type, Depth: number): type
		if Depth > 16 then
			return Held
		end
		if Held:is("union") or Held:is("intersection") then
			local Parts = {}
			for _, Part in Held:components() do
				table.insert(Parts, Frozen(Part, Depth + 1))
			end
			return if Held:is("union") then types.unionof(table.unpack(Parts)) else types.intersectionof(table.unpack(Parts))
		end
		if not Held:is("table") then
			return Held
		end

		local Out = types.newtable(nil, nil, Held:metatable())
		for Name, Field in Held:properties() do
			if Field.read ~= nil then
				Out:setreadproperty(Name, Frozen(Field.read, Depth + 1))
			end
		end
		local Indexer = Held:readindexer()
		if Indexer ~= nil then
			Out:setindexer(Indexer.index, Frozen(Indexer.result, Depth + 1))
		end
		return Out
	end

	if not Shape:is("table") then
		error(`a draft needs a table state, and this one is {tostring(Shape)}`)
	end

	local Draft = types.newtable(nil, nil, Shape:metatable())
	for Name, Field in Shape:properties() do
		if Field.read ~= nil then
			Draft:setproperty(Name, Frozen(Field.read, 1))
		end
	end
	local Indexer = Shape:readindexer()
	if Indexer ~= nil then
		Draft:setindexer(Indexer.index, Frozen(Indexer.result, 1))
	end
	local Gives = types.optional(Frozen(Shape, 0))

	local Out = types.newtable()
	for Kind, Held in Map:properties() do
		local Fields = Held.read
		if Fields == nil then
			continue
		end
		if not Fields:is("table") then
			error(`op kind '{tostring(Kind)}' has to name the fields it carries, as a table, and it names {tostring(Fields)}`)
		end

		local Arm = types.copy(Fields)
		for Name in Fields:properties() do
			Arm:setwriteproperty(Name, nil)
		end
		Arm:setreadproperty(types.singleton("Kind"), Kind)
		Arm:setreadproperty(types.singleton("Id"), types.string)
		Out:setreadproperty(Kind, types.newfunction({ head = { Draft, Arm } }, { head = { Gives } }))
	end
	return Out
end

export type function Opener(Parent: type): type
	local function Open(Held: type): type?
		if Held:is("union") then
			local Parts = {}
			for _, Part in Held:components() do
				local Opened = Open(Part)
				if Opened ~= nil then
					table.insert(Parts, Opened)
				elseif Part:is("nil") then
					table.insert(Parts, Part)
				else
					return nil
				end
			end
			return types.unionof(table.unpack(Parts))
		end
		if not Held:is("table") then
			return nil
		end

		local Out = types.newtable(nil, nil, Held:metatable())
		for Name, Inner in Held:properties() do
			if Inner.read ~= nil then
				Out:setproperty(Name, Inner.read)
			end
		end
		local Indexer = Held:readindexer()
		if Indexer ~= nil then
			Out:setindexer(Indexer.index, Indexer.result)
		end
		return Out
	end

	local Out = types.newtable()
	if not Parent:is("table") then
		return Out
	end
	for Name, Field in Parent:properties() do
		if Field.read ~= nil and Field.write ~= nil then
			local Opened = Open(Field.read)
			if Opened ~= nil then
				Out:setreadproperty(Name, Opened)
			end
		end
	end
	local Indexer = Parent:readindexer()
	if Indexer ~= nil then
		local Opened = Open(Indexer.result)
		if Opened ~= nil then
			Out:setindexer(Indexer.index, Opened)
		end
	end
	return Out
end

type Handler = (State: any, Op: any) -> any

local function Reducer<D, O>(Kinds: Handlers<D, O>): (State: D, Op: Op<O>) -> D?
	local Held: { [string]: Handler } = Kinds :: any

	return function(State: D, Given: Op<O>): D?
		local Handle = Held[(Given :: any).Kind]
		if Handle == nil then
			return nil
		end
		return Handle(table.clone(State :: any), Given)
	end
end

local function Open<T>(Parent: T): Opener<T>
	local Plain: { [any]: any } = Parent :: any

	return setmetatable({}, {
		__index = function(_, Key: any): any
			local Current = Plain[Key]
			if type(Current) ~= "table" or not table.isfrozen(Current) then
				return Current
			end
			local Inner = table.clone(Current)
			Plain[Key] = Inner
			return Inner
		end,
	}) :: any
end

return table.freeze({
	Reducer = Reducer,
	Open = Open,
})
```


# Apply and Commit (https://xoifaii.github.io/LedgerDocs/docs/concepts/apply-and-commit)



Both of them write an op. The difference is when you know the op is saved.

| | `Apply` | `Commit` |
| --- | --- | --- |
| Returns | `(boolean, Reason?)` | `Future<boolean, Reason?>` |
| Yields | no | yes, on `:Wait()` |
| Durable when it returns | no | yes |
| Costs a datastore request | no | yes |
| Sees other servers' writes | no | yes |

## Apply [#apply]

`Apply` runs your reducer against live state, updates it, tells observers, and queues the op. It
never touches the datastore. The op goes out on the next autosave, which runs every 30 seconds, or
on the next `Flush`, `Commit` or `Unload`.

```luau
local Ok, Why = Session:Apply("SpendGold", { Amount = 25 })
```

Use it by default, for whatever the player is doing right now. Spending, picking things up,
progression, stats.

The result is local. It knows what this server has, and not what another server appended a second
ago. Usually only one server writes to a player's key, so this rarely matters.

### When the result changes later [#when-the-result-changes-later]

`Apply` returns `true` straight away, and the op only reaches the log on the next save. If another
server wrote to that key in between, the fold can refuse your op when it is saved, after you
already told the player it worked.

This only happens when an op from each server passes the reducer's check alone, but not both
together. Two spends that together exceed the balance are the usual case:

```luau
-- 100 gold. server A spends 80, server B spends 30, neither knows about the other
A:Apply("SpendGold", { Amount = 80 })   -- A shows 20
B:Apply("SpendGold", { Amount = 30 })   -- B shows 70

-- both ops reach the log. A's is saved first, so B's would take the balance negative
-- and the reducer refuses it. B's player watches 70 become 20
```

Nothing is lost or double spent, and every server agrees once it settles. The player on B still saw a
number that was never true.

Render from state, not from the return value. The correction then arrives on its own through
[`Observe`](/docs/reference/observer). Use `Commit` where a wrong number for a moment is worse than
waiting.

## Commit [#commit]

`Commit` pushes everything queued, appends the op, waits for the datastore to take it, refolds from
what came back, and only then returns.

```luau
local Ok, Why = Session:Commit("GrantReward", { Item = "Sword" }):Wait()
if Ok then
	GiveTheSword()
end
```

Use it when you're about to do something you can't take back. Giving out a purchase, calling a
webhook, telling another service the thing happened. `true` means the op is in the log, your reducer
took it, and every server will agree from here on.

The fold runs against the real record, so `Commit` sees other servers' writes. A parked
[transaction](/docs/guides/transactions) leg on the key can still change the result afterwards. When
that is possible, `Commit` returns [`Unresolved`](/docs/concepts/reasons).

## CommitOp [#commitop]

`CommitOp` takes an op table you built yourself, so you can put a `Once` name on it or reuse an id
across a retry:

```luau
local Ok, Why = Session:CommitOp({
	Id = Ledger.Id(),
	Kind = "GrantReward",
	Item = "Sword",
	Once = `order:{OrderId}`,
}):Wait()
```

`Id` and `Kind` are required. `Once` is optional, and it makes the op apply at most one time on that
key. See [Once](/docs/concepts/once).

## Which one to use [#which-one-to-use]

Apply for gameplay, Commit for side effects.

If the player would not notice a rollback, use `Apply`. If a rollback would make the player report
a problem, use `Commit`.

## Flush [#flush]

`Session:Flush()` pushes queued ops without adding one. Autosave calls it. You rarely need it
yourself. Call it when the queued ops must be saved before your next step:

```luau
Session:Flush():Wait()
```

## Many ops, one request [#many-ops-one-request]

A flush writes the whole queue in one request. The number of ops does not change this. When one
action of a player must change more than one part of their data, queue each op with `Apply` and
flush once.

| call | requests |
| --- | --- |
| `Session:Apply` | none |
| `Session:Flush` | one, for the whole queue |
| `Session:Commit` | one, or two when ops are already queued |
| `Store:Edit` | one, and it takes one op |

```luau
Session:Apply("Coins", { Amount = 500 })
Session:Apply("Sword")
Session:Flush():Wait()
```

Two ops, and one request. Two `Commit` calls would cost two requests. Each `Commit` is saved before
it returns. A `Commit` also writes the queued ops first, if there are any.

The ops are saved in one request, but each op is folded on its own. If the reducer refuses one op,
the other ops stay applied. When a grant must be all or nothing, make it one op, and let its reducer
branch make every change. One op applies in full or not at all.


# Handling failures (https://xoifaii.github.io/LedgerDocs/docs/concepts/handling-failure)



Most code only cares about two things: did it work, and is it safe to retry.

```luau
local Ok, Why = Store:Edit(UserId, "GrantItem", { Item = "Sword" }):Wait()

if Ok then
	-- it applied, and a retry under the same id would return true again
elseif Why == Ledger.Reason.Unresolved or Why == Ledger.Reason.Busy then
	-- no result yet, retry later with the same id
else
	-- Refused, Spent, Closed, Backlog, Full, Invalid, Behind:
	-- it didn't apply, and a retry with this id won't change that
end
```

Reads return `(value?, Reason?)`, with the value first:

```luau
local State, Why = Store:Peek(UserId):Wait()
if State == nil then
	-- Why is the reason the read failed
	return
end
```

A key nobody has ever written folds to your `Default`, so a read never returns `nil` on success.
`nil` always means it failed.

## Why a retry is safe [#why-a-retry-is-safe]

Every op carries an id, and an id applies at most once while the key remembers it. A key remembers
an op id while the op is in the log. After compaction, it keeps the ids of the newest 2048 compacted
ops. A retry that already applied returns `true` and changes nothing the second time. A
[`Once`](/docs/concepts/once) name, a transfer id and a transaction id are remembered for 30 days
instead. Use one of those for anything that may be retried later than the key remembers it.

An op you send with your own `Id`, through `EditOp`, `CommitOp` or `Confirm`, can also carry
`IdAt`, the `os.time()` when you first sent the op. Send the same `IdAt` on every retry. When
the key has dropped the ids from that time, the retry returns
[`Unresolved`](/docs/concepts/reasons#unresolved) and applies nothing. Without `IdAt`, that retry
applies a second time.

The id has to be the same one. Build it before the call and keep it for the retry:

```luau
local OrderId = `order:{Receipt.PurchaseId}`

local Ok, Why = Store:Edit(UserId, "Grant", { ProductId = 123, Once = OrderId }):Wait()
if Why == Ledger.Reason.Unresolved then
	-- same OrderId, so DidApply can tell whether the first call applied
	Ok = Store:DidApply(UserId, OrderId):Wait() == true
end
```

Generate a new id on the retry and Ledger has nothing to match it against, so the retry applies a
second time.

## Unresolved [#unresolved]

Ledger doesn't know whether the write applied. `Unresolved` does not mean no. If you treat it as a
refusal and send the change again under a new id, it can apply twice.

**Retry with the same id.** See above. A retry under a new id is not safe.

**Ask instead of guessing.** [`Store:DidApply(Key, Name)`](/docs/reference/store#didapply) returns
whether a `Once` name applied. Compare it against `true`, because a failed read returns `nil`.

**In `ProcessReceipt`, return `NotProcessedYet`.** Roblox calls `ProcessReceipt` again, and the next
call gets a definite result. The full pattern is in [Once](/docs/concepts/once#processreceipt).

**For a parked leg, [`Store:Resettle(Key)`](/docs/reference/store#resettle) settles it now** instead
of waiting for the sweep. `true` means the key has nothing unfinished on it.

## Spent [#spent]

Nothing was applied. `Spent` looks like success and it isn't.

For a transfer the money is **back with the sender**. If you give out the item on `Spent`, the
sender gets the item and keeps the money.

`true` is the result that means "already happened". Call `Transfer` again with an id that delivered,
or `Tx` again with an id that committed, and it returns `true` and moves nothing.

So on `Spent`, decide what to do about an id you can't reuse. Read the keys, pick a new id, or tell
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
rejoin puts the player back on a server with the old build, so handle `Behind` with a teleport. See
[Rolling deploys](/docs/guides/migrations#rolling-deploys).

## Other reasons [#other-reasons]

| Reason | What to do |
| --- | --- |
| `Refused` | Your reducer returned `nil`. Tell the player. |
| `Busy` | Retry in a few seconds. See [Parked legs](/docs/guides/transactions#parked-legs). |
| `Closed` | The session is gone. Write before `Unload`, see [Shutting down](/docs/guides/sessions#shutting-down). |
| `Backlog` | Saves aren't going through. Stop writing and look at the datastore, see [Autosave](/docs/guides/sessions#autosave). |
| `Full` | Remove something first, see [Size](/docs/limits#size). |
| `Invalid` | A bug in the calling code. Ledger warns with the field, see [What you can store](/docs/concepts/the-fold#what-you-can-store). |


# Once (https://xoifaii.github.io/LedgerDocs/docs/concepts/once)



Every op Ledger writes already has an id, so a retry can't apply twice. But that id is generated
when the op is built. If your code crashes and builds the op again, the new op has a new id, and it
applies a second time.

`Once` fixes that. You give the op a name that comes from outside your game, and Ledger applies it
at most one time on that key.

```luau
Session:CommitOp({
	Id = Ledger.Id(),
	Kind = "ProductGrant",
	ProductId = 123456,
	Once = `receipt:{Receipt.PurchaseId}`,
}):Wait()
```

The name is remembered inside the profile, under `_Received`, so it survives a compaction, a rejoin,
and two servers processing the same receipt at once.

## ProcessReceipt [#processreceipt]

This is what `Once` was built for. Roblox keeps calling `ProcessReceipt` until you return
`PurchaseGranted`. There is no timer on it. A receipt you returned `NotProcessedYet` for comes back
when the player buys another developer product on this server, or when they join any server in the
experience again.

Roblox can also fail to record your return value after you returned `PurchaseGranted`, so it calls
again for a grant that already worked. Two servers can even run the same receipt at the same time
if the player joins the second one before the first returned.

<Callout type="warn">
  Assign `MarketplaceService.ProcessReceipt` as early as you can. Roblox acknowledges receipts on its
  own while no callback is assigned, and an acknowledged receipt can never be given back. Assign it
  first and let the callback yield for your store, instead of loading the store and then assigning.
</Callout>

So the grant has to happen at most once, and you still have to return `PurchaseGranted` on every
replay after that.

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

Notes on the example:

**`WaitForLoaded`, not `Get`.** The callback fires as the player joins, which can be before their
profile is loaded, and a `ProcessReceipt` callback is allowed to yield for as long as the server
runs. If you return `NotProcessedYet` because the session wasn't loaded, Roblox does not call again
until the player buys another product or rejoins.

**`DidApply`, not the Commit result.** `Commit` returns whether this call applied the op. Only the
first call does. Every replay returns `false`, but the purchase was still granted. `DidApply`
returns whether the name ever applied, which is what `ProcessReceipt` needs.

```luau
Store:Edit(UserId, "ProductGrant", { ProductId = 123, Once = "receipt:abc" }):Wait()
--> true, nil

Store:Edit(UserId, "ProductGrant", { ProductId = 123, Once = "receipt:abc" }):Wait()
--> false, "Refused"

Store:DidApply(UserId, "receipt:abc"):Wait()
--> true, nil
```

A replay returns `Refused`. When your reducer returns `nil`, the call also returns `Refused`, so the
boolean cannot tell you which one happened. `DidApply` can.

**Check `Unresolved` first.** It means there is no settled result yet, so `DidApply` might read a
fold that a parked transaction can still change. Return `NotProcessedYet`, and the next call checks
again.

<Callout type="warn">
  Never return `PurchaseGranted` for something you aren't sure applied. An unresolved purchase
  is never refunded, so the player loses the Robux and gets nothing.
</Callout>

## Other ids to name an op with [#other-ids-to-name-an-op-with]

A receipt is one id `Once` can use. Any id that comes from outside the call works the same way: a
support tool order, a webhook delivery, a gamepass unlock.

### Gamepasses [#gamepasses]

A gamepass has no `ProcessReceipt` and no receipt id. Roblox stores whether the player owns the pass,
so you don't have to. You store what the pass gave them.

`UserOwnsGamePassAsync` returns whether they own it. Two things about it need care.

<Callout type="warn">
  `UserOwnsGamePassAsync` throws when the request fails, and it fails often under load. Wrap it in a
  `pcall`. Never turn a thrown call into `false`. `false` means "does not own it", so you would take
  the pass away from a player who paid for it.
</Callout>

Roblox caches the result per player, per pass, per server. A purchase made in your experience updates
that cache when `PromptGamePassPurchaseFinished` fires, so you don't have to track it yourself. A
purchase made outside the experience takes several minutes to reach the cache.

So `OwnsPass` only has to add a third result, `nil`, for a failed check:

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

With a reducer check like that one, you do not need the `Once` name. Keep `Once` for a grant your
reducer can't check, like a one off currency top up. There the name is the only thing that stops a
second grant.

### Granting to a player who is not on this server [#granting-to-a-player-who-is-not-on-this-server]

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

`Session:DidApply(Name)` and `Store:DidApply(Key, Name)` both return whether a `Once` name ever
applied on that key. The session version reads live state, returns a plain `boolean`, and can't
fail. The store version reads the record and returns a `Future<boolean?, Reason?>`.

<Callout type="warn">
  `Store:DidApply` returns `nil` when it couldn't read the record at all, which is not the same as
  `false`. Compare against `true`, not truthiness, or a failed read looks like "never granted" and
  you give out the reward a second time.
</Callout>

`DidApply` checks the name, not this call, so it returns `true` on every replay.

<Callout type="warn">
  A name lives on one key of one store. Ask `DidApply` on the store that the name was written to.

  A handler can grant on a profile store and record the sale on a second store. It then needs one
  name for each store. Check each name on its own store.

  If you ask the profile store about a name on the record store, the result is always `false`. The
  write returns `Refused` because it is a replay, and the check returns `false`. The callback never
  returns `PurchaseGranted`, so Roblox retries the receipt forever.
</Callout>

`Session:DidApply` reads live state, and live state includes the ops that wait for the next save.
After `Apply`, `Session:DidApply` returns `true` before the op is saved. On a receipt, grant with
`Commit`, or `Apply` and then `Flush`. A `true` then means a saved grant.

## How long a name is remembered [#how-long-a-name-is-remembered]

30 to 31 days. Ledger groups names by the day they were applied. The next time any name is written
to that key, Ledger removes each day older than 30 days, so the set does not grow forever.

The check for an already applied name runs before that removal, against every name still in the
set. Names are only removed when a new name is written. So if a player is away for two months and
Roblox retries an old receipt when they return, the name is still in the set and the retry is
refused.

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

It does not cover a receipt that is still unsettled after 30 days while the same player buys other
things. That only happens if your grant fails every time for a month, which is a bigger problem
than the dedupe.

<Callout type="warn">
  So `Once` is for retry windows, not for names that stay meaningful forever. A support ticket
  reopened two months later, or an unlock you want to be permanent, is outside the window. 
  Put that rule in the reducer instead.
</Callout>

The [gamepass example](#gamepasses) above uses both. `pass:{PassId}` stops the retries. The
reducer refusing on `State.Passes[Op.Pass]` is what stops a second grant a year later.

## Rules [#rules]

The name has to be a non empty string. Any other value returns [`Invalid`](/docs/concepts/reasons)
from every method, and nothing applies. `Once = nil` is the same as leaving `Once` out: the op
applies with no name, so a retry can apply it again. A name usually comes from outside your game, so
check that the receipt id is there before you write.

Names are namespaced, so a `Once` name can't collide with a transfer id or a transaction id even if
they're spelled the same.

Your reducer never has to dedupe. Before your reducer runs, Ledger refuses an op whose `Once` name
has already applied, so the op applies once. Your reducer still runs on every fold of the log, so
keep the branch pure.

Don't put `Once` on a [transaction](/docs/guides/transactions) leg. The transaction id already makes
every leg apply at most once, and Ledger throws if you pass one anyway.


# Reasons (https://xoifaii.github.io/LedgerDocs/docs/concepts/reasons)



Anything that can fail tells you why. Writes return `(boolean, Reason?)` and reads return
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

Your reducer returned `nil`. The op was valid, but your rule rejected it, for example because the
player couldn't afford it or already owns it. This is the only reason that came from your own code,
and it's the only one that's a normal part of gameplay.

Nothing changed. Don't retry it, the result won't be different.

## Busy [#busy]

Someone else is in the middle of a transaction on that key and it hasn't finished yet. Nothing
changed.

Ledger puts the key on the [recovery sweep](/docs/guides/recovery#sweeping), which runs every 60
seconds. Your own retry usually settles it sooner, because every read and write settles what it
finds pending on the key before doing anything else. Retry in a few seconds.

`Session:Apply` also returns this when the key has hit its 1.5 MB op cap and a parked transaction is
stopping it compacting. The datastore is fine. Retry once the transaction settles.

A write to a key also returns `Busy` while a second `Erase` takes that key off the datastore. This
lasts at most two minutes. See [Erase](/docs/guides/recovery#erase).

`Tx` does not retry a `Busy` for you. Every server retrying at once would add more load to a key
that is already contended, so your own code has to retry, with a longer wait each time. See
[One key at a time](/docs/limits#one-key-at-a-time).

## Spent [#spent]

That id is used up and nothing was applied.

For a transfer it means the money went **back to the sender**. The money stayed set aside until the
transfer expired, and Ledger refunded it. Ledger keeps the id afterwards, so a late retry with that
id cannot send the money again.

For a transaction it means the id can't be used for what you asked. Either that id already ran for
a different set of keys or a different amount, or an earlier attempt was cancelled part way. Ledger
refuses it instead of applying part of it. A transfer does the same: a retry under an id that
already applied, for a different amount or a different key, returns `Spent` instead of `true`.

`Spent` means this attempt changed nothing. It does not mean the id can never work again. An id
whose transaction was cancelled before any leg applied is free to use, so a retry can finish a
cancelled attempt. An id that already moved money cannot be used again.

<Callout type="warn">
  `Spent` is not success. Nothing moved, and for a transfer the money is back where it started. See
  [Spent](/docs/concepts/handling-failure#spent).
</Callout>

## Held [#held]

A transfer took the money and could not deliver it, because the receiving key was erased. This is
not "nothing happened". The amount has left the sender and is set aside with them.

Ledger gives it back on its own, and the recovery sweep keeps checking that key until it has. Tell
the sender their money is coming back rather than that the transfer failed. Don't send it again
under a new id, or they pay twice.

A [reservation](/docs/guides/reservations) never returns `Held`. A hold lives in MemoryStore and
takes nothing off the key, so there is nothing to be set aside.

## Unresolved [#unresolved]

Ledger doesn't know. Either the datastore call failed in a way that might still have written, or a
transaction leg is parked on the key and the fold can change once it settles.

`Session:Apply` returns this when a transaction is parked on the key and your reducer accepts the op
only if that transaction commits, or only if it does not. Ledger folds the state both ways, and
accepts the op only when both results agree. Retry once the transaction settles.

`Session:Commit` and `Store:Edit` return this when the op was written but a transaction still parked
on the key could change whether it applies. With two or more transactions parked, they always
return it. Read the key once the transactions settle.

A retry of an op with your own `Id` returns this when its `IdAt` is older than the ids the key still
keeps. The key may have applied that id and then dropped it, so nothing is applied. Read the key
before you send the op again. See
[Why a retry is safe](/docs/concepts/handling-failure#why-a-retry-is-safe).

`Unresolved` does not mean no, and it is the one that costs money if you treat it as a refusal. See
[Unresolved](/docs/concepts/handling-failure#unresolved).

## Closed [#closed]

The session is gone. The player left and the session was released, or the store was destroyed.
Anything you write to it now is lost.

## Backlog [#backlog]

Ops are piling up because saves aren't going through. Either 4096 ops are queued or they've hit the
1.5 MB cap on unsaved bytes. This usually only happens when the datastore is down.

Nothing changed. This is a signal to stop writing and look at what's wrong, not to retry more often.

## Full [#full]

The profile is at the 2 MB cap and the op would make it bigger. Ledger still accepts ops that make
it smaller, so a cleanup still works.

`Store:Edit` returns this when the key already carries 1.5 MB of ops that have not been compacted.
That happens when a parked transaction is stopping the key compacting. It clears once the
transaction settles.

`Store:Edit` and `Session:Commit` compact a full log once and try again before they return `Full`.

Nothing changed. You need to remove something before you can add anything.

## Invalid [#invalid]

The op can't be stored. Something in the fields isn't JSON, such as an Instance, a function, a
cyclic table, a table mixing array and dictionary keys, NaN or inf. Or the fields use a name Ledger
reserves, or the kind starts with `__`. Or your reducer returned something that wasn't a table.

`Edit`, `Apply`, `Commit` and `Tx` all return this the same way. For `Tx` it means one of the legs
is invalid, and nothing was prepared on any key.

Nothing changed. This is a bug in the calling code, and Ledger warns with the specific field.

## Behind [#behind]

A newer server wrote that record and this one can't read it. Either the stored format is newer than
this server's build, or the record needs a migration this build doesn't have.

Nothing changed, and retrying is pointless. `Behind` is caused by the version of your game this
server is running, not by the datastore. It clears when the deploy finishes and
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

The reducer takes the state and one op, and returns the next state or `nil` to refuse. It's the
only place in your game that decides whether a change is allowed.

```luau
export type Ops = {
	SpendGold: { Amount: number },
}

local function Reducer(State: Profile, Op: Ledger.Op<Ops>): Profile?
	if Op.Kind == "SpendGold" then
		if Op.Amount <= 0 or Op.Amount > State.Gold then
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

The same `(State, Op)` has to give the same result on every server, forever. No `os.time()`, no
`math.random()`, no `game`, no upvalues that change, no reading someone else's data. If you need the
time or a dice roll, work it out at the call site and put it on the op:

```luau
Session:Apply("DailyBonus", { At = os.time(), Roll = math.random(1, 6) })
```

A log gets folded on two servers at two different moments. If the reducer reads the clock, those two
folds disagree, and different servers hold different data with no error.

<Callout type="warn">
  In Studio, Ledger refolds the log after every commit and compares it against live state. If they
  don't match it warns and names the field that changed. That check doesn't run in production, so
  fix the field it names before you ship.
</Callout>

## It must not mutate the state [#it-must-not-mutate-the-state]

Return a new table. `table.clone` is shallow, so clone each nested table you touch:

```luau
local Next = table.clone(State)
Next.Gamepasses = table.clone(State.Gamepasses)
Next.Gamepasses[Pass] = true
return Next
```

The state you are given is deep frozen, so a mutation throws on the line that did it instead of
corrupting a fold somewhere later.

Cloning by hand gets hard to read a few levels down. [Advanced
reducers](/docs/concepts/advanced-reducers#changing-nested-state) has an `Open` that copies only
the tables you change.

Freezing can't cover a buffer, because Luau has no way to freeze one. State can hold buffers, and
Ledger copies them instead of sharing them, so writing into one can't reach another server or another
session. It does still change the state you're holding, and a later fold of the same log gives a
different result. Build a new buffer instead of writing into the one you were given.

A buffer in `Default` works, and each key gets its own copy. Ledger used to give every key that had
not stored one yet the same buffer, so one key writing into it changed what all of them read.

Don't freeze what you return. Ledger freezes it for you, all the way down. Ledger only skips the
tables it froze itself. It checks every table inside a table you froze, which costs more than
letting Ledger do the freezing.

## It must not yield [#it-must-not-yield]

No `task.wait`, no `:Wait()`, no yielding datastore calls. Ledger runs the reducer inside a guard
that errors if it yields.

## It has to return a table or nil [#it-has-to-return-a-table-or-nil]

Anything else is a bug. Ledger refuses the op with [`Invalid`](/docs/concepts/reasons) and warns.

## Leave the reserved fields alone [#leave-the-reserved-fields-alone]

`table.clone(State)` carries `_Received` and `_Held` across, so most reducers never need to handle
them.

If you build the next state from scratch and drop them, Ledger puts them back, so you can't lose the
applied names that way. It does not always detect your own values written into them. A store with a
`Balance` overwrites those, but a store without one keeps a hand built `_Received`, and that breaks
the dedupe.

So don't drop them, and don't write to them. You can read them. They are plain data.

## Ops you don't know [#ops-you-dont-know]

Return `nil` for anything you don't recognise. Ledger treats that as a refusal. An old server that
has never heard of `NewFeatureOp` refuses it instead of guessing at it. This does not make every new
kind safe during a rolling deploy. A new kind that changes a field that other kinds read needs a
migration. See [changing the reducer](/docs/guides/migrations#changing-the-reducer).

Ledger checks this when the store is built. It calls the reducer with an op of a kind your game
never uses. A reducer that returns a state for it gets a warning at `New`. Every unknown op on that
store counts as applied until the reducer is fixed.

That covers a kind you don't know yet. A kind you have deleted is different. No build will ever
accept it, and refusing one of those stops the key compacting permanently. See [changing the
reducer](/docs/guides/migrations#changing-the-reducer).

## What Studio checks at every save [#what-studio-checks-at-every-save]

In Studio, Ledger checks the folded state of a session at every save. State a datastore cannot
hold gets a warning that names the field. An array with a gap, a table that mixes array and string
keys, and a `nan` are the usual causes. A table keyed by `UserId` is an array with gaps. Key it by
`tostring(UserId)` instead.

Live servers skip the check. A key in that state keeps taking writes and stops compacting, and
Ledger warns each time it tries to compact the key.

## Check the fields [#check-the-fields]

With your ops named, every write your game makes is checked against `Ops`, so the reducer can read
`Op.Amount` as a number. See [Typed ops](/docs/concepts/typed-ops).

That check is a type check, so it only covers the code you write. Ops read back from the datastore
are not checked again. An op that an older version of your game wrote before a field changed type
reaches the reducer with the old type. Maths or a comparison on the wrong type throws, and Ledger
refuses an op whose reducer throws. A field you only store, like an item name, goes into the state
as it is. If an older version wrote that kind with a different type, keep a `type()` check on that
field.

A store built without `Ops` gives the reducer `Ledger.Op`, where every field is `unknown`. Check the
type of each field before you use it.

## Coming from Rodux or Redux [#coming-from-rodux-or-redux]

The shape is similar. An op is an action, `Op.Kind` is `action.type`, and a handler table keyed by
kind is easier to read than a long `if` chain.

Two Redux conventions are reversed in Ledger. Getting either one wrong can lose a purchase, and
nothing raises an error.

### nil means refused, not unhandled [#nil-means-refused-not-unhandled]

In Redux the default case returns the state unchanged, and returning nothing is an error. Here it's
the other way round. Ledger reads any table you return as accepted, including the exact state you
were given. Returning `nil` is the only way to refuse.

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
written into the applied names as soon as your reducer returns a table, so the receipt is marked
granted while nothing was granted. `DidApply` returns `true`, Roblox stops retrying, and the player
paid Robux for nothing. A transaction leg is also marked as committed on that key, although nothing
changed.

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

In Lua, a slice that returns `nil` also assigns `nil` into the combined table, which deletes that
key. So the refusal is lost, and the field is deleted as well.

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

### What Ledger does instead of the rest of Rodux [#what-ledger-does-instead-of-the-rest-of-rodux]

Don't build a `Rodux.Store`. Ledger is the store, state lives in the log, and `Session:Observe()` is
your subscribe. If two stores hold the same data, they get out of sync.

No middleware and no thunks. The reducer can't yield, so anything async happens before you call
`Apply` or `Commit`, and you put its result on the op.

Ledger has no built in Immer style drafts. State is deep frozen, so mutating it throws on the line
that did it. Clone what you change, or copy the `Drafts` module from
[Advanced reducers](/docs/concepts/advanced-reducers#changing-nested-state).

One convention does carry over cleanly. Redux asks you to keep actions serializable by convention.
Ledger enforces it, because ops go in a datastore, and an op that isn't JSON is refused with
[`Invalid`](/docs/concepts/reasons) instead of failing at save time.

## Balance and transactions [#balance-and-transactions]

If the store names a `Balance` field, Ledger wraps your reducer with the transfer ops
(`__TransferReserve`, `__TransferDeliver` and the rest). Your reducer never receives those kinds, so
they never reach your `if` chain. The same is true for the ops that transaction bookkeeping and
`Store:Reset` write.


# The fold (https://xoifaii.github.io/LedgerDocs/docs/concepts/the-fold)



Every key Ledger owns holds a record, not a state table. A record is a snapshot plus the ops that
have been appended since that snapshot was taken.

```luau
State = fold(Snapshot, Ops)
```

Reading a key means loading the record and replaying its ops through your reducer. Writing a key
means appending one op. Nothing ever overwrites state.

## Why there is no lock [#why-there-is-no-lock]

Two servers appending to the same key isn't a conflict, because neither append overwrites the other.
Both ops end up in the log, the datastore settles what order they're in, and every server that folds
that log later walks them in that same order and gets the same state.

This replaces the session lock. A lock stops the second writer. A fold takes both writes and decides
afterwards, the same way on every server.

<Callout type="info">
  The datastore settles the order once, at the moment of the append. It isn't decided per server and
  it doesn't depend on anyone's clock.
</Callout>

## Refusing an op [#refusing-an-op]

Your reducer returns `nil` to refuse an op. The op is still in the log, but it has no effect on the
state. So when two servers both try to spend the same last 100 gold:

1. Server A appends `SpendGold{100}`, server B appends `SpendGold{100}`.
2. The log holds both of them, in whatever order the datastore settled on.
3. Every fold applies the first and refuses the second, because by then the balance is 0.

Both servers see the same thing. The player spent 100 gold once.

## Compaction [#compaction]

A log that only ever grows would eventually hit the 4 MB value limit. Once a log has many ops or
many bytes, Ledger folds it into a new snapshot and removes the ops it compacted. Autosave does this
on its own, and `Session:Compact()` forces it.

Compaction keeps the ids of the compacted ops on the record, under `Seen`, so a retry that arrives
afterwards applies nothing. `Seen` is not part of the state, so your reducer never sees it. `Seen`
keeps the newest 2048 ids, and records when it compacted them. An op whose `IdAt` is older than the
ids `Seen` still keeps returns [`Unresolved`](/docs/concepts/reasons#unresolved) and applies
nothing. A [`Once`](/docs/concepts/once) name, a transfer id and a transaction id live inside the
state, under `_Received`, for 30 days.

## Reserved fields [#reserved-fields]

Ledger keeps its own bookkeeping in the state table, under keys starting with an underscore.

`_Received` holds the applied names, namespaced so a transfer id, a transaction id and a
[Once](/docs/concepts/once) name can't collide. `_Held` holds money set aside by a
[transfer](/docs/guides/transfers) that hasn't finished yet.

`Ledger.New` throws if your `Default` declares any key starting with `_`. Your reducer will see both
fields on `State`, and `table.clone` carries them across without you doing anything. Drop them by
accident and Ledger puts them back. Write your own values into them and you can break the dedupe.

## What you can store [#what-you-can-store]

Anything a datastore can store as JSON: tables, strings, numbers and booleans. No Instances, no
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



An op is a kind plus the fields you pass with it. Write down which kinds your game uses and which
fields each one carries, give that list to `Ledger.New`, and every write is checked against it. A
misspelled kind or a field of the wrong type is a type error where you wrote it, not a refusal you
find at runtime.

## Declaring your ops [#declaring-your-ops]

`Ops` maps each kind to the fields it carries:

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

local Store = Ledger.New<<Profile, Ops>>({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {} },
	Reducer = Reducer,
})
```

A kind with no fields takes an empty table:

```luau
export type Ops = {
	Prestige: {},
}

Session:Apply("Prestige", {})
```

## What gets checked [#what-gets-checked]

Every write that names a kind:

```luau
Session:Apply("Buy", { Item = "Sword" }) -- fine
Session:Apply("Byu", { Item = "Sword" }) -- no kind by that name
Session:Apply("Buy", { Item = 42 })      -- Item has to be a string
Session:Apply("Buy", { Amount = 5 })     -- those are AddGold's fields
```

The error lists every kind the store has, with its fields. `Commit`, `Edit`, `Confirm`, `CommitOp`
and `EditOp` are checked the same way.

Extra fields are allowed when every declared field is present. That is how `Once` sits beside your
own fields:

```luau
Session:Apply("Buy", { Item = "Sword", Once = "order1" })
```

`IdAt` sits there the same way on `Confirm`, `CommitOp` and `EditOp`. On `Apply`, `Commit` and
`Edit` the check lets it through, and Ledger drops it with a warning, since those calls make a new
id every time.

So a misspelled field is caught only because the correctly spelled field is then missing. The
misspelled field itself is allowed as an extra.

The field names you pass to `Reserve`, `Holds`, `Transfer`, `Bump` and `Total` are checked too.
They have to name a number field of your state:

```luau
Store:Reserve(UserId, "Gold", 1, "order1") -- fine
Store:Reserve(UserId, "Glod", 1, "order1") -- no field by that name
Store:Reserve(UserId, "Items", 1, "order1") -- Items isn't a number
```

## In the reducer [#in-the-reducer]

Type the op as `Ledger.Op<Ops>`. Testing `Op.Kind` narrows it to that kind, and its fields have
their types:

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

`Op.Item` is a string and `Op.Amount` is a number, with no `type()` checks and no casts. These are
type errors:

```luau
if Op.Kind == "Buy" then
	print(Op.Amount) -- Key 'Amount' not found in table '{ read Id: string, read Item: string, read Kind: "Buy" }'
	Op.Item = "Shield" -- Property Item of table '{ read Id: string, read Item: string, read Kind: "Buy" }' is read-only
end
```

Annotate the reducer's return as `Profile?`, as above, and it has to return your state or `nil`. A
reducer written inline in the config, with no return annotation, is not checked for that.

The state you are given is frozen. Writing into it throws at runtime, and the op is
[`Refused`](/docs/concepts/reasons). Annotate the state as `Ledger.Frozen<Profile>` to make that a
type error too:

```luau
Reducer = function(State: Ledger.Frozen<Profile>, Op)
	if Op.Kind == "AddGold" then
		State.Gold += Op.Amount -- Property Gold of table '{ read Gold: number, read Items: { [string]: boolean } }' is read-only
	end
	return nil
end,
```

Arrays and maps stay writable in the type, because Luau can't mark a table's entries read only yet.
A write into one still throws at runtime.

For a reducer with deep state or many kinds, [Advanced reducers](/docs/concepts/advanced-reducers)
has a table of handlers, one per kind, and an `Open` that makes nested state writable.

Fields an older version of your game wrote are not checked again when they are read back. See
[check the fields](/docs/concepts/reducer#check-the-fields).

## A store without types [#a-store-without-types]

`Ledger.New(Options)`, without `<<Profile, Ops>>`, builds a store that takes any kind with any
fields. The reducer gets `Ledger.Op`, where every field is `unknown`, so it has to check each field's
type before it uses it. That suits a store whose ops are still changing.

Adding the types later changes no call site, since both take the kind and the fields as two
arguments. Nothing changes at runtime either.

## Naming the store and session types [#naming-the-store-and-session-types]

`Ledger.TypedStore<Profile, Ops>` and `Ledger.TypedSession<Profile, Ops>` are the types of a typed
store and its sessions, the way `Ledger.Store<Profile>` and `Ledger.Session<Profile>` are for a store
without types:

```luau
local function Buy(Session: Ledger.TypedSession<Profile, Ops>, Item: string)
	return Session:Apply("Buy", { Item = Item })
end
```

See [Types](/docs/reference/types).


# Entity stores (https://xoifaii.github.io/LedgerDocs/docs/guides/entity-stores)



A store with `Keys = "String"` isn't about players. The keys are names you pick, like a clan id, and
the data under a key belongs to no single player.

```luau
export type Clan = {
	Members: { [string]: true },
	Count: number,
	Treasury: number,
	Level: number,
}

export type Ops = {
	Join: { UserId: string },
	Donate: { Amount: number },
}

local MAX_MEMBERS = 50

local Clans = Ledger.New<<Clan, Ops>>({
	Name = "Clans",
	Keys = "String",
	Default = { Members = {}, Count = 0, Treasury = 0, Level = 1 },
	Balance = "Treasury",
	Reducer = function(State, Op)
		if Op.Kind == "Join" then
			if State.Members[Op.UserId] or State.Count >= MAX_MEMBERS then
				return nil
			end

			local Next = table.clone(State)
			Next.Members = table.clone(State.Members)
			Next.Members[Op.UserId] = true
			Next.Count += 1
			return Next
		end

		if Op.Kind == "Donate" then
			if Op.Amount <= 0 then
				return nil
			end

			local Next = table.clone(State)
			Next.Treasury += Op.Amount
			return Next
		end

		return nil
	end,
})
```

Two things in there are easy to get wrong.

**`UserId` is a string.** A table keyed only by numbers is an array. A UserId is a huge number, so
`Members` keyed by it would be an array with millions of gaps, and a datastore cannot store that.
Each op succeeds on its own, so the writes keep working, but the key can no longer compact and the
log grows forever. `UserId: string` in `Ops` makes passing a number a type error, so call
`tostring(Player.UserId)`.

**`State.Count`, not `#State.Members`.** `#` gives `0` on a dictionary, so the cap would never apply.
Keep the count in the state and change it with the members.

Entity stores have no lock either. Twenty servers can write to the same clan at once, and each one
applies the membership cap the same way when it replays the log. There's no owner server, no lease,
and nothing to recover if a server dies during a write.

## Reading and writing [#reading-and-writing]

There are no sessions, because nobody is logged in to a clan. You write with `Edit` and read with
`Peek`:

```luau
local Ok, Why = Clans:Edit("cool-guys", "Join", { UserId = tostring(Player.UserId) }):Wait()
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
all throw on a string keyed store, because a session belongs to a player.

## Keys [#keys]

A key is a string of 1 to 50 characters and it has to be valid UTF-8. Roblox sets that limit, so
Ledger can't raise it.

A key cannot hold a `#`. Ledger puts a `#` between a total's name and its shard number, so a key
with one could be read as a shard of something else. A key with a `#` in it throws an error at the
call.

Pick keys that come from something stable. A clan id, a listing id, a slug. Don't build them out of
anything that might change, because there's no rename.

## Transfer and Tx limits on one key [#transfer-and-tx-limits-on-one-key]

A clan or a listing takes writes from every player at once. Ledger records the name of every `Tx`
leg and every `Transfer` that goes through, and keeps each name for 30 days. One key can take about
1,900 of these a day before the names fill the state cap. A transfer into or out of a full key then
returns `Full`, and the money stays where it was.

`Edit` and `Reserve` record no name, so a clan that only receives those is not affected. `Confirm`
records one only when you give it a [`Once`](/docs/concepts/once).

Above that rate, split the data over more keys, for example one key per guild instead of one key for
all guilds. See [Limits](/docs/limits#applied-names).

## Following a key [#following-a-key]

`Peek` with no `MaxAge` reads the record on each call. Do not call it in a loop or every frame.
Follow a key that every server needs, such as a settings table, a role list or a feature switch:

```luau
Settings:Follow("config"):Subscribe(function(Config)
	Apply(Config)
end)
```

One shared copy of the key is in MemoryStore for the whole fleet. Each server reads the shared copy
on a timer, and the subscription fires only when the state changed. After 60 to 75 seconds the
shared copy is stale. One server then reads the record and writes the shared copy again. The other
servers return the old copy until then. A change on any server reaches every server within 75
seconds plus one tick. A fleet of 5,000 servers costs the key one datastore read a minute, not 5,000.
`Peek(Key, MaxAge)` reads the same copy without a subscription.

Follow a key at server start, and do not peek it there. `Follow` makes its first read at a random
point in its first tick, and `Peek` reads at once. So when 5,000 servers start together and each
follows the key, they do not all read the shared copy in the same second.

A followed key holds small state that changes slowly. The copy has to fit one MemoryStore item,
32 KB. The copy carries your fields only. Keep anything that grows with players in one key per
entry. Let the followed key point at those keys. A ban is one key per banned player. A log is one
key per line. Do not follow those keys.

To show a write on every server immediately, send the key over `MessagingService` from
`Store:Stale()`. The receiver calls `Peek(Key, 0)`, which reads the record and refills the shared
copy for the other servers. Wait a random few seconds before that call, so the servers don't all
read at the same moment and one refill serves every server. See
[Telling another server to refresh](/docs/guides/transactions#telling-another-server-to-refresh).

A store with no MemoryStore reads the record on each tick. When MemoryStore stops responding, each
server keeps its copy for 10 minutes. A server with no copy reads the record once in those
10 minutes. No server waits for another server at any point.

## Player and entity stores in one transaction [#player-and-entity-stores-in-one-transaction]

A transaction can touch a player store and an entity store in the same commit, which is the usual
reason to have both:

```luau
Players:Tx(`donate:{OrderId}`, {
	{ UserId = Player.UserId, Kind = "SpendGold", Fields = { Amount = 500 } },
	{ Store = Clans, Key = "cool-guys", Kind = "Donate", Fields = { Amount = 500 } },
}):Wait()
```

Both sides move or neither does. A leg's kind and fields are not checked against `Ops`, so a leg
can name a kind on any store. See [Transactions](/docs/guides/transactions).


# Migrations (https://xoifaii.github.io/LedgerDocs/docs/guides/migrations)



A migration is a function that takes the old state and returns the new one. Add new ones to the end
of the list and never change the ones already there.

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

The number of migrations in the list is the version. A record stores the version it was written at.
When a server loads a record with a lower version, it runs the missing steps in order before the
fold.

Migrations run on the snapshot at load. They never see ops.

## New fields don't need one [#new-fields-dont-need-one]

On every load Ledger adds each field of `Default` that the stored state is missing. A field you
add to `Default` appears on old profiles with its default value. You only need a migration to change
a field that already exists, such as renaming or reshaping it.

## Rolling deploys [#rolling-deploys]

During a deploy, old servers and new servers run at the same time on the same data.

New servers write records with the new version. An old server that reads one refuses to fold it.
Otherwise it would fold a record it doesn't understand and write it back with the new fields removed.

`Compatible = true` marks a step that only adds things. An old server can read a record at that
version, ignore the fields it doesn't know, and write it back without losing anything.

The floor is the version of the last step that isn't compatible. A server whose build has at least
that many migrations can read the record. An older one returns
[`Behind`](/docs/concepts/reasons).

```luau
-- new build, two migrations, the first of them not compatible
Version = 2, Floor = 1

-- old build with one migration reads it
Store:Peek(UserId):Wait()   --> nil, "Behind"
Store:Reset(UserId):Wait()  --> false, "Behind"
```

The first write to a key stores `Default` as its snapshot along with the version and the floor.
Every later write raises the floor to the writer's floor, so a key turns an old server away from
the first write a new server makes:

```luau
Store:Edit(UserId, "Add", { Amount = 5 }):Wait()   --> false, "Behind"
```

The floor is checked inside the datastore update, before the op reaches the log, so nothing is
written. `Behind` stops once the deploy finishes.

An older server never compacts one of these records, so it never writes a snapshot in the old shape.

Don't retry `Behind`. It isn't a datastore failure. It means this server runs an older build than
the one that wrote the record, and it stops once the deploy finishes. Never fall back to a fresh
profile on `Behind`. The stored data is fine, and writing over it loses it.

In short:

- Adding a field, a table or a default: mark it `Compatible = true`, and old servers keep working
  through the deploy.
- Renaming, deleting or reshaping a field: leave it unmarked. Old servers refuse those records with
  `Behind` until the deploy finishes.

## Don't drop something Default still declares [#dont-drop-something-default-still-declares]

If a migration removes a field but `Default` still lists it, the load puts it back with its default
value and the migration has no effect. Nothing warns about this, because Ledger can't tell a field
you meant to drop from one you meant to keep.

Remove the field from `Default` in the same change as the migration.

## Rules [#rules]

Migrations have to be pure and can't yield, like the reducer.

They have to return a table. Anything else throws an error at load that names the step.

Don't change fields that start with an underscore. They are Ledger's own: the money set aside for
a transfer, the applied names, and the totals `Bump` keeps. A migration that builds a new table drops
them, so Ledger puts them back after every step and warns with the step number. Copy the state and
change only what you meant to:

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

Never reorder, delete or edit a migration that has shipped. The list index is the version, so
changing the list changes what every stored version means.

Versions only go up. A server reads a record with a newer version only when the floor allows it,
and refuses it otherwise. It never migrates a record down.

## Changing the reducer [#changing-the-reducer]

The reducer has no version. A migration changes the snapshot, not the ops. Each server folds the log
with the reducer it runs now, so changing the reducer changes what older ops do.

Add a new kind for a new rule. You can widen a kind to accept ops it refused before. Don't narrow
a kind, don't change what it does, and never reuse a kind name.

Keep the branch for a kind after its feature is removed. Every record whose log still holds one of
its ops needs it to fold. Keep it correct through later migrations too:

```luau
-- pets were taken out of the game. the ops are still in the logs, so the rule stays
if Op.Kind == "BuyPet" then
	if Op.Cost > State.Gold then
		return nil
	end

	local Next = table.clone(State)
	Next.Gold -= Op.Cost
	Next.Pets = table.clone(State.Pets)
	Next.Pets[Op.PetId] = true
	return Next
end
```

If you delete it, the fold leaves out that gold and that pet. The key stops compacting, with a warning
that names the kind, and the log grows until writes return [`Full`](/docs/concepts/reasons). Putting
the branch back restores both.

`Reset` doesn't fix that. It writes the default state as another op, so the op that can't be applied
is still the oldest one and the log still can't compact. `Reset` warns about this. Only a build that
folds the op, or erasing the key, clears it.

Don't replace it with a branch that accepts the op and changes nothing. The state loses the same
gold and pet, but this time the key compacts, so the snapshot saves that result permanently:

```luau
-- wrong. the fold drops what the op did, and a compaction saves that permanently
if Op.Kind == "BuyPet" then
	return table.clone(State)
end
```

Only a loaded session compacts, and only when the log is long enough. An offline key keeps its ops
until you deploy a build that folds them.

A change to the reducer doesn't raise the floor, because Ledger can't detect it. During the deploy,
two builds fold one log with different rules. When that isn't safe, add an unmarked migration that
returns the state unchanged. It raises the floor, so old servers stop writing to the key:

```luau
Migrations = {
	-- ...
	function(State) return State end,  -- 3: SpendGold now checks a daily cap
}
```

A new kind isn't always safe either. An old server refuses the new op and folds the key without it.
If the new op changes a field that another kind reads, the old server can write an op that the new
build refuses. For example, a new `Tax` op takes gold. An old server then writes a `SpendGold` op
against gold the tax already took, and tells the game it went through. The new build refuses it, so
it never applies, and the key can't compact again. When a new kind changes a field that other kinds
read, add the same kind of migration:

```luau
Migrations = {
	-- ...
	function(State) return State end,  -- 4: Tax takes gold, and SpendGold reads gold
}
```

An old server then gets [`Behind`](/docs/concepts/reasons).


# Recovery (https://xoifaii.github.io/LedgerDocs/docs/guides/recovery)



## History [#history]

Roblox keeps a version for the first write to a key in each UTC hour, for 30 days after it stops
being current. Later writes in the same hour overwrite that version. `History` lists them, so it
shows the state at the end of each hour and nothing finer.

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

It returns the newest first. `Version` is the string you pass to `PeekVersion`, `At` is a Unix
timestamp in seconds, and `Deleted` is `true` when that version was a delete.

The limit is clamped between 1 and 100 and defaults to 25.

## PeekVersion [#peekversion]

```luau
local Was = Store:PeekVersion(UserId, Entry.Version):Wait()
if Was then
	print(Was.Gold)
end
```

This folds the old record the same way a load does, so migrations run and it returns the state, not
the stored record.

It is read only, and there is no restore. Writing an old snapshot over a live profile would erase
everything that happened since, including money that arrived from a transfer. To roll something
back, find what changed and write ops that undo it.

## Reset [#reset]

`Reset` puts a key back to `Default`.

```luau
local Ok, Why = Store:Reset(UserId):Wait()
```

It is an op like any other, so it goes in the log and every server sees it. It keeps `_Received` and
`_Held`. Clearing the applied ids would let an old retry apply again, and clearing `_Held` would
destroy money that is part way through a transfer.

A server won't reset a record written at a version it doesn't know, so a reset can't downgrade a
profile during a deploy.

It can return [`Unresolved`](/docs/concepts/reasons) when a transaction leg parked on the key could
change the result. Call it again later. Nothing was written.

## Erase [#erase]

`Erase` deletes the player data on a key. Use it for GDPR deletion requests.

```luau
local Gone, Why = Store:Erase(UserId):Wait()
if not Gone then
	warn(`that key is still there: {Why}`)
end
```

Check the result. `false` means nothing was erased, so a deletion request is not done yet.

First it delivers any transfers this key was part way through sending. If a receiver doesn't accept
one, `Erase` returns `Busy` and changes nothing. Call it again later. A transfer that can't be
delivered is refunded once it is 8 days old, so an `Erase` after that succeeds.

Money arriving is different, because another server can be delivering to this key while you erase
it. So an erase replaces the record with a tombstone instead of removing the key. A transfer to a
tombstoned key is refused, and the sender keeps the money set aside.

**The tombstone lasts 8 days.** A write to the key doesn't clear it. The tombstone has to outlast
every transfer still on its way to the key, and after 8 days none can be.

You can still read and write a tombstoned key. It folds from `Default` like a new profile. Only
transfers to it are refused.

The tombstone holds a timestamp, your `Default`, and the key's applied names. It holds no other
player data. To remove the key completely, call `Erase` again after the 8 days. If the key still
holds names from the last 30 days, that call keeps the tombstone and warns, because a refund may
still need to check those names. Call `Erase` again after they expire.

While that second `Erase` removes the key, a write to the key returns
[`Busy`](/docs/concepts/reasons). This lasts at most 2 minutes.

The names matter. `ProcessReceipt` retries until you return `PurchaseGranted`, and Roblox can retry
one you already granted. If an erase dropped the names, that retry would look like a new purchase
and pay out again. So a read of an erased key returns a new profile, but a receipt already paid out
is still refused.

A refused sender isn't refunded at once. Their money stays set aside until the transfer is overdue,
after the same 8 days, and then the sweeper refunds it. Calling `RecoverTransfers` on the sender
before that does nothing, on purpose: a refund paid early could still be delivered later and pay
twice.

Erasing a player who is still in the server warns. Unload them first:

```luau
Store:Unload(Player)
Store:Erase(Player.UserId):Wait()
```

A session on **another** server that loaded the key before the erase can't bring the data back. Its
next save is refused, and the session closes. `Flush`, `Release` and `Commit` then return
[`Refused`](/docs/concepts/reasons) instead of reporting a save that never happened.

The ops that session had queued are lost, so remove the player from every server before you erase
them. The server holding the session warns when it closes, with the key and the number of unsaved
ops.

The erase is still a version, so `History` lists it, and `PeekVersion` can read the old data for 30
days. Roblox keeps that history whatever Ledger does, so keep it in mind when you erase someone for a
legal reason.

## Sweeping [#sweeping]

Ledger runs a background sweeper that finishes unfinished transfers, settles parked transaction
legs, and deletes old transaction markers. It goes back to the keys where it saw a problem, so you
usually don't need to do anything.

`Ledger.Sweep()` runs a pass now. Use it in a test, or during a live incident when you don't want to
wait for the next pass.

## Support tooling [#support-tooling]

Every store method that takes a key works on a player who is offline or on another server, so a
support tool doesn't need the player online:

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

Put a `Once` name on every op a support tool writes, because someone will click the button twice.

It stops the second click, and a retry minutes or days later. It doesn't stop the same ticket being
fulfilled again months later, because a name is kept for 30 days.
If a reopened ticket has to stay fulfilled permanently, record that in the state your reducer can see
and refuse on it there. See [how long a name is remembered](/docs/concepts/once#how-long-a-name-is-remembered).

## Editing storage directly [#editing-storage-directly]

A datastore editor plugin shows Ledger's record, not the player's state:

```luau
{
	Snapshot = { Gold = 100 },   -- the state as of the last compaction
	Ops = { ... },               -- changes since then, not folded in yet
	Seen = { ... },              -- op ids already applied
	Version = 3, Floor = 1, Envelope = 2
}
```

The value you are looking for is inside `Snapshot`, but it isn't the current value, because every op
in `Ops` still applies on top of it.

<Callout type="warn">
  Replacing the record with a plain state table erases the player. With no `Snapshot` field, Ledger
  folds from your `Default` and reads a new profile. What you typed stays on the record as a field
  nothing reads, until the next compaction removes it.
</Callout>

Other mistakes, worst first:

- **Editing `Snapshot` while `Ops` has anything in it.** Your edit is saved, then the ops apply on
  top. Set gold to 1000 with a spend of 50 still in `Ops`, and the fold returns 950.
- **Deleting `Seen`.** It holds the ids of ops already compacted, so an old retry can apply a second
  time.
- **Removing an op that has a `Tx` field.** That is a parked [transaction](/docs/guides/transactions)
  leg. The marker still counts it, so the transaction can apply on only some keys, or stay stuck
  until it is cleaned up.
- **Clearing `_Held` or `_Received` inside `Snapshot`.** `_Held` is money set aside for a transfer
  that has not finished, so deleting it destroys that money. `_Received` is the delivery evidence, so
  deleting it lets the same transfer pay twice.
- **Raising `Envelope`** is the only safe mistake. Every server returns
  [`Behind`](/docs/concepts/reasons) and won't touch the record, instead of misreading it.

Use the API instead. It goes through your reducer and the log, and it works whether the player is
online, on another server, or offline:

```luau
Store:Inspect(UserId):Wait()   -- see what is actually on the key first
Store:Edit(UserId, "GrantItem", { Item = "Sword", Once = `support:{TicketId}` }):Wait()
Store:Reset(UserId):Wait()     -- back to Default, keeping _Received and _Held
```

`Reset` keeps `_Received` and `_Held`, which a hand edit wouldn't. `Once` makes a second click
safe.

If you do edit storage, a live session doesn't see the change until its next autosave reads the key.
That is within 30 seconds when it has ops queued, and within 2 minutes when it has none. The ops it
already queued were checked against the state before your edit.


# Reservations and totals (https://xoifaii.github.io/LedgerDocs/docs/guides/reservations)



Two problems look like they need a transaction but don't.

The first is a limit: 500 copies of a sword, 40 raid places, one seat per table. The second is a
total: an event prize pool, a kill counter, a donation total.

Both are cheaper and simpler on one key than across two, and each has its own methods.

## Reserve, Confirm, Release [#reserve-confirm-release]

A reservation holds units of a number field on one key. The hold is stored in MemoryStore, not on
the key. The field keeps its value, and `Holds` returns how much of it is held. When nothing is left
to hold, `Reserve` refuses the next buyer before checkout starts.

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

`Stock` is still 500, `Holds("sword", "Stock")` returns 1, and the next `Reserve` can hold up to 499.
A hold ends in one of two ways:

```luau
Shop:Confirm("sword", OrderId, "Sell", { Count = 1 }):Wait()   -- your op spends the unit, stock is 499
Shop:Release("sword", OrderId):Wait()                           -- the hold goes, stock was never touched
```

`Confirm` takes the kind and fields of your own op, the same ones you would pass to `Edit`. Your
reducer decides what a checkout takes from the key, and refuses one the field can't cover:

```luau
-- in your reducer
if Op.Kind == "Sell" then
	if State.Stock < Op.Count then
		return nil
	end
	return { Stock = State.Stock - Op.Count }
end
```

The reducer is what enforces the limit. A hold only decides who gets to check out first, and it is
not part of the fold, so an `Edit` can spend units someone holds, and their `Confirm` then returns
`Refused`. A hold that was lost, or never made because MemoryStore was down, has the same effect: one
refused checkout, never an oversell. Show players the field minus `Holds` when "3 left" has to be
accurate.

`Reserve` with an id that already holds the same amount of the same field returns `true` and holds
nothing more, so a retry is safe. With a different amount or field it returns `Spent`.

`Confirm` twice with one id spends once while the key still has that op's id. The key keeps an id
while the op is in the log, and for the next 2048 ops it compacts. After a hold ends, a new hold can
use the same id, but a `Confirm` under it doesn't sell again while the key has the first confirm's
id. Give each purchase its own id.

A confirm you may retry later than that needs `IdAt` in its fields: the time you first sent it, the
same on every retry. Once the key has dropped the id, the retry returns
[`Unresolved`](/docs/concepts/reasons) and sells nothing. See
[Confirm](/docs/reference/store#confirm).

### One key is one item [#one-key-is-one-item]

`"sword"` and `"shield"` are separate keys with separate records, so each has its own stock.
`Default` is not a template for an item. It is the state of a key nothing has written to yet, and
each item's stock is set by an op like any other change:

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

Start the default at zero. A key nobody has written to still folds to it, so with a default of 500 a
misspelled item id has 500 in stock and `Reserve` accepts all of it. Give the restock a
[`Once`](/docs/concepts/once) name if it should apply once however many servers run it.

The second argument to `Reserve` is a field, so one key can hold several pools. Only do that for
units that share a limit. Each key has one write queue, so putting every item on one key makes every
purchase wait for every other.

### Holds expire on their own [#holds-expire-on-their-own]

A hold expires after 15 minutes. Nothing has to be returned, because nothing was taken. The `Hold`
option sets a shorter time. Fifteen minutes is both the default and the maximum, so `Hold` can only
shorten a hold. A `Hold` above the maximum throws an error at the call.

For a checkout that stays open longer, call `Reserve` again with the same id. That extends the hold
and holds nothing more. Call `Release` when the player leaves checkout, so the next buyer doesn't
wait 15 minutes.

One key can have 256 holds at once. Past that, `Reserve` returns [`Busy`](/docs/concepts/reasons),
which means holds are being made faster than they are confirmed or released. Every hold expires
within 15 minutes, so try again shortly. `Refused` means the field can't cover the units.

`Reserve` checks a hold against the last value it read from the key. Before it refuses, it reads the
key again, so it sees a restock. `Reserve` needs MemoryStore, which in Studio means API access has to
be on. Without it, `Reserve` returns [`Unresolved`](/docs/concepts/reasons), and checkout falls back
to first come, first served, which the reducer enforces.

## Moving the units to another key [#moving-the-units-to-another-key]

`Confirm` spends the units where they are. `Transfer` with a field moves them somewhere else:

```luau
Shop:Transfer("sword", tostring(Player.UserId), 1, OrderId .. ":unit", "Stock"):Wait()
```

That is the same three op transfer a balance uses, on the field you name. The units are set aside on
the way, the transfer applies once per id, and the sweeper finishes or refunds it if the server stops
between the steps. See [Transfers](/docs/guides/transfers).

A transfer id belongs to one transfer, and the field is part of that transfer, so the price and the
unit of a purchase need two ids. The same id on a different field returns
[`Spent`](/docs/concepts/reasons).

## The buying sequence [#the-buying-sequence]

The order matters, because a server can stop between any two calls. This order recovers from a stop
at any point:

```luau
Shop:Reserve("sword", "Stock", 1, OrderId):Wait()
Bank:Transfer(tostring(Player.UserId), "shop", 250, OrderId .. ":price"):Wait()
Shop:Transfer("sword", tostring(Player.UserId), 1, OrderId .. ":unit", "Stock"):Wait()
```

`Bank` is a store with `Keys = "String"`, and the player's key on it is `tostring(Player.UserId)`.
A transfer moves a field between two keys of one store, so both keys have to suit that store's key
mode. A player keyed store cannot hold a key called `"shop"`, and a string keyed store cannot take a
`UserId` as a number. Ledger throws at the call when a key does not suit the store.

Each transfer applies once per id, so running the whole sequence again after a crash applies each
one exactly once. A transfer whose id already moved returns `true`. The hold expires once the unit has
left the shop, or sooner if you `Release` it.

If the server stops before the payment, nothing was taken. If it stops between the two transfers,
running the sequence again charges once and delivers the unit once.

A purchase that stays on one key is simpler: `Confirm` with your own op. Put a
[`Once`](/docs/concepts/once) name on any op that grants something on another key, so `DidApply` can
return whether it applied. Don't use the reservation id for that. After the key compacts, a repeated
`Confirm` returns [`Unresolved`](/docs/concepts/reasons), and a confirmed, a released and an expired
hold all look the same: no hold.

## Bump and Total [#bump-and-total]

A total is the other shape. Nothing is limited, a lot of servers add to it, and you want the sum.

Only one server can write a key at a time, so a key that every server writes to spends most of its
time retrying. `Bump` spreads the total over 16 keys and gives each server its own, so servers don't
wait for each other. `Shards` in the config sets the number of keys, 1 to 99. For a large fleet,
raise it to about one shard per 80 servers that bump the total. See
[Limits](/docs/limits#reservations-and-totals). Never lower it on a live store: the bumps on the
removed shards would drop out of every total.

```luau
local Events = Ledger.New({
	Name = "Events",
	Keys = "String",
	Default = { Gold = 0 },
	Reducer = Reducer
})

Events:Bump("summer", "Gold", 25):Wait()

local Pool = Events:Total("summer", "Gold"):Wait()
```

`Total` returns a sum cached in MemoryStore, for one request unit. Once a minute, one server reads
every shard and updates the cached sum. Read it on a timer.

If your game bumps on every action, set `BumpEvery` on the store, in seconds up to 60. The server
then queues its bumps and writes one op per total per window. `Bump` returns a Future that completes
when the window is written. Wait on it like `Commit`, or don't wait and treat it like `Apply`. A
server that crashes loses the bumps of its last window.

`Total` returns what has been added, not the sum of the field on the 16 keys. `Bump` keeps its own
count on each shard and never changes the field your reducer owns, so `Default` never counts toward
the total. A total nobody has added to returns 0.

### A total can only go up [#a-total-can-only-go-up]

`Bump` refuses any amount that isn't positive. No shard can read the others, so no shard knows the
sum, and nothing can enforce a limit across them.

That is the difference between the two. A reservation can enforce a limit because everything is on
one key. A total gives that up so many servers can write at once.

If you need both, split the stock into fixed pools on separate keys and reserve from one pool. Each
pool enforces its own share, so the overall limit holds. When one pool runs out, try the next.

## Which tool to use [#which-tool-to-use]

| | |
| --- | --- |
| The limit is a property of one key | `Reserve` and `Confirm` |
| Units held on one key end up on another | `Reserve` and `Transfer` with a field |
| Add only, no limit, many servers | `Bump` |
| A balance moves between two keys | [`Transfer`](/docs/guides/transfers) |
| Two keys must change together and one change can't be undone | [`Tx`](/docs/guides/transactions) |

To choose, ask what undoing it would take. If you can write that as an op, use a reservation or a
transfer. If undoing it means asking the other player to give the sword back, use a transaction.

Trading a sword for a shield is a real transaction. Selling a sword from a shop is not.

## What this costs [#what-this-costs]

Measured on the fake datastore, 100 limited stock purchases:

| | Requests |
| --- | --- |
| A transaction across buyer and shelf | 800 |
| Reserve and confirm | 201 |

`Reserve` and `Release` cost no datastore requests, only two MemoryStore request units each, and the
first hold on a key reads the key once. `Confirm` costs one request and two units. Moving the units to
another key is a transfer, which costs three requests.

A hold never waits in the key's write queue. When 500 buyers reserve at once, MemoryStore handles
them, and only the buyers who got a hold go on to write. A transaction can't do that.


# Sessions (https://xoifaii.github.io/LedgerDocs/docs/guides/sessions)



A session is one player's data loaded on this server. `Load` creates it, and it stays until `Unload`
or until the store is destroyed.

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

`Load` yields while it reads the record and folds it. If that fails, Ledger kicks the player with a
message asking them to rejoin, so they never play on an empty profile that could overwrite the real
one. To handle each failure reason differently, pass
[`OnLoadFailed`](/docs/reference/ledger#onloadfailed) when you build the store.

Calling `Load` a second time for the same player warns and does nothing. If the player leaves while
the load is still running, Ledger releases the session when the load finishes.

`Unload` stops the autosave timer, writes every queued op, and yields until they are saved.

A reference you kept to the session still works after that, but every write returns
[`Closed`](/docs/concepts/reasons):

```luau
Store:Unload(Player)
Session:Apply("Add", { Amount = 1 })   --> false, "Closed"
```

`Ledger.CloseAll()` releases every session, so the same applies after a shutdown.

## Getting the session [#getting-the-session]

Which method to use depends on what should happen when the player isn't loaded.

`Store:Get(Player)` returns the session, or `nil`. Use it when the player not being loaded is normal.

`Store:Expect(Player)` returns the session, or throws an error. Use it in code that only runs once
the player is loaded, so a mistake throws an error instead of returning `nil`.

`Store:IsLoaded(Player)` returns a boolean.

`Store:WaitForLoaded(Player)` yields until the session is loaded and returns it, or returns `nil` if
the player left first. Use it in callbacks that can run during a join, like `ProcessReceipt`.

`Store:Read(Player)` returns the state table, or `nil`. Use it when you only need to read.

```luau
Store:IsLoaded(Player)        --> false
Store:Get(Player)             --> nil
Store:Expect(Player)          --> throws, data for Name is not loaded

Store:Load(Player)

Store:IsLoaded(Player)        --> true
Store:Read(Player)            --> { Gold = 0 }
```

These seven take the `Player`: `Load`, `Unload`, `Get`, `Expect`, `IsLoaded`, `WaitForLoaded` and
`Read`. Every other method takes a key, so pass `Player.UserId`. `Store:Peek(Player)` throws an error
that says it wants a key.

## Autosave [#autosave]

Every session autosaves every 30 seconds. It writes the queued ops, and compacts the log if it has
grown too long or too large.

If the server is out of datastore budget, the autosave is skipped and Ledger warns. Ops keep
queueing, and if it goes on, writes start returning [`Backlog`](/docs/concepts/reasons).

A session with nothing queued and no transaction leg parked on its key reads the key every two
minutes instead. It has nothing to write, so it only picks up what other servers wrote. That read is
how a session sees gold another player sent, or a trade.

[`Store:Stale()`](/docs/reference/store#stale) fires with each key this server writes with `Edit`,
`Transfer` or `Tx`, so you can flush that session at once instead of waiting for the read. See
[Transactions](/docs/guides/transactions#a-live-session-does-not-know-a-leg-wrote-to-it).

## Log size [#log-size]

`Session.LogSize` is the number of ops in the stored log, and `Session.LogBytes` is roughly the size
in bytes of those ops plus the queued ones. Both are read only, and mostly useful for a debug display.

A queued op counts in `LogBytes` but not in `LogSize`, because it is not in the stored log yet:

```luau
Session.LogSize, Session.LogBytes   --> 0, 0
Session:Apply("Add", { Amount = 5 })
Session.LogSize, Session.LogBytes   --> 0, 54
```

You don't need to watch them, because autosave compacts on its own. Call `Session:Compact()` to
compact now, for example right before something that writes a lot.

## Shutting down [#shutting-down]

`Ledger.CloseAll()` handles the whole shutdown. It stops the background sweeper, and on each key it
drops every queued datastore call except the newest, which returns `Closed` to the dropped callers.
Then it saves every loaded session and yields until everything is done.

Put it in `BindToClose` with nothing else. Roblox gives a server limited time to shut down, and
`CloseAll` does the steps in the right order to fit.

`Store:Destroy()` does the same for one store and frees its name, so you can build another store with
that name. This is mostly for tests.

## Watching state [#watching-state]

```luau
local Connection = Session:Observe():Subscribe(function(State)
	UpdateHud(Player, State)
end)
```

It fires on every change that is applied, including changes from another server that arrive when the
session reads the key, such as a transfer or a transaction. It doesn't fire for a refused op, because
nothing changed.

A listener runs on the thread doing the write, so it must not yield. `Store:Stale()` is the only
observer whose listeners can yield.

Ledger never disconnects your listeners. A released session stops pushing, so they never fire again,
and a connection you didn't store is garbage collected with the session. If you did store it,
disconnect it yourself. See [Observer](/docs/reference/observer).


# Testing (https://xoifaii.github.io/LedgerDocs/docs/guides/testing)



## The mock datastore [#the-mock-datastore]

`Mock = true` runs a store on an in memory datastore instead of `DataStoreService`. It needs no API
access, no published place and no network. Nothing it saves outlives the server.

```luau
local Store = Ledger.New<<Profile, Ops>>({
	Name = "Test",
	Default = { Gold = 0 },
	Reducer = Reducer,
	Mock = true,
})
```

The mock enforces the same limits as the real datastore:

- Names and keys up to 50 characters, and values up to 4 MB as JSON. Only values JSON can hold.
- The request budget for this server and for the whole experience, refilled over a minute, with a
  queue of 30 requests behind each.
- The throughput cap on each key: 25 MB read and 4 MB written per minute.
- Versions kept for 30 days, and key listings in pages.

It is stricter than Studio. Studio gives a server a larger request budget than a live server gets,
so code that fits in Studio can run out of budget live. The mock uses the live budgets.

It does not model the 4 second read cache, a read that is a few seconds behind another server's
write, or throttling inside Roblox's backend.

### Sizing it [#sizing-it]

Pass a table instead of `true` to set the size of server the mock acts as:

| Option | Default | What it sets |
| --- | --- | --- |
| `Players` | `0` | Players on this server. Sizes this server's request budget. |
| `CCU` | `Players` | Players in the whole experience. Sizes the experience's request budget. |
| `Throttled` | `true` | Whether the budgets and caps are enforced. |

A request has to fit both budgets, so the smaller one is the limit:

```luau
Mock = { Players = 30 }              --> 900 writes, 1260 reads, 65 lists a minute
Mock = { Players = 30, CCU = 10000 } --> 1260 writes, 1260 reads, 65 lists a minute
```

With `CCU` left at its default, the experience budget is the tighter limit on writes. Raise `CCU` to
test a server where only its own budget limits it.

Set `Throttled = false` to test logic without waiting on budgets. Leave it on to test how your code
behaves under live limits.

Every store built with `Mock` shares one fake datastore, and the first one sets its size. A later
store that asks for a different size throws. `Mock = true` uses the size that is already set.

## Checks that only run in Studio [#checks-that-only-run-in-studio]

In Studio, Ledger checks two things each time a session saves:

- It replays the log and compares the result with the live state. A difference means your reducer
  is not deterministic, and the warning names the field that differs.
- It checks that the state can be stored, and names the field that can't.

Both cost too much to run on a live server, so a live server gives no warning. Fix what they report
in Studio.

## Writing a test [#writing-a-test]

Build the store on the mock, write to it, then check the result with `Peek`:

```luau
local Store = Ledger.New<<Profile, Ops>>({
	Name = "Test",
	Default = { Gold = 100 },
	Reducer = Reducer,
	Balance = "Gold",
	Mock = { Players = 8, Throttled = false },
})

Store:Edit(1, "SpendGold", { Amount = 30 }):Wait()

local State = Store:Peek(1):Wait()
assert(State ~= nil and State.Gold == 70)

Store:Destroy()
```

Call `Store:Destroy()` at the end of each test. It frees the store's name, so the next test can
build a store with the same name. Building two live stores with one name throws.

The fake datastore keeps its data for as long as the server runs, and `Destroy` does not clear it.
A later test that reads the same key sees what an earlier test wrote. Give each test its own keys.


# Transactions (https://xoifaii.github.io/LedgerDocs/docs/guides/transactions)



`Tx` writes to several keys at once and guarantees that either every write is applied or none is.
The keys can be in two different stores, and none of them needs a loaded session.

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
  A transaction is the most expensive thing Ledger does, and many jobs people use it for can be done
  more cheaply. Selling limited stock, reserving a slot and keeping a total each need only one key.
  Read [Reservations and totals](/docs/guides/reservations) first.

  Use a transaction only when two keys must change together, and neither change could be undone
  afterwards. Trading a sword for a shield needs this. Selling a sword from a shop does not.
</Callout>

## The id [#the-id]

The id comes first and it's required. It has to be stable and derived from the thing the
transaction is for, such as a trade id, an order id or a match id. Never build it from the clock,
and never create one inside the `Tx` call.

A stable id is what makes a retry safe. Running the same id again doesn't do it twice. It finds every
leg already settled and returns `true` having moved nothing, so to retry an `Unresolved`, make the
same call again:

```luau
local Ok, Why = Store:Tx(`trade:{TradeId}`, Legs):Wait()
if Why == Ledger.Reason.Unresolved then
	Ok, Why = Store:Tx(`trade:{TradeId}`, Legs):Wait()
end
```

The legs have to match on every attempt. Ledger keeps a fingerprint of the legs with the id, so the
same id run again for a different set of keys or a different amount returns
[`Spent`](/docs/concepts/reasons) rather than `true`. Ledger keeps the id for 30 days, the same as
every [applied name](/docs/limits#applied-names). After that the id is forgotten, and running it
again applies it again.

Ids are 1 to 50 characters.

### Where the id comes from [#where-the-id-comes-from]

A purchase and a request from outside the game each come with an id. A trade does not, so you
create one.

**A purchase** comes with `ReceiptInfo.PurchaseId`. Roblox keeps calling `ProcessReceipt` with the
same one until you return `PurchaseGranted`, so it survives a server restart as well as a retry.

**A trade** has no id, so create one when the trade opens rather than when it commits:

```luau
local function OpenTrade(A: Player, B: Player)
	return {
		Id = Ledger.Id(),   -- once, here
		A = A,
		B = B
	}
end

-- later, when both sides confirm
Store:Tx(`trade:{Trade.Id}`, Legs):Wait()
```

`Ledger.Id` is fine there because it's created once and stored on the trade. What breaks is
generating one inside the `Tx` call, since every retry would be a new transaction and move the money
again.

**Anything from outside**, a webhook or your own website, should use the sender's order id. They're
the ones who retry, so their id is the one that stays the same when they do.

In all three cases, the id has to last at least as long as anything that might retry the call. For
a purchase Roblox stores it. For a trade only the hosting server would retry, so that server's memory
is enough. If nothing would retry the call, the id does not need to outlive it.

## The legs [#the-legs]

Between two and four legs. Each one names a key and an op.
[Limits](/docs/limits#transactions) explains where those two numbers come from. Read it before you
add a fourth leg.

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

A transaction can only touch a key once. Ledger throws if two legs name the same key, and does not
merge them.

Don't put `Once` on a leg. The transaction id already makes every leg apply at most once, and Ledger
throws if it sees one.

### A leg will not apply to an erased key [#a-leg-will-not-apply-to-an-erased-key]

A key that was [erased](/docs/guides/recovery) refuses a leg for the 8 days its tombstone lasts, and
the whole transaction returns [`Refused`](/docs/concepts/reasons) with a warning naming the key.
Nothing is applied to any of the other keys.

```luau
Store:Erase("shop"):Wait()

Store:Tx("order1", {
	{ Key = "player", Kind = "Pay", Fields = { Amount = 25 } },
	{ Key = "shop", Kind = "Take", Fields = { Amount = 25 } },
}):Wait()   --> false, Refused
```

Once the tombstone runs out the key accepts legs again.

### A leg reads what is stored, not what a session is holding [#a-leg-reads-what-is-stored-not-what-a-session-is-holding]

Every leg folds the record on the datastore. A live session that has taken ops through
[`Apply`](/docs/concepts/apply-and-commit) has not written them yet, so a leg on that player's key
does not see them.

This mostly affects a player who just joined. Grant them something with `Apply`, list it for sale a
few seconds later, and the leg reads a key that has never been written, which folds to your `Default`.
The reducer sees an empty inventory and a new player, refuses, and the whole transaction returns
[`Refused`](/docs/concepts/reasons).

```luau
-- the session says the item is there, the stored record does not
Session:Apply("GrantItem", { Item = ItemId })

Store:Tx(`listing:{ListingId}`, {
	{ Key = "market", Kind = "AddListing", Fields = { Item = ItemId } },
	{ Store = Players, UserId = Seller, Kind = "ListItem", Fields = { Item = ItemId } },
}):Wait()   --> false, Refused
```

There are two fixes. Flush first if the session is on this server:

```luau
Session:Flush():Wait()
```

Or write it durably in the first place, which is what `Commit` is for:

```luau
Session:Commit("GrantItem", { Item = ItemId }):Wait()
```

Prefer `Commit` for anything a transaction will later depend on. A flush only works while the session
is on the server running the transaction, and the seller may be on another one or offline.

Waiting does not fix it. An autosave writes only what was queued when it ran, so ops applied after it
are still unsaved when the transaction runs.

### A live session does not know a leg wrote to it [#a-live-session-does-not-know-a-leg-wrote-to-it]

The record carries the change the moment `Tx` returns `true`. A session already open on that key does
not. It holds its own copy and only picks an outside write up when it folds the record again.

A session with nothing queued and nothing parked reads every two minutes, so a player who just bought
something waits that long to see it arrive. Nothing is wrong and nothing is at risk. They are reading
a copy that has not caught up.

[`Store:Stale()`](/docs/reference/store#stale) is a stream of the keys this server has changed.
Subscribe once, and flush the session on every key it names:

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
costs one request for each changed key that has a session on this server, and nothing while no key
changes.

A cross store transaction pushes each leg onto its own store's stream, so subscribe on both stores.

This listener yields, which the stale stream allows. Listeners on `Session:Observe()` may not yield.
See [Observer](/docs/reference/observer#listeners-that-may-yield).

A player on another server is not on this stream. Their session is on that server, so that server
has to flush it. The next section shows how to ask it to.

### Telling another server to refresh [#telling-another-server-to-refresh]

Ledger can't reach another server. Your game can, so send the key over `MessagingService` and let the
server holding that player do the flush.

Drive it from the same stream. If the key has a session on this server, flush it. Otherwise publish
the key, so the server that has the session can flush it:

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

With this, the buyer sees the purchase within a moment, whichever server they are on. Without it
they wait for the ordinary two minute read.

**Send the key and nothing else.** The other server re-reads the key itself, so the stored record
stays the only source of state. A message that carried the new inventory would be a second copy, and
a dropped or repeated message would leave the two servers disagreeing.

**Delivery is not guaranteed.** `MessagingService` is best effort and rate limited, and
`PublishAsync` throws once you hit a limit, which is why the call above is wrapped. If a message
never arrives, the player sees the change at the ordinary two minute read. Nothing is lost either
way, so there is no need to confirm delivery or retry.

Publishing only when the player isn't here keeps most purchases off the topic entirely.

### Errors thrown and reasons returned [#errors-thrown-and-reasons-returned]

The shape of a leg is your code, so getting it wrong throws where you wrote it. Each of these throws:
a key the target store won't take, a missing or oversized id, the wrong number of legs, the same key
twice, a `Once` on a leg, and a `Store` that Ledger didn't build.

A bad value inside `Fields` is data, not code, so `Tx` returns `Invalid` instead of throwing:

```luau
local Ok, Why = Store:Tx(`trade:{TradeId}`, {
	{ UserId = A, Kind = "Give", Fields = { Amount = Price * Quantity } },
	{ UserId = B, Kind = "Take", Fields = { Amount = Price * Quantity } }
}):Wait()

if Why == Ledger.Reason.Invalid then
	-- a field can't be stored, for example an Instance, a NaN from that multiply, a reserved name
end
```

`Edit` handles bad fields the same way, with the same [`Invalid`](/docs/concepts/reasons). Nothing
is prepared on any key when it happens, so there's nothing to clean up.

## How it decides [#how-it-decides]

Each leg gets prepared on its key first. A prepared op is written into the log but carries a stamp
that makes the fold skip it, so it has no effect yet. A prepared leg is called parked until the
transaction settles.

Once every leg is prepared, Ledger writes the outcome to a marker key. That single write is the
moment the transaction commits, and there's exactly one of them, so two servers racing the same
transaction can't disagree about what happened.

Committing removes the stamps, so the fold starts including the ops. Aborting removes the ops.

If any leg's reducer refuses during prepare, the whole transaction aborts and Ledger removes the
prepared op from every other leg.

## Parked legs [#parked-legs]

If the server dies between preparing a leg and writing the outcome, that leg stays parked on its key.
Anything that reads the key sees the parked leg.

A few things clear it. Any read or write on that key tries to settle it first. The background
sweeper picks up keys it knows have parked legs. And once a transaction's marker has not changed for
30 seconds per leg, a minute for two legs and two minutes for four, it counts as abandoned. The next
server that reads it aborts it.

While a leg is parked, writes to that key return [`Busy`](/docs/concepts/reasons), and `Edit` or
`Reset` can return `Unresolved` when the parked leg would change the verdict. Neither means it
failed. Both mean ask again in a moment.

`Tx` does not retry `Busy` itself, because retrying at once adds load to a key that is already
contended. Retry it yourself, with a delay that grows each time. The same id makes a retry safe, so
`Unresolved` can be retried the same way:

```luau
local MAX_ATTEMPTS = 5
local BASE_DELAY = 0.5 -- seconds

local function TxWithRetry(Id: string, Legs: { Ledger.TxLeg }): (boolean, Ledger.Reason?)
	local Ok, Why = Store:Tx(Id, Legs):Wait()
	for Attempt = 1, MAX_ATTEMPTS - 1 do
		if Ok or (Why ~= Ledger.Reason.Busy and Why ~= Ledger.Reason.Unresolved) then
			break
		end

		-- the delay doubles each attempt, with jitter so servers that collided don't retry in step
		task.wait(BASE_DELAY * 2 ^ (Attempt - 1) * (0.5 + math.random()))
		Ok, Why = Store:Tx(Id, Legs):Wait()
	end
	return Ok, Why
end

local Ok, Why = TxWithRetry(`trade:{TradeId}`, Legs)
```

The waits add up to about 7.5 seconds. Another server's lease on the keys is released when its
transaction finishes, usually well within that time, and lasts at most 10 seconds. A leg left by a
crashed server is not aborted until its marker has been unchanged for 30 seconds per leg. If `Busy`
comes back after the last attempt, tell the player to try again rather than retrying for longer.

A key that every player writes to limits throughput, not correctness. See
[One key at a time](/docs/limits#one-key-at-a-time).

`Ledger.Sweep()` runs a sweeper pass immediately.

## Marker cleanup [#marker-cleanup]

The sweeper deletes a committed marker about an hour after it last changed, and an aborted one after
5 minutes. Markers are kept on the store named `<YourStore>_Tx`, which Ledger creates alongside
yours.

That is why store names cap at 47 characters instead of the datastore's 50. Ledger needs the three
characters for `_Tx`.

## Mixing stores [#mixing-stores]

```luau
local Ok, Why = Players:Tx(`donate:{OrderId}`, {
	{ UserId = Player.UserId, Kind = "SpendGold", Fields = { Amount = 500 } },
	{ Store = Clans, Key = "cool-guys", Kind = "Donate", Fields = { Amount = 500 } },
}):Wait()
```

Both stores have to have been built by `Ledger.New` in this server. A leg naming something else
throws.

## When not to use it [#when-not-to-use-it]

If you're moving one balance one direction, use a [transfer](/docs/guides/transfers). It costs 3
requests where a two leg transaction costs 8, finishes on its own after a crash, and doesn't leave a
key `Busy` while it runs.

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

## What happens [#what-happens]

It's three steps, not one write.

**Reserve.** Ledger appends an op to the sender that takes the money out of the balance and puts it
in `_Held` under a transfer id. If the sender doesn't have enough, Ledger refuses the reserve without
calling your reducer, and `Transfer` returns `Refused`.

**Deliver.** It appends an op to the receiver that adds the money and records the transfer id in
their `_Received`.

**Settle.** It goes back to the sender and drops the hold, because the money has arrived.

Money is only ever in one of three places: the sender's balance, the sender's `_Held`, or the
receiver's balance. There's no moment where it's in two, and no moment where it's in none. So a crash
partway through cannot lose or duplicate money.

## If a server crashes during a transfer [#if-a-server-crashes-during-a-transfer]

If the server dies between reserve and deliver, the money is sitting in the sender's `_Held`. It's
out of their balance so they can't spend it twice, and it hasn't arrived yet.

Ledger picks that up on its own. A background sweeper notices held money and completes the transfer,
and the sender's next load starts a recovery too. You don't need to schedule anything for this, and
you shouldn't call `RecoverTransfers` by hand in normal operation.

If the receiver turns out to be gone or the delivery keeps failing, the hold eventually expires and
the money goes back to the sender.

## Ids and retries [#ids-and-retries]

By default each transfer gets a fresh id, which means calling it twice moves the money twice. That is
only safe when the call is never retried, such as a one off tip. A trade can be retried, so give it
an id.

When a call might be a retry of the same transfer, pass an id:

```luau
local Ok, Why = Store:Transfer(From, To, 250, `trade:{TradeId}`):Wait()
```

Now a second call with that id doesn't move anything again. It returns `true`, because the transfer
already went through. Every retry with that id within 30 days returns `true`, so retrying is safe.

The amount and the receiver have to match on every attempt. Calling again with the same id but a
different amount or receiver returns [`Spent`](/docs/concepts/reasons). Ledger keeps a fingerprint of
the amount and both keys with each id, so it can tell a retry from an id reused for a different
transfer.

Ids are 1 to 64 characters. The id has to be the same string on every attempt, so make it once and
keep it somewhere the retry can read it:

```luau
-- wrong, a new id each attempt, so a retry sends the money a second time
Store:Transfer(From, To, 250, HttpService:GenerateGUID(false)):Wait()

-- right, the id was made when the trade opened and lives on the trade
Store:Transfer(From, To, 250, `trade:{Trade.Id}`):Wait()
```

`Trade.Id` is whatever already names that trade, and it can be a GUID too. What matters is that it
was made once, so every retry reads the same one. If nothing names the trade yet, make the id when
the trade opens and store it on the trade, next to the two players and the offer. An order id, a
match id and a receipt id all work the same way.

Never build an id from the clock. Never build one from the amount and the two keys either. The same
two players can trade the same amount twice, and Ledger would treat the second trade as a retry of
the first and skip it.

[Where the id comes from](/docs/guides/transactions#where-the-id-comes-from) covers the three cases
and how long each id has to survive.

## Checking the result [#checking-the-result]

`true` means the money moved and both sides are settled.

`Refused` means the sender didn't have it. An amount that isn't positive and finite throws at the call
site instead, because that's a bug in the caller rather than a result about the money.

`Spent` has two meanings, and both come only from a call with an id. Either the id already went
through for a different amount or a different key, or the hold sat there long enough to expire and
the money went **back to the sender**. Either way nothing moved on this call, so don't give anything
out on it. A transfer that actually went through returns `true`, not this.

`Busy` means a transaction is holding the sender's key. Ledger has already scheduled a cleanup pass.
Try again shortly.

`Unresolved` means the reserve went through but the delivery didn't finish. The money is set aside
and Ledger will either finish it or refund it on its own. Don't retry with a new id, because that
would move it twice. Don't tell the player it failed.

## Cleanup [#cleanup]

Delivered transfer ids sit in the receiver's `_Received` so a redelivery can't pay twice. They're
dropped after 30 days, which is well past the point any retry could still turn up.

`Store:ClearDelivered(Key)` drops the ids that are already past 30 days now, rather than at the next
write of an id to the key. You rarely need it.

`Store:RecoverTransfers(Key)` forces a recovery on one key. The sweeper already does this, so use it
from a support tool, or in a live incident where you want one key dealt with right now.

Both are about money moving between keys, so both require a store that names a `Balance` field. On a
store without one they throw where you called them.

<Callout type="warn">
  `Store:Erase(Key)` first delivers the money the key was still sending. That includes transfers
  between 7 and 8 days old, which recovery has stopped resending while it waits to give them back.
  If a receiver does not take one, `Erase` returns [`Busy`](/docs/concepts/reasons) and changes
  nothing, so call it again later. After an erase, a transfer sent to the key is refused with
  [`Held`](/docs/concepts/reasons), and the sender gets the money back instead of losing it. That
  lasts 8 days, and a write to the key does not end it early. See
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

## Adding it to your project [#adding-it-to-your-project]

roblox-ts only syncs `node_modules/@rbxts` on its own. This package lives under `@xoifail`, so if
you don't tell Rojo about that folder, the require fails at runtime because the module can't be
found. Add one line to `default.project.json`, next to the `@rbxts` one:

```json
"node_modules": {
	"$className": "Folder",
	"@rbxts": { "$path": "node_modules/@rbxts" },
	"@xoifail": { "$path": "node_modules/@xoifail" }
}
```

Then import it in a server script. As in Luau, it throws if a client requires it.

```ts
import Ledger from "@xoifail/ledger";
```

## Calling it [#calling-it]

The declaration knows which methods take a self, so you write dot calls everywhere and the compiler
turns them into colon calls where Ledger needs them. Futures still have `Wait`, and the
`(boolean, Reason?)` every write returns is a tuple you destructure:

```ts
const [ok, why] = session.Apply("SpendGold", { Amount: 25 });
const [state, readWhy] = store.Peek(userId).Wait();
```

`Ledger.Reason` is both the type and the constants, so `why === Ledger.Reason.Busy` works the same
way it does in Luau. In a `switch` over it that handles every reason, the `default` case narrows to
`never`.

The one thing to decide is where the state type comes from. `Ledger.New` reads it off the reducer or
off `Default`, whichever you've annotated. When neither is annotated, pass the type explicitly:

```ts
const Store = Ledger.New<Profile>({ Name: "PlayerData", Default: { Gold: 100 }, Reducer });
```

## Typed ops [#typed-ops]

Typed ops are where the declaration helps most. Name the ops as an interface and give `Ledger.New`
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

const Store = Ledger.New<Profile, Ops>({
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
a type error. Every write is checked against the map, and the type errors are the ones the
[typed ops](/docs/concepts/typed-ops) page lists:

```ts
session.Apply("Buy", { Item: "Sword" });                 // fine
session.Apply("Buy", { Item: "Sword", Once: "order1" }); // fine, Once is allowed on any write
session.Apply("Byu", { Item: "Sword" });                 // no kind by that name
session.Apply("Buy", { Item: 42 });                      // Item is a string
session.Apply("Buy", { Amount: 5 });                     // those are AddGold's fields
store.Reserve(userId, "Items", 1, "order1");             // Items isn't a number field
```

There's one check the Luau side doesn't have. If a kind's fields are not an object type, for example
`Buy: string`, the build fails at `Ledger.New`. Luau ignores it.

On a store built without an `Ops` type, the op's fields all read as `unknown`, so narrow them with
`typeIs` the way the Luau examples use `type()`.

## Frozen state [#frozen-state]

The state your reducer is given is frozen at runtime. `Ledger.Frozen` marks it read only in the type,
at every depth, arrays and maps included. Annotate the state with it, and a write that would throw at
runtime is a type error instead:

```ts
Reducer: (state: Ledger.Frozen<Profile>, op) => {
	state.Items[op.Item] = true; // Index signature in type '{ readonly [x: string]: boolean; }' only permits reading
	return { ...state, Items: { ...state.Items, [op.Item]: true } }; // fine
},
```

## The fields you can't pass [#the-fields-you-cant-pass]

`Id`, `Kind` and `OnceAt` are reserved by Ledger. In Luau, passing one in `Fields` warns and gets
overwritten. In TypeScript it is a type error. `Once` is the one you may pass, and it's allowed on
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

`Wait()` returns the values. `Wait(seconds)` returns nothing if it times out, so in that overload
every value in the pair is optional and the type checker makes you handle `undefined`. The
[Future](/docs/reference/future) page explains why you don't want a timeout on a write anyway.

## `Ledger.Record` and `Ledger.OpMap` [#ledgerrecord-and-ledgeropmap]

`Ledger.Record<D>` is what `Inspect` returns, the same as in Luau. Inside the `Ledger` namespace it
hides TypeScript's built in `Record`, which Ledger's declaration does not use.

`Ledger.OpMap` is the type every op map is checked against. You never write it yourself. If you see
it in an error, one of your kinds isn't naming its fields as an object.

## What isn't checked [#what-isnt-checked]

Which methods a store accepts still depends on its `Keys` option, and that's not in the type.
`Load`, `Get` and the other player methods throw at the call on a string keyed store, and `Bump` and
`Total` throw on a player one, exactly as they do in Luau.


# Future (https://xoifaii.github.io/LedgerDocs/docs/reference/future)



Every Ledger method that touches the datastore returns a `Future` instead of yielding.

```luau
local Job = Store:Peek(UserId)   -- already running
local State = Job:Wait()         -- yields here
```

The work starts when you call the method, not when you call `Wait`. The callback starts at once on
its own thread. `Wait` only yields your thread until the callback finishes.

## Running two at once [#running-two-at-once]

The work starts at the call, so if you start several Futures and then wait, they run at the same
time:

```luau
local A = Store:Peek(FirstUserId)
local B = Store:Peek(SecondUserId)

print(A:Wait().Gold + B:Wait().Gold)
```

Both reads are already running while the first `Wait` yields.
`Store:Peek(First):Wait() + Store:Peek(Second):Wait()` runs the two requests one after the other.

## Wait [#wait]

```luau
Job:Wait(Timeout: number?) -> T...
```

Yields until the callback finishes, then returns what the callback returned. If the callback already
finished, `Wait` returns at once and does not yield. Do not use it to wait for a frame.

Waiting more than once is fine, and so is waiting from several threads.

<Callout type="warn">
  `Wait` returns **no values** if the callback errored or the timeout ran out. Every local you
  assign from it is then `nil`.
</Callout>

Ledger methods return a [reason](/docs/concepts/reasons) instead of throwing, so a failed call
still returns values. A failed `Peek` returns `(nil, Unresolved)`:

```luau
local State, Why = Store:Peek(UserId):Wait()
if State == nil then
	warn(`could not read that profile: {Why}`)
	return
end
```

A timeout returns no values. The first local is then `nil`, so `if Ok then` and
`if State == nil then` still take the failure branch. `Why` is `nil` as well, so a timeout looks the
same as a failure. `Happened` returns `false` for both, so it cannot tell them apart either.

## Timeout [#timeout]

```luau
local Ok, Why = Store:Edit(UserId, "GrantItem", { Item = "Sword" }):Wait(10)
```

After 10 seconds your thread resumes with no values. The work is not cancelled. It keeps running,
and when it finishes a second `Wait` returns its result.

<Callout type="warn">
  Don't put a timeout on a write. A timed out `Wait` returns no values, so the caller treats it as
  a refusal. If it then retries with a new id, the write applies twice. The timeout does not cancel
  the write either. Call `Wait()` with no timeout to get the real result, and read the
  [reason](/docs/concepts/reasons) to see what happened.
</Callout>

## Happened [#happened]

```luau
Job:Happened(Wait: boolean?) -> boolean
```

Whether the callback ran to completion without erroring.

While the callback is still running, `Happened()` returns `false` at once and does not wait. Call it
after you have waited:

```luau
local Job = Store:Peek(UserId)
local State = Job:Wait()

if not Job:Happened() then
	warn("that read failed")
end
```

`Happened(true)` waits for the callback to finish first. Use it when you need to know whether the
call succeeded but do not need its return values:

```luau
local Job = Store:ClearDelivered(UserId)

-- ... do other things while it runs ...

if not Job:Happened(true) then
	warn("that housekeeping pass failed, the next one picks it up")
end
```

`Happened(true)` yields exactly like `Wait` does, so don't call it somewhere that can't yield.

Once the callback has finished, `Happened` tells a callback that returned no values from one that
errored.

<Callout type="warn">
  `Happened` returns whether the callback ran, not whether what you asked for worked. A refused
  `Edit` returns a Future whose callback finished without an error and returned `(false, Refused)`,
  so `Happened()` is `true`. Read the boolean for the outcome, `Happened` for whether there is an
  outcome at all.
</Callout>

`Happened()` returns `false` both while the callback is still running and after it errored. Straight
after a `Wait` that timed out, it can return `false` for a callback that finishes a moment later. If
you used a timeout, use `Happened(true)`. It waits for the callback to finish before it returns.

## Errors don't propagate [#errors-dont-propagate]

A callback that throws is caught. Ledger warns with the error message, `Happened` returns `false`,
and `Wait` returns no values. The error is not thrown again in your thread, so a `pcall` around
`:Wait()` catches nothing.

To make a failed read throw in your own code, check `Happened` and call `error` yourself.

## Not waiting on a Future [#not-waiting-on-a-future]

You don't have to wait at all. The work still runs.

```luau
Store:ClearDelivered(UserId)  -- no :Wait(), still happens
```

This is fine for maintenance calls. Do not do it for a call whose result you act on next, because you
cannot know whether it worked.


# Ledger (https://xoifaii.github.io/LedgerDocs/docs/reference/ledger)



```luau
local Ledger = require(ServerStorage.Ledger)
```

## Ledger.New [#ledgernew]

```luau
Ledger.New<D, O>(Options: TypedConfig<D, O>) -> TypedStore<D, O>
```

Builds a store. Throws when you call it if any option is invalid. Call it as `Ledger.New(Options)`
for a store that takes any op, or as `Ledger.New<<Profile, Ops>>(Options)` for one that checks
every write against your ops. See [Typed stores](#typed-stores).

| Option | Type | |
| --- | --- | --- |
| `Name` | `string` | Required. The datastore name, 1 to 47 characters. |
| `Reducer` | `(State, Op) -> State?` | Required. See [Writing a reducer](/docs/concepts/reducer). |
| `Default` | `D` | Required. The fresh state table. |
| `Balance` | `string?` | Names a number field for [transfers](/docs/guides/transfers). |
| `Migrations` | `{ Migration }?` | See [Migrations](/docs/guides/migrations). |
| `Keys` | `"Player" \| "String"` | `"Player"` keys by UserId, `"String"` by any string. Defaults to `"Player"`. |
| `Shards` | `number?` | How many keys a total is spread over, 1 to 99. Defaults to 16. Only ever raise it. See [Bump](/docs/reference/store#bump). |
| `BumpEvery` | `number?` | How often queued bumps are written, in seconds, up to 60. Leave it out and every `Bump` is one write. See [Bump](/docs/reference/store#bump). |
| `OnLoadFailed` | `((Player, Reason) -> boolean)?` | What to do when a load fails. See below. |
| `Mock` | `boolean \| { Players: number?, CCU: number?, Throttled: boolean? }` | Puts this store on an in memory datastore, with the player count, CCU and throttling you give. See [Testing](/docs/guides/testing). |

The name caps at 47 rather than the datastore's 50 because Ledger also creates `<Name>_Tx` for
transaction markers.

`Default` can't declare any key starting with `_`, and it has to be storable: numbers, strings,
booleans, tables and buffers.

Two stores can't share a name in one server. Call `Store:Destroy()` first if you need to rebuild
one.

### OnLoadFailed [#onloadfailed]

A load that fails kicks the player with "Your data failed to load, please rejoin". `OnLoadFailed`
replaces that kick. It receives the player and the [reason](/docs/concepts/reasons). Return `true`
if you handled the player, and Ledger does nothing more. Return `false` and Ledger kicks them.

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

`Behind` means a newer build wrote the record. A rejoin can put the player on an old server again,
and the load fails again. `Unresolved` is usually a datastore outage, where rejoining is the right
fix.

It can yield, so a teleport works. Every `WaitForLoaded` call for that player returns `nil` before
`OnLoadFailed` runs.

If it throws, Ledger warns and kicks. If it returns `true` and the player is still in the server with
no data, Ledger warns about that too.

Only for `Keys = "Player"` stores. Passing it to a string keyed store makes `Ledger.New` throw.

### Typed stores [#typed-stores]

Give `Ledger.New` your state type and a map of your op kinds, and the store checks every write:

```luau
export type Ops = {
	Buy: { Item: string },
	AddGold: { Amount: number },
}

local Store = Ledger.New<<Profile, Ops>>({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {} },
	Reducer = Reducer,
})
```

`Apply`, `Commit` and `Edit` then check the kind against the ones you named, and the fields against
what that kind carries. Your reducer gets `Ledger.Op<Ops>`, which narrows on `Op.Kind`. At runtime
the store is the same either way. See [Typed ops](/docs/concepts/typed-ops).

## Ledger.Id [#ledgerid]

```luau
Ledger.Id() -> string
```

Creates a short id that is different on every server and on every call. It is the id Ledger puts on
its own ops. Use it for an op you build yourself, a transfer or a transaction. Create it once and
use the same id for every retry.

```luau
local Op = { Id = Ledger.Id(), Kind = "GrantReward", Item = "Sword" }
Store:EditOp(UserId, Op):Wait()
```

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

Runs a sweeper pass now. It finishes unfinished transfers, settles parked transaction legs and
removes old transaction markers. The sweeper does this on its own, so this is for tests and
incidents.

## Ledger.CloseAll [#ledgercloseall]

```luau
Ledger.CloseAll() -> ()
```

Shuts everything down, in this order:

1. Stops the sweeper.
2. For each key, keeps only the newest datastore call that is waiting in the queue. The calls it
   drops return `Closed`.
3. Cuts datastore retries to 2 attempts.
4. Stops every `Follow` timer, writes every queued bump, and saves every live session.
5. Yields until those saves finish.

Call it from `BindToClose`, and put nothing else in that callback.

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
Ledger.Frozen<S>
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

An observer is a stream of values you can subscribe to. Ledger has three:

- `Session:Observe()` pushes the session's new state after every accepted change.
- `Store:Stale()` pushes the keys this server changed, not a state table.
- `Store:Follow()` pushes the state on one key that every server reads.

Everything on this page works on all three.

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

It fires on every accepted change. That includes changes from another server that arrive when a
transfer or transaction settles. It does not fire for a refused op, since nothing changed.

It does not fire on subscribe either. If you need the current value first, call `Session:Get()`
yourself.

## Listeners run inline [#listeners-run-inline]

Your listener is called on the thread doing the write, not on a new thread. This has two results.

It must not yield. No `task.wait`, no `:Wait()`. A listener that yields is stopped with an error,
and Ledger warns. If you need to yield, start the work with `task.spawn` and return.

A listener that throws is caught, Ledger warns, and the other listeners still run.

Listeners are called over a snapshot of the list, so subscribing or disconnecting from inside a
listener is safe and takes effect on the next push rather than partway through this one.

### Listeners that may yield [#listeners-that-may-yield]

`Store:Stale()` is the one stream that does not work this way. Ledger calls each of its listeners on
a new thread, so they can yield. A `Flush` or a `PublishAsync` inside one is fine.

Ledger warns when a listener runs for 10 seconds without returning. Every pushed key holds a thread
until its listener returns, so a listener that never returns leaks one thread per write.

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
chain. The first subscriber connects the chain to its source. When the last subscriber disconnects,
the chain disconnects from its source.

So a chain that nobody subscribes to does no work. A chain whose subscribers have all disconnected
stops listening to its source.

## Cleaning up [#cleaning-up]

Nothing disconnects your listeners for you. The session does not clear its observers when the player
leaves. It only stops pushing to them, so they stay connected and never fire again.

You usually do not need to disconnect them. Ledger drops the session when the player leaves. If you
did not keep the connection anywhere, it is garbage collected with the session.

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

Disconnects every listener and disconnects the observer from its source.

<Callout type="warn">
  Don't call this on `Session:Observe()`. It returns the session's own stream, not a copy, so
  destroying it stops change notifications for every other subscriber on that session. Destroy your
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

Fires on every accepted change. That includes changes from another server that arrive when a
transfer or transaction settles. Doesn't fire for a refused op.

```luau
Session:Observe():Subscribe(function(State)
	UpdateHud(Player, State)
end)
```

This is the session's own stream, not a copy, so `Session:Observe() == Session:Observe()`. Don't
call `Destroy` on it. That removes every subscriber, Ledger's own included. See
[Observer](/docs/reference/observer) for the chain methods and cleanup.

### DidApply [#didapply]

```luau
Session:DidApply(Id: string) -> boolean
```

Whether a [`Once`](/docs/concepts/once) name ever applied on this key. Reads live state, so it
doesn't yield.

<Callout type="warn">
  Live state includes the ops that wait for the next save. After `Apply` queues an op with a
  `Once` name, `DidApply` returns `true` before the op is saved. It tells you the name applied, not
  that it is saved. To know it is saved, use `Commit`, or `Apply` and then `Flush`.
</Callout>

## Writing [#writing]

### Apply [#apply]

```luau
Session:Apply(Kind: string, Fields: { [any]: any }?) -> (boolean, Reason?)
```

Instant and local. Runs the reducer, updates state, pushes to observers, and queues the op for the
next save. Never touches the datastore.

Use it for gameplay. See [Apply and Commit](/docs/concepts/apply-and-commit).

On a session from a [typed store](/docs/concepts/typed-ops) the `Kind` and the `Fields` are checked
against the ops you named. `Commit` and `CommitOp` are checked the same way.

### Commit [#commit]

```luau
Session:Commit(Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>
```

Writes everything queued, appends the op, waits for the datastore, folds the record again, then
returns. `true` means the op is applied and saved.

If the log is full, `Commit` compacts it once and tries again. It returns `Full` if the log is still
full.

When a transaction is parked on the key, `Commit` waits up to 65 seconds for it to settle. If it is
still parked and could change whether the op applies, `Commit` returns `Unresolved`. With two or
more transactions parked it always does, because it cannot check every way they can settle.

The op is already written, so don't call `Commit` again: that writes a second op with a new id.
Read the key once the transaction settles, or use `CommitOp` with your own `Id`, which is safe to
retry.

Use it for any change you cannot undo.

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

`IdAt` is optional. It is the time you first sent an op whose `Id` you chose, in Unix seconds as
`os.time()` returns it. Send the same value on every retry. A key keeps the ids of its last 2048
compacted ops. If the key has dropped ids that were compacted after `IdAt`, it cannot tell whether
your op applied. The commit then returns `Unresolved`, applies nothing and warns. An `IdAt` that is
not a number returns `Invalid`. A time later than now counts as now.

`Id`, `Kind` and `OnceAt` belong to Ledger. If you pass them in `Fields` to `Apply` or `Commit`,
Ledger warns and overwrites them. `Apply` and `Commit` make a new id on every call, so Ledger warns
and drops an `IdAt` passed to them.

## Saving [#saving]

### Flush [#flush]

```luau
Session:Flush() -> Future<boolean, Reason?>
```

Writes queued ops without adding one. Autosave calls this. `false` comes with a
[reason](/docs/concepts/reasons) and the ops stay queued for next time.

### Compact [#compact]

```luau
Session:Compact() -> Future<boolean, Reason?>
```

Folds the logged ops into a new snapshot and removes the compacted ops from the log. Autosave does
this when the log gets long, so you rarely need it.

### Release [#release]

```luau
Session:Release() -> Future<boolean, Reason?>
```

Marks the session closed and writes what is left. `Apply`, `Commit` and `CommitOp` then return
[`Closed`](/docs/concepts/reasons). `Flush` still works, because it adds no op.

Use `Store:Unload` instead. `Release` closes the session and tells the store nothing, so `IsLoaded`
stays `true`, `Get` still returns the closed session, and the autosave timer keeps running.
`Unload` closes the session and also removes it from the store.


# Store (https://xoifaii.github.io/LedgerDocs/docs/reference/store)



A store owns one datastore name, every key under it, and every session live on this server.

A method marked "Player only" throws when you call it on a string keyed store.

## Sessions [#sessions]

### Load [#load]

```luau
Store:Load(Player: Player) -> ()
```

Player only. Yields while it reads and folds the record, then starts a 30 second autosave. Kicks the
player if the load fails.

Calling it twice for the same player warns and does nothing. If the player leaves during the load,
Ledger releases the session and does not keep it.

### Unload [#unload]

```luau
Store:Unload(Player: Player) -> ()
```

Player only. Cancels the autosave, writes queued ops, and yields until they are saved.

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

Player only. Yields until the session exists. Returns `nil` if the player left first. Use it in
`ProcessReceipt`.

### Read [#read]

```luau
Store:Read(Player: Player) -> D?
```

Player only. The state table, or `nil` if the player is not loaded. Same as
`Store:Get(Player):Get()`.

## Reading any key [#reading-any-key]

### Peek [#peek]

```luau
Store:Peek(Key: KeyLike, MaxAge: number?) -> Future<D?, Reason?>
```

Reads the record and folds it. It works for any key, whether the player is on this server, on
another server, or offline. Without `MaxAge` there is no cache. Each call costs one request.

With `MaxAge`, `Peek` returns a copy of the key instead. There are two copies:

- This server's own copy. While it is younger than `MaxAge` seconds, `Peek` returns it and makes no
  request.
- A copy in MemoryStore that every server reads. When this server's copy is older than `MaxAge`,
  `Peek` reads the shared copy for one request unit.

The shared copy goes stale after 60 to 75 seconds. Each server picks its own limit in that range.
One server then reads the record and writes the shared copy again. The other servers return the old
copy until it has.

A `MaxAge` of 0 reads the record now. If many servers ask at the same time, only one of them reads
the record. The copy holds your fields only. Ledger's own fields, such as `_Received` and `_Held`,
are not on it. `Peek` with a `MaxAge` works on string keyed stores only. See
[Following a key](/docs/guides/entity-stores#following-a-key).

A key nobody has written folds to your `Default`. `nil` always means the read failed, and the reason
tells you why. `Behind` means a newer build wrote the key. On any other reason, try again.

### DidApply [#didapply]

```luau
Store:DidApply(Key: KeyLike, Id: string) -> Future<boolean?, Reason?>
```

Whether a [`Once`](/docs/concepts/once) name ever applied on that key.

`nil` means it could not read the record, which is not the same as `false`. Compare against `true`.
If you only test truthiness, a failed read looks like "never granted" and you grant twice.

### History [#history]

```luau
Store:History(Key: KeyLike, Limit: number?) -> Future<{ HistoryEntry }?, Reason?>
```

Up to 30 days of versions, newest first, one per UTC hour the key was written in. `Limit` is
clamped to 1 through 100 and defaults to 25.
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

Appends one op to any key and waits for the result. Works whether or not the target is online.

If the key has a live session on this server, `Edit` still goes through the log, so the session picks
it up on its next fold.

Can return `Unresolved` when a parked transaction leg on the key could change whether the op is
accepted. An edit that leg cannot affect returns at once.

On a [typed store](/docs/concepts/typed-ops) the `Kind` is checked against the kinds you named, and
the `Fields` against what that kind carries.

`Edit` makes a new id on every call, so Ledger warns and drops an `IdAt` in `Fields`.

### EditOp [#editop]

```luau
Store:EditOp(Key: KeyLike, Op: Op) -> Future<boolean, Reason?>
```

Appends an op you built yourself, with your own `Id`. The same op sent again applies only once. Use
it to retry an edit that returned `Unresolved`. `Edit` creates a new id on every call. A retried
`Edit` can apply twice.

Create the id with [`Ledger.Id`](/docs/reference/ledger#ledgerid) and keep it for the retry. An op
needs a string `Id` and a string `Kind`. `Invalid` is returned when either is missing, or when a
field cannot be stored. Ledger copies the op. The table you pass is never changed.

```luau
local Op = { Id = Ledger.Id(), Kind = "Archive", Line = Line }
local Ok, Why = Store:EditOp("journal", Op):Wait()
if not Ok and Why == Ledger.Reason.Unresolved then
	Ok, Why = Store:EditOp("journal", Op):Wait()
end
```

A retry after the key has compacted the op returns `Unresolved`. The op is in the snapshot by then,
and the record cannot say whether that id was applied.

A key keeps the ids of its last 2048 compacted ops. After it drops the id, a retry applies the op
again. To stop that, set `IdAt` on the op. `IdAt` is the time you first sent the op, in Unix
seconds as `os.time()` returns it. Send the same value on every retry. If the key has dropped ids
that were compacted after `IdAt`, the write returns `Unresolved`, applies nothing and warns. An
`IdAt` that is not a number returns `Invalid`. A time later than now counts as now.

On a typed store the op is checked against the kinds you named.

### Transfer [#transfer]

```luau
Store:Transfer(From: KeyLike, To: KeyLike, Amount: number, Id: string?, Field: string?) -> Future<boolean, Reason?>
```

Moves `Amount` of a number field from one key to another. `Field` names it, and has to be a number
field your `Default` declares. Leave it out to move the `Balance` field, which needs the store to
name one.

`From` and `To` have to be different. `Amount` has to be positive and finite. `Id` is 1 to 64
characters when given, and giving one makes a retry safe. An `Id` belongs to one transfer. The same
`Id` with a different field, amount or pair of keys returns [`Spent`](/docs/concepts/reasons).

A delivery into a key that was erased returns [`Held`](/docs/concepts/reasons). The amount has
already left the sender. It stays set aside on the sender's key until recovery refunds it.

See [Transfers](/docs/guides/transfers).

### Reserve [#reserve]

```luau
Store:Reserve(Key: KeyLike, Field: string, Amount: number, Id: string, Options: {
	Hold: number?
}?) -> Future<boolean, Reason?>
```

Holds `Amount` of a number field on one key, under `Id`, in MemoryStore. The key itself
does not change: `Peek` shows the full field, and `Holds` shows what is held. `Field` has to name a
number field your `Default` declares. `Id` is 1 to 64 characters.

On a [typed store](/docs/concepts/typed-ops) that rule is checked, so a `Field` that isn't a number
field of your state is a type error. `Bump`, `Total`, `Holds` and
`Transfer` take the same check.

Asking again under an `Id` already held returns `true` and holds nothing extra. After a hold is
confirmed, released or runs out, its `Id` can be used again.

Asking for more than the field has, counting what is already held, returns `Refused`. A key can
have at most 256 holds at once. Asking for another returns `Busy`. A hold runs out in 15 minutes or
less, so ask again later. A hold is checked against the last value Ledger read from the key. Before
it returns `Refused`, Ledger reads the key again, so a restock is counted.

`Hold` is how long to keep it, in seconds. The cap and the default are both 15 minutes, so `Hold`
can only shorten a hold. A `Hold` above the cap throws where you wrote the call. Reserve again under
the same `Id` to extend a hold. A hold that nobody confirms runs out on its own. There is nothing to
refund, because the key never changed.

A hold is not part of the key's state. An `Edit` can spend units another player holds, and that
player's `Confirm` then returns `Refused`. Nothing is oversold. One checkout fails.

MemoryStore has to be reachable. In Studio that means API access is on. A store with no MemoryStore,
or one whose MemoryStore is down, returns [`Unresolved`](/docs/concepts/reasons) and holds nothing.
The reducer still refuses at checkout, so a lost hold can cause a refused checkout but never an
oversell.

The first hold on a key costs one datastore read and four MemoryStore request units. Every hold after
that costs two units, and a `Release` costs two.

See [Reservations](/docs/guides/reservations).

### Holds [#holds]

```luau
Store:Holds(Key: KeyLike, Field: string) -> Future<number?, Reason?>
```

Returns how many units of `Field` are held on `Key` right now. A key nothing holds returns `0`.
Costs one MemoryStore request unit.

`nil` and [`Unresolved`](/docs/concepts/reasons) mean the MemoryStore could not be read, never that
nothing is held.

### Confirm [#confirm]

```luau
Store:Confirm(Key: KeyLike, Id: string, Kind: string, Fields: table?) -> Future<boolean, Reason?>
```

Spends what `Id` holds, with your own op. `Kind` and `Fields` are what you would give `Edit`, so your
reducer decides what a checkout takes off the key and refuses one the field cannot cover. The op's id
comes from `Id`, so a retry applies only once. The hold is released after the op is applied.

A confirm needs no hold. The reducer decides whether the checkout is accepted, with or without a
hold. A checkout whose hold ran out, or was never made because the MemoryStore was down, still sells
what is there.

On a [typed store](/docs/concepts/typed-ops) `Kind` and `Fields` are checked the way `Edit` checks
them.

The key keeps the op's id while the op is in the log, and for the next 2048 ops it compacts. A
confirm replayed inside that window spends nothing more. Once the op is compacted into the snapshot,
the reply is [`Unresolved`](/docs/concepts/reasons). The record cannot say whether that op was
applied or refused.

`Fields` can carry an `IdAt`, the same as on [`EditOp`](#editop). It is the time you first sent the
confirm, in Unix seconds. Send the same value on every retry. If the key has dropped ids that were
compacted after `IdAt`, a replay returns `Unresolved`, sells nothing and warns. Without `IdAt`, a
replay after the key drops the id sells the units again.

`Fields` can carry a [`Once`](/docs/concepts/once). A confirm with a `Once` name that is replayed
after the key drops its id returns `Refused`, and `DidApply` returns `true` for 30 days. A name adds
40 bytes to the key for 30 days. A key that sells 1,700 units a day fills its state with names in a
month. Give a confirm a `Once` only when you need a lasting answer from `DidApply`. Put the `Once`
for the grant on the player's key.

Costs one datastore request and two MemoryStore request units.

### Release [#release]

```luau
Store:Release(Key: KeyLike, Id: string) -> Future<boolean, Reason?>
```

Releases what `Id` holds. Nothing on the key changes, because nothing was taken.

Returns `Refused` when nothing is held under that `Id`, and [`Unresolved`](/docs/concepts/reasons)
when the MemoryStore could not be read to find out. Costs two MemoryStore request units.

### Bump [#bump]

```luau
Store:Bump(Name: string, Field: string, Amount: number) -> Future<boolean, Reason?>
```

String keyed stores only. Adds `Amount` to a total spread over 16 keys, named `<Name>#0` to
`<Name>#15`. Each server writes its own shard, so servers do not queue behind each other on one key.
`Shards` on the config sets the count, 1 to 99. Only ever raise it on a live store. With a lower
count Ledger stops reading the highest shards, so the amounts in them drop out of every total.
During the deploy that raises it, an old server sums only the shards it knows. Its totals are short
until that server stops. The cached sum is kept per shard count, so a new server caches its own sum
over every shard and never reads an old server's short one.

`Amount` has to be positive. A total is spread over keys that cannot see each other, so nothing can
be taken back out of one. Anything with a limit belongs on a single key, where `Reserve` can hold it.

A store built with `BumpEvery` queues its bumps. Every `BumpEvery` seconds the server writes one
op per total with the sum of its queued bumps. `Bump` then returns one Future shared by every bump
of that total in the window. If you wait on it, it returns once the window is saved, the same as
`Commit`. If you do not wait, the bump is not saved yet, the same as `Apply`. `Destroy` and
`CloseAll` write what is queued. A server that crashes loses the bumps of its last window. Your own
server's totals show a queued bump immediately.

### Total [#total]

```luau
Store:Total(Name: string, Field: string, MaxAge: number?) -> Future<number?, Reason?>
```

Returns the sum cached in MemoryStore, for one request unit. The cached sum goes stale after 60 to
75 seconds. Each server picks its own limit in that range. One server then reads every shard and
caches the sum again. The other servers return the old sum until then. A total from another server
is at most 90 seconds behind, plus the time one refill takes. Your own server's bumps show in its
totals immediately.

With `MaxAge`, `Total` returns this server's own last sum and makes no request while that sum is
younger than `MaxAge` seconds. A total read every five seconds makes no requests between refills.

It returns what has been added, not what the keys hold. Each shard starts at the value
your `Default` gives the field. That baseline is taken off the sum. A total nobody has added to
reads 0 for any `Default`.

MemoryStore has to be reachable. In Studio that means API access is on. A store with no MemoryStore,
or whose MemoryStore is down, reads every shard each time and returns the same sum. Ledger warns
once when this happens.

### Tx [#tx]

```luau
Store:Tx(Id: string, Legs: { TxLeg }) -> Future<boolean, Reason?>
```

Commits 2 to 4 legs all or nothing. `Id` comes first and is required, 1 to 50 characters, and has to
be stable across retries. Running the same id again returns `true` and moves nothing.

A malformed leg throws. That covers a bad key, a key used twice, and a `Once` on a leg. `Fields`
that cannot be stored return [`Invalid`](/docs/concepts/reasons) instead, the same as `Edit`, and
nothing is prepared.

Before it writes any leg, a transaction leases each of its keys in MemoryStore for ten seconds. If
another server already holds a lease on one of those keys, `Tx` returns `Busy` at once. That costs
one request unit and no datastore requests. Without the lease, the second server would find the same
`Busy` after eight requests.

The lease only decides which server tries first. The transaction marker still decides the outcome.
No server waits for another. A server that cannot reach MemoryStore runs the transaction without
leases. A lease that is never released makes `Tx` return `Busy` for at most ten seconds. A two leg
transaction spends 8 request units on its leases.

See [Transactions](/docs/guides/transactions).

### Reset [#reset]

```luau
Store:Reset(Key: KeyLike) -> Future<boolean, Reason?>
```

Puts the key back to `Default`, keeping `_Received` and `_Held`. A record written at a version this
server doesn't know returns [`Behind`](/docs/concepts/reasons), not `Refused`. Nothing refused the
write. This server cannot read what is on the key.

A key with a transaction parked on it returns [`Busy`](/docs/concepts/reasons). Resetting it would
throw away a leg the transaction still counts as committed. Settle it with `Resettle` first.

### Inspect [#inspect]

```luau
Store:Inspect(Key: KeyLike) -> Future<Record?, Reason?>
```

The record itself rather than the state it folds to: the snapshot, the ops not yet compacted into it,
the applied ids, and the version. `Peek` returns the folded state. `Inspect` returns the stored
record.

```luau
local Record = Store:Inspect(UserId):Wait()
if Record then
	print(`{#Record.Ops} op(s) waiting on top of the snapshot`)
	for _, Op in Record.Ops do
		print(Op.Id, Op.Kind)
	end
end
```

What it returns is frozen, like everything else Ledger returns. To change a key, use `Edit`,
`Reset` or `Erase`.

### Erase [#erase]

```luau
Store:Erase(Key: KeyLike) -> Future<boolean, Reason?>
```

Throws the record away and leaves a tombstone. First, Ledger delivers any transfer the key is still
sending. If it cannot deliver one, `Erase` returns [`Busy`](/docs/concepts/reasons) and changes
nothing. Call it again later. A transfer that cannot be delivered is refunded once it is 8 days
old, so an `Erase` after that goes through. For 8 days the tombstone refuses transfers sent to the
key, and each one goes back to its sender.
See [Erase](/docs/guides/recovery#erase).

The tombstone lasts the full 8 days, even if the key is written to again. An `Edit` to the key in
that time is written and does not remove the tombstone. A session that loaded the key before the
erase cannot save to it. On its next save, the server that holds the session warns and closes it.
Its unsaved ops are not written, `Apply` and `Commit` then return `Closed`, and `Flush` returns
`Refused`. Get the player off every server before you erase them.

An `Erase` that finds a tombstone that has run out removes the key from the datastore. For up to 2
minutes while it does, a write to the key returns `Busy`. If the key still holds `Once` names or
transfer and transaction ids from the last 30 days, Ledger keeps the record and warns. Erase it again
after they run out. A write after the tombstone runs out clears it, and the next `Erase` leaves a new
tombstone.

A key with a transaction parked on it returns [`Busy`](/docs/concepts/reasons), the same as `Reset`.

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

| method | what it pushes |
| --- | --- |
| `Edit`, `Confirm`, `Bump`, `Reset` | the key it wrote |
| `Transfer` | both keys |
| `Tx` | every leg key, onto that leg's own store |

Nothing else pushes. A write the reducer refuses pushes nothing, and so does a read, an `Erase` and
every maintenance method.

`Session:Apply` and `Session:Commit` push nothing either. That session already holds the change.

The key is a string. A player store keys on the `UserId`, so call `tonumber` on it before you look
the player up.

Listeners on this stream run on their own thread and may yield, which the ones on
`Session:Observe()` may not. See [Observer](/docs/reference/observer#listeners-that-may-yield).

Use it to flush a session the moment another part of your game writes to its key. See
[Transactions](/docs/guides/transactions#a-live-session-does-not-know-a-leg-wrote-to-it).

### Follow [#follow]

```luau
Store:Follow(Key: KeyLike) -> Observer<D>
```

A stream of the state on one key. You subscribe once, and Ledger keeps the value current from the
shared copy. Ledger reads the shared copy on a timer. The timer starts at 30 seconds. Each time the
key has not changed, the interval doubles, up to 4 minutes. When the key changes, it goes back to
30 seconds. Ledger pushes the state only when it changed. The first read pushes the state as it is.
Subscribing pushes nothing, so call `Peek` with a `MaxAge` for the current value.

```luau
Settings:Follow("config"):Subscribe(function(Config)
	Apply(Config)
end)
```

The timer starts with the first listener. It stops when the last listener disconnects. `Destroy`
stops it too. A write on this server shows on this server's stream immediately. A write on another
server shows after the shared copy is refilled and this server reads it on its timer. That takes at
most 75 seconds plus one interval. To show it sooner, the writing server can send the key over
`MessagingService`, and the receiver calls `Peek(Key, 0)`. Calling `Follow` again with the same key
returns the same observer. `Follow` works on string keyed stores only. See
[Following a key](/docs/guides/entity-stores#following-a-key).

Listeners run inline and must not yield, the same as `Session:Observe()`. See
[Observer](/docs/reference/observer#listeners-run-inline).

## Maintenance [#maintenance]

### Resettle [#resettle]

```luau
Store:Resettle(Key: KeyLike) -> Future<boolean, Reason?>
```

Settles any transaction leg parked on the key and finishes any unfinished transfer on it. `true`
means nothing is left unfinished. `Busy` means a leg is still waiting on a decision, so try again
later.

The sweeper calls this for you every minute. Call it yourself when the sweeper warns that it is
already tracking 256 keys, or that it stopped retrying a key after five attempts.

### RecoverTransfers [#recovertransfers]

```luau
Store:RecoverTransfers(Key: KeyLike) -> Future<boolean, Reason?>
```

Makes the unfinished transfers on one key finish or refund now. The sweeper already does this, so it
is for support tools.

### ClearDelivered [#cleardelivered]

```luau
Store:ClearDelivered(Key: KeyLike) -> Future<boolean, Reason?>
```

Drops delivered transfer ids older than 30 days from the key. Ledger also does this on its own.

Both this and `RecoverTransfers` work on any store, since a transfer can move any number field.

### Destroy [#destroy]

```luau
Store:Destroy() -> ()
```

Saves every live session, frees the name, and takes the store out of the registry. Every method
throws afterwards.


# Types (https://xoifaii.github.io/LedgerDocs/docs/reference/types)



Everything here is exported from the top level module, as `Ledger.Op`, `Ledger.Store` and so on.

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

`Id`, `Kind` and `OnceAt` are reserved. If you pass any of them in `Fields`, Ledger warns and
overwrites them.

`Once` is yours to set, and it's what makes the op apply at most one time on that key. See
[Once](/docs/concepts/once).

## OpOf [#opof]

```luau
type OpOf<O, K> = { Id: string, Kind: K } & index<O, K>
```

The op type for one kind in your op map. Use it to type a function that handles a single kind.

```luau
local function SpendGold(State: Profile, Op: Ledger.OpOf<Ops, "SpendGold">): Profile?
	local Next = table.clone(State)
	Next.Gold -= Op.Amount
	return Next
end
```

For a table of handlers, one per kind, see [Advanced reducers](/docs/concepts/advanced-reducers#one-handler-per-op-kind).

## Reducer [#reducer]

```luau
type Reducer<S, O = any> = (State: S, Op: Op<O>) -> (S | Frozen<S>)?
```

See [Writing a reducer](/docs/concepts/reducer).

## Frozen [#frozen]

```luau
type Frozen<S>
```

Your state with every field read only, at every depth. At runtime, the state Ledger passes you is
already frozen this way. Annotate a reducer's state with it, and a write into a nested table is a
type error:

```luau
type Hero = { Gold: number, Stats: { Level: number } }

Reducer = function(State: Ledger.Frozen<Hero>, Op)
	local Next = table.clone(State)
	Next.Stats.Level += 1 -- Property Level of table '{ read Level: number }' is read-only
	return Next
end,
```

An array or a map stays writable in the type, and so does what it holds, because Luau can't make an
indexer read only yet. A write into one still throws at runtime. In TypeScript `Ledger.Frozen`
covers arrays and maps as well.

## Reason [#reason]

```luau
type Reason =
	"Refused" | "Busy" | "Spent" | "Unresolved" | "Closed"
	| "Backlog" | "Full" | "Invalid" | "Behind" | "Held"
```

Compare against the `Ledger.Reason` constants, such as `Ledger.Reason.Refused`, not the string
literals. See [Reasons](/docs/concepts/reasons).

Every method that can fail returns `(value?, Reason?)` or `(boolean, Reason?)`.

## KeyLike [#keylike]

```luau
type KeyLike = number | string
```

A UserId on a player store, a key string on a string keyed store. If the key does not fit the store,
Ledger throws, and the error message names what the store expects.

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

The options of a store that takes any op. See [Ledger.New](/docs/reference/ledger#ledgernew).

## TypedConfig [#typedconfig]

```luau
type TypedConfig<D, O> = {
	read Name: string,
	read Reducer: (State: D, Op: Op<O>) -> unknown,
	read Default: D,
	read Balance: string?,
	read Migrations: { Migration }?,
	read Keys: KeysMode?,
	read OnLoadFailed: ((Player: Player, Why: Reason) -> boolean)?,
}
```

What `Ledger.New` takes. The reducer gets the op as one of the kinds you named. Annotate its return
as your state or `nil` to have that checked. See [Typed ops](/docs/concepts/typed-ops).

## TypedStore and TypedSession [#typedstore-and-typedsession]

```luau
type TypedStore<D, O>
type TypedSession<S, O>
```

`TypedStore` is what `Ledger.New<<Profile, Ops>>` returns. `TypedSession` is what `Store:Expect`
returns on a typed store. They have the same methods as `Store<D>` and `Session<S>`, with `Apply`,
`Commit` and `Edit` checked against the ops you named.

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
	Removing: number?,
	Horizon: number?,
	Absorbed: { { At: number, Count: number } }?,
}
```

What [`Store:Inspect`](/docs/reference/store#inspect) returns. It is a frozen copy. To change the
key, use `Edit`, `Reset` or `Erase`.

`Erased` is when the key was last erased. `Removing` is set while a second erase removes the key.
`Horizon` is the time of the newest compaction whose ids the key has dropped, or of the last erase.
An op whose `IdAt` is earlier than `Horizon` is not written. `Absorbed` counts how many ids each
compaction added to `Seen`, and when.

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

`At` is Unix seconds. `Version` is what you give to `PeekVersion`.

## Future [#future]

What every method that touches the datastore returns. The work starts at the call. `:Wait()`
yields your thread until the work finishes.

```luau
local Job = Store:Peek(UserId)
DoSomethingElse()
local State = Job:Wait()
```

Ledger methods return a reason instead of throwing inside the Future, so `Wait` returns values. The
exception is a `Wait` with a timeout that runs out. It returns no values.

See [Future](/docs/reference/future) for timeouts, error handling, and why a failed read returns
`nil`.

## Observer [#observer]

What `Session:Observe()`, `Store:Stale()` and `Store:Follow()` return. Subscribe to get every
accepted change, and chain with `Map`, `Filter`, `Changed` and `Use`.

```luau
Session:Observe():Subscribe(function(State)
	UpdateHud(Player, State)
end)
```

See [Observer](/docs/reference/observer).

## Typing your own state [#typing-your-own-state]

Write the state type and the ops yourself and give both to `New`:

```luau
export type Profile = {
	Gold: number,
	Items: { string },
}

export type Ops = {
	AddGold: { Amount: number },
	PickUp: { Item: string },
}

local function Reducer(State: Profile, Op: Ledger.Op<Ops>): Profile?
	-- ...
end

local Store: Ledger.TypedStore<Profile, Ops> = Ledger.New<<Profile, Ops>>({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {} },
	Reducer = Reducer,
})
```

A store built without `Ops` is annotated `Ledger.Store<Profile>`.

`Session:Get()` then returns a `Profile`, and the reserved fields stay out of your type. They exist
at runtime, and `table.clone` in your reducer copies them. You don't have to declare them.
