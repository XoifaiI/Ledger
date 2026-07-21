# API reference

## Building a store

- `Ledger.New(Options) -> Store` builds a store. Call it once, before anyone joins.
- `Ledger.CloseAll()` flushes and releases every store. Call it from `BindToClose`.

`Options` is a table:

```luau
{
    Name = "PlayerData",            -- datastore name, 1 to 47 characters
    Reducer = Reducer,              -- (State, Op) -> State? , decides every change
    Default = { Gold = 100 },       -- a fresh record's starting state
    Balance = "Gold",               -- optional: the numeric field Transfer moves
    Migrations = { ... },           -- optional: ordered shape-change steps
    Keys = "Player",                -- optional: "Player" (default) or "String"
}
```

`New` validates everything and returns the store you call methods on. Build as many as you
like; a second store with `Keys = "String"` is an entity store. `CloseAll` is a module
function, called once, that closes every store you built.

## The player lifecycle

Player stores get a session per player. Your boot script owns when they load and leave.

- `Store:Load(Player)` folds a session and starts the autosave. It kicks the player on a
  failed load.
- `Store:Unload(Player)` does a final save and releases the session.
- `Store:Get(Player) -> Session?` is the live session, or `nil` if not loaded.
- `Store:Expect(Player) -> Session` is the session, asserting it is loaded (throws otherwise).
- `Store:IsLoaded(Player) -> boolean` is whether a session is loaded.
- `Store:WaitForLoaded(Player) -> Session?` yields until loaded, `nil` if the player leaves
  first.
- `Store:Read(Player) -> State?` is the current state table, or `nil`.

## The session

- `Session:Get() -> State` is the current state.
- `Session:Apply(Kind, Fields?) -> boolean` runs the reducer, updates state optimistically, and
  queues the op for the next flush. Returns whether it was accepted.
- `Session:Commit(Kind, Fields?) -> Future<boolean>` appends durably and resolves to whether
  your op was the one accepted. Gate a side effect on this.
- `Session:CommitOp(Op) -> Future<boolean>` is `Commit` for a pre-built op whose `Id` you own.
- `Session:Flush() -> Future<()>` pushes pending ops, then folds in what other servers wrote.
- `Session:Compact() -> Future<()>` folds the log into a fresh snapshot.
- `Session:Release() -> Future<()>` does a final push and rejects further `Apply` or `Commit`.
- `Session:Observe() -> Observer<State>` is a stream of state that fires on every change.
- `Session.LogSize` and `Session.LogBytes` are the op count since the last snapshot and their
  measured size.

## Cross-server and entity keys

These work on any key, online or not, in this server or none. On a player store the key is a
UserId; on an entity store it is a string.

- `Store:Peek(Key) -> Future<State>` is a read-only fold, for display.
- `Store:Edit(Key, Kind, Fields?) -> Future<()>` appends one op to a key's log.
- `Store:Transfer(From, To, Amount) -> Future<boolean>` moves the `Balance` field between two
  keys.
- `Store:Tx(Legs) -> Future<boolean>` runs an atomic multi-key transaction.
- `Store:History(Key, Limit?) -> Future<{ Entry }>` is the 30-day version history, newest
  first.
- `Store:PeekVersion(Key, Version) -> Future<State>` folds a historical version into state.
- `Store:RecoverTransfers(Key) -> Future<()>` finishes a key's stranded transfers.
- `Store:ClearDelivered(Key) -> Future<()>` is an operator override that drops the delivered
  set.
- `Store:Reset(Key) -> Future<()>` appends a reset to `Default`, keeping the log.
- `Store:Erase(Key) -> Future<()>` hard-deletes the record.

A `Tx` leg is a table. On a player store it carries `UserId`, on an entity store `Key`, and it
can name a different `Store` to cross datastores:

```luau
Store:Tx({
    { UserId = Jack, Kind = "SpendGold", Fields = { Amount = 100 } },
    { Store = Clans, Key = "sunreavers", Kind = "Deposit", Fields = { Amount = 100 } },
})
```

## Futures

The cross-server methods and `Commit` return a `Future`. You consume it two ways:

```luau
local State = Store:Peek(UserId):Wait()          -- yields until done, returns the value
local Ok = Store:Edit(UserId, "AddGold", { Amount = 5 }):Happened(true)  -- wait, then success
```

`:Wait()` yields the calling coroutine until the job settles and hands back its result.
`:Happened(true)` yields and then returns whether it succeeded, for when you only need the
boolean. A failed job settles instead of throwing; every failed datastore attempt is warned
with a stack trace, so a silent nil is never silent about why.
