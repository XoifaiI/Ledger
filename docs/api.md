# API reference

## Module

```luau
Ledger.New(Options) -> Store   -- build a store, once, before anyone joins
Ledger.CloseAll()              -- flush and release every store, from BindToClose
Ledger.Sweep()                 -- settle stranded transaction legs now, not on the next tick
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

Session.LogSize   -- ops since the last snapshot
Session.LogBytes  -- their measured size
```

## Any key

Online, elsewhere, or offline. A UserId on a player store, a string on an entity store.

```luau
Store:Peek(Key) -> Future<State>
Store:Edit(Key, Kind, Fields?) -> Future<boolean, Reason?>
Store:Transfer(From, To, Amount, Id?) -> Future<boolean, Reason?>
Store:Tx(Id, Legs) -> Future<boolean, Reason?>             -- atomic across 2 to 4 keys

Store:History(Key, Limit?) -> Future<{ Entry }>            -- 30 day version list, newest first
Store:PeekVersion(Key, Version) -> Future<State>

Store:RecoverTransfers(Key) -> Future<()>
Store:ClearDelivered(Key) -> Future<()>                    -- drop every applied id, a last resort
Store:Reset(Key) -> Future<boolean, Reason?>
Store:Erase(Key) -> Future<()>
```

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
