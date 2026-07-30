# API reference

## Module

```luau
Ledger.New(Options) -> Store   -- build a store, once, before anyone joins
Ledger.CloseAll()              -- flush and release every store, from BindToClose
Ledger.Sweep()                 -- settle stranded transaction legs now, not on the next tick

Ledger.UseMock(Options?) -> Service  -- swap every store onto an in memory datastore
Ledger.UseReal()                     -- swap back to the real one
Ledger.UseClock(Reads?)              -- swap the clock Ledger stamps with, nil puts os.time back
```

```luau
local Store = Ledger.New({
	Name = "PlayerData",       -- datastore name, 1 to 47 characters
	Reducer = Reducer,         -- (State, Op) -> State?
	Default = { Gold = 100 },  -- a fresh record's state

	Balance = "Gold",          -- optional, the numeric field Transfer moves
	Migrations = { ... },      -- optional, ordered shape changes
	Keys = "Player",           -- optional, "Player" (default) or "String"
})
```

`New` throws on anything malformed. `Keys = "String"` makes an entity store.

## Running without a datastore

`UseMock` points every store at an in memory datastore, so saves work with no API access and nothing
outlives the server. Useful in Studio, in a test place, or in CI.

```luau
Ledger.UseMock()                            -- solo, an empty server
Ledger.UseMock({ Players = 30 })            -- budgets sized as if 30 players were on
Ledger.UseMock({ Throttled = false })       -- lift the budget and per key throughput limits
Ledger.UseReal()                            -- back to the real datastore
```

Order does not matter, the swap is read per operation, so it works before or after `Ledger.New`.
Every store built while the mock is on warns that nothing it saves will outlive the server, which is
how you can tell at a glance that a place is not talking to the real thing.

**It is deliberately stricter than Studio.** Studio reports far larger budgets than a live server
ever gets, which is exactly how budget bugs reach production. The mock follows the documented live
limits instead: `60 + players * 40` reads and writes per minute, `5 + players * 2` lists, 4 MB per
minute written per key, 25 MB read, a 4 MB value cap and 50 character names and keys. `Throttled =
false` turns the budget and throughput parts off when you only want the storage.

`UseClock` swaps the clock Ledger stamps transfers and transaction markers with, so a test can age a
hold by days without waiting:

```luau
local Now = os.time()
Ledger.UseClock(function(): number
    return Now
end)
Now += 8 * 86400   -- everything Ledger stamps now looks eight days old
Ledger.UseClock()  -- back to os.time
```

Anything that installs a clock must put it back, or a later run keeps the frozen one.

## Player lifecycle

```luau
Store:Load(Player)                      -- folds a session, starts autosave, kicks on failure
Store:Unload(Player)                    -- final save and release
Store:Get(Player) -> Session?           -- nil if not loaded
Store:Expect(Player) -> Session         -- throws if not loaded
Store:IsLoaded(Player) -> boolean
Store:WaitForLoaded(Player) -> Session? -- yields, nil if they leave first
Store:Read(Player) -> State?
```

## Session

```luau
Session:Get() -> State
Session:Apply(Kind, Fields?) -> (boolean, Reason?)         -- local, saved on the next flush
Session:Commit(Kind, Fields?) -> Future<boolean, Reason?>  -- durable before it answers
Session:CommitOp(Op) -> Future<boolean, Reason?>           -- Commit for an op whose Id you own
Session:Flush() -> Future<boolean>
Session:Compact() -> Future<boolean>
Session:Release() -> Future<boolean>
Session:Observe() -> Observer<State>
Session:DidApply(Name) -> boolean                          -- has an op named Once ever landed here

Session.LogSize   -- ops since the last snapshot
Session.LogBytes  -- their measured size
```

## Any key

Online, elsewhere, or offline. A UserId on a player store, a string on an entity store.

```luau
Store:Peek(Key) -> Future<State>
Store:Edit(Key, Kind, Fields?) -> Future<boolean, Reason?>
Store:DidApply(Key, Name) -> Future<boolean>               -- has an op named Once ever landed here
Store:Transfer(From, To, Amount, Id?) -> Future<boolean, Reason?>
Store:Tx(Id, Legs) -> Future<boolean, Reason?>             -- atomic across 2 to 4 keys

Store:History(Key, Limit?) -> Future<{ Entry }>            -- 30 day version list, newest first
Store:PeekVersion(Key, Version) -> Future<State>

Store:RecoverTransfers(Key) -> Future<()>
Store:ClearDelivered(Key) -> Future<()>                    -- drop delivered transfer ids, a last resort
Store:Reset(Key) -> Future<boolean, Reason?>
Store:Erase(Key) -> Future<()>
```

## Once

An op named `Once` lands **at most one time on that key, ever**, however often it is replayed. Use it
whenever something outside Ledger owns the id: a receipt, a webhook, an order, a support grant.

```luau
Session:Commit("ProductGrant", { ProductId = 123, Once = `receipt:{PurchaseId}` }):Wait()
Store:Edit(UserId, "ProductGrant", { ProductId = 123, Once = `order:{OrderId}` }):Wait()
```

A replay is **refused**, so it changes nothing and answers `false` with `Refused`. That is not the
same as failing, and it is the distinction that matters:

```luau
Store:Edit(Key, "Grant", { Amount = 500, Once = "order:42" }):Wait()   -- true,  granted
Store:Edit(Key, "Grant", { Amount = 500, Once = "order:42" }):Wait()   -- false, already granted
Store:DidApply(Key, "order:42"):Wait()                                 -- true, both times
```

**Ask `DidApply`, never the write's answer.** "Did this write change anything" and "has this name ever
landed" are different questions, and for anything you have to report back, the second is the one you
mean.

The name is remembered in the profile's own state, so it survives a compaction, a rejoin, and a
different server. If two servers replay the same name at once, one applies and both see `DidApply`.

A name is only remembered when the reducer **accepted** the op. A refused grant does not burn the
name, so it can be retried later once the state allows it.

Names age out after 30 days, the same horizon as delivered transfers. `ClearDelivered` does not touch
them.

`Once` belongs on ordinary ops. A `Tx` leg refuses it, because the transaction `Id` already makes
every leg land at most once.

## Retiring a store

```luau
Store:Destroy()   -- release the name, stop sweeping it, save any live sessions
```

Most games build their stores once and never destroy one. `Destroy` exists for the cases where a
store outlives its usefulness inside a running server: tests that build a store per case, and tools
that swap a store out without restarting.

It saves and releases every live session, wakes anyone waiting in `WaitForLoaded` with `nil`, drops
the store from the recovery sweep, and frees both `Name` and `Name_Tx` so `Ledger.New` can claim
them again. It yields until those saves finish, and calling it twice is harmless.

Afterwards the store is closed: every call throws rather than silently going unswept.

```luau
Store:Destroy()
Store:Peek(Key)   -- throws, "Peek was called on 'PlayerData' after it was destroyed"
```

Destroying a store does **not** touch what is stored. The records stay exactly where they are, and a
new store built on the same name reads them back.

A `Tx` leg carries `UserId` on a player store or `Key` on an entity store, and may name a
different `Store`:

```luau
Store:Tx(`deposit:{DepositId}`, {
	{ UserId = Jack, Kind = "SpendGold", Fields = { Amount = 100 } },
	{ Store = Clans, Key = "sunreavers", Kind = "Deposit", Fields = { Amount = 100 } },
})
```

## Reasons

| Reason | Means | Answered by |
| --- | --- | --- |
| `Refused` | the reducer said no, permanent | all |
| `Busy` | a transaction holds a key, **nothing was applied** | `Tx`, `Transfer` |
| `Spent` | that id cannot be used again, use a new one | `Tx`, `Transfer` |
| `Unresolved` | no final answer yet, it may still land | all |
| `Closed` | the session was released, the player left | `Apply`, `Commit` |
| `Backlog` | the unsaved backlog hit its cap, saves are not landing | `Apply`, `Commit` |
| `Full` | the profile is at the 2MB cap and this op grows it | `Apply`, `Commit` |
| `Invalid` | the op cannot be stored | `Apply`, `Commit`, `Edit` |

Each names what you should do, never what went wrong inside. `Unresolved` always means the same
thing: re-read rather than deciding, and never retry under a new id.

`Reason` is a union type, so annotating one catches a typo:

```luau
local Why: Ledger.Reason = "Refuzed"   -- type error
```

A **comparison** cannot be checked that way, `Why == "Refuzed"` is legal Luau and silently never
matches. Compare against `Ledger.Reason` instead and a typo becomes a type error again:

```luau
local Ok, Why = Store:Transfer(From, To, 50):Wait()
if not Ok and Why == Ledger.Reason.Busy then   -- Ledger.Reason.Buzy would not compile
	Retry()
end
```

## Throws vs returns

Outcomes return. Mistakes in the call throw where they are written:

```luau
Store:Tx("x", { Leg })                        -- throws, needs 2 to 4 legs
Store:Transfer(A, B, -5)                      -- throws, Amount must be positive and finite
Store:Transfer(A, B, 5)                       -- throws if the store has no Balance
Store:Peek("nope")                            -- throws on a player store, keys are UserIds
```

`Tx` legs validate up front and throw, since one unstorable leg would take the whole set down.
`Edit` returns `Invalid` instead, matching `Apply`: a single key write takes fields as they come.

## Warnings

Almost every warning is Ledger telling you what it already handled. Exactly two ask something
of you, and both mean compensating from the audit log:

- a stranded transfer past its 30 day horizon, settled rather than refunded
- an `Erase` that could not deliver its escrow first

## Futures

```luau
Future:Wait(Timeout?) -> T...       -- yields until settled
Future:Happened(Wait?) -> boolean   -- whether the job ran, not whether it was accepted
```

`Wait(Seconds)` frees the caller and returns nothing; it does not stop the job, and there is no
cancellation. A failed job settles rather than throwing, and warns with a stack trace.

## Observers

```luau
Observer:Subscribe(Listener) -> Connection
Observer:Map(Transform) -> Observer      -- derive a new stream
Observer:Filter(Predicate) -> Observer
Observer:Changed(Equals?) -> Observer    -- drop repeats, == by default
Observer:Use(Middleware) -> Observer     -- the primitive the others build on
Observer:Destroy()
```

Listeners run inline and must not yield.

## Types

```luau
local Store: Ledger.Store<Profile> = Ledger.New({ ... })

type Op = { Id: string, Kind: string, [any]: any }
type Reducer<S> = (State: S, Op: Op) -> S?
type Migration = ((State: any) -> any) | { Apply: (State: any) -> any, Compatible: boolean? }
type Entry = { Version: string, At: number, Deleted: boolean }
```
