# What each call touches, and what it costs

The table in `SKILL.md` is the short form. This is the same with costs and the path behind each row, so
it can be checked rather than believed. Paths are inside the library's `src`. Costs are Roblox requests
with no contention and no faults, measured on 7.0.0: `read` is a `GetAsync`, `write` an `UpdateAsync`.
The server's budget is 60 + 40 per player of each kind a minute; a key takes about 4 MB of writes and
25 MB of reads a minute.

## Memory only

`Session:Get`, `Session:Observe`, `Session:ObserveFates`, `Store:Get`, `Expect`, `IsLoaded`, `Read`,
`Store:Stale`, `Store:Leg`, `Store:Quantity`, `Ledger.Now`, `Ledger.Id` (after the server's number is
drawn).

Every value they hand back is a deep-frozen copy, on a live server too. Changing it throws.
`Session:Get()` is the session's **view**: the last saved state this server saw, with the session's own
queued `Apply`s laid on top. It is not the saved data.

## `Apply`: free now, judged twice

`Session:Apply` sends nothing. It judges the op on the view with the game's reducer and queues it. The
next save (every `SaveInterval`, 30 s, while ops are queued, one write however many) judges it again on
the saved data, and can turn it away. A `Flush`, `Commit`, `Release`, `Unload` or the close also carries
the queue. `Sessions/Session.luau`, `Api/Session.luau`.

The queue holds 4,096 ops or 1.5 MiB; past that `Apply` answers `Backlog`. A crash before a save loses
the queue with no fate.

## Reads, and why they aren't passive

| Call | Cost | Notes |
|---|---|---|
| `Store:Peek(Key)`, `Peek(Key, 0)` | 1 read | the saved state at some moment, never older than this server showed last |
| `Store:Inspect(Key)` | 1 read | the record: state plus the supported parts of `Book` |
| `Store:Losses(Key)` | 1 read | cut events and returned escrow, 7 days |
| `Store:Pending(Key)` | 1 read | unfinished trade work, with ages |
| `Store:DidApply(Key, Name)` | 1 read | `Probe = true` makes it **1 write** |
| `Store:Load(Player)` | 1 read | then an idle session reads once per `IdleReadInterval` (120 s) |
| `Session:Refresh()` | 1 read, or a `Flush` with ops queued | the view adopts the read only if it's newer |
| `Store:Keys():Next()` | 1 list request per page of 50 | the list budget is 5 + 2 per player a minute |

Every read that finds unfinished trade work on a key notes it, and this server comes back to end that
work: from 10 s on for a session's load or idle read, staggered up to about 30 minutes (`TouchBound`,
1,878 s) otherwise. Ending it costs writes and applies decided legs, aborts undecided ones, and returns
escrow. So a read can cause money to move, later, on this server. `Writing/Numbers.luau`
(`LearnWorkAndGate`), `Tx/Work/Touch.luau`, `Constants/Transaction.luau`.

Beside an undecided mark from a server that died, `Peek` and `Inspect` answer `Unresolved` on every
server until a touch ends it, up to about 30 minutes. `Load` doesn't wait that long: it acts on such a
mark once it's 10 s old.

Reads answer `Unresolved` after 30 s (`OpBound`) when the DataStore doesn't answer.

## Reads through the shared copy

`Peek(Key, MaxAge)` and `Follow(Key)` read a copy of the key kept in MemoryStore, shared by every
server. `Extras/Copies/`.

| Case | Cost |
|---|---|
| this server showed the key within `MaxAge` | nothing |
| a live copy exists | 1 MemoryStore request |
| no copy yet | 2 reads + 2 MemoryStore requests, and **this server becomes the copy's holder** |
| the holder | 2 reads a minute per key for 30 minutes after the last use |
| `Follow` | 1 MemoryStore read per tick per server: 30 s, doubling to 240 s on a quiet key |

So `MaxAge` saves requests only on a key many servers read often. On a key one server reads now and
then, it costs more than a plain `Peek`.

A copy can be minutes old: a write shows on the holder within about 30 s, elsewhere at the next tick,
and up to about 4.5 minutes on a quiet key. Right after this server's own write, a `MaxAge` read can
still return the copy from before it. Once a server has heard `Behind` for a key, its `MaxAge` reads
answer `Behind` and `Follow` emits `"Behind"`; a server that never read the key can serve the old copy
once before it learns. A copy expires an hour after it was last written.

`Peek(Key, { Fresh = true })` is the only current read, and it is **1 write** that changes nothing.

## Writes

| Call | Cost | Notes |
|---|---|---|
| `Store:Edit`, `Session:Commit` | 1 write; +1 read the first time this server meets an erasable key | `Edit` on a key a session here holds goes through that session's writer, with its queued ops |
| `Session:Flush`, `Release`, `Store:Unload` | 1 write with ops queued, else nothing | `true` means the push was answered, not that ops saved |
| `Ledger.Tx`, N keys | N writes before the answer, 2N-1 in all | a two-player trade: 2 to the answer, 3 in all |
| `Quantity:Take`, `Hold`, `Confirm`, `Release` | 1 write; with one key in `Legs`, 2 to the answer and 3 in all | a failed try on a part adds a write on the part and two per leg key |
| `Quantity:Deposit`, `Withdraw`, `Gather` | a two-leg `Tx` each (a minted `Deposit` is 1 write) | Open quantities, mostly |
| `Store:Bump` | 1 write per shard per server batch | yields 0 to 60 s, up to 90 s when writes fail |
| `Store:Total(Name, MaxAge)` | nothing inside `MaxAge`; else 1 MemoryStore request; shard reads when the summary is gone | a statistic, never part of an op |
| `Store:Resettle` | 1 read + 1 write, +1 read and 1 write per undecided mark | ends the key's trade work now |
| Server start | 1 write on `Ledger$N` | draws the server's number |

An unnamed write that answers `Unresolved` stays in this server's writer, which sends it again about
every 16 s for the server's life (`Writing/Writer.luau`, `Writing/Sending.luau`). A `Tx` that answers
`Unresolved` is driven by its sender with no time bound while the sender lives (`Tx/Call/`). After a
long outage (past about 180 s), if other writes to the key drop names stamped after the op's first send,
the op can end without landing: a session op then gets the `Unknown` fate, and an unnamed `Edit` is
dropped with no signal. For changes the game can't lose, keep a record in the data.

A game-op leg of a `Tx` that isn't the decider takes an **exclusive mark** on its key, holding the key's
game ops until the trade ends. A balance leg only escrows its amount, so credits and covered debits on
the key go on beside it. A key holds at most 16 marks; the 17th leg answers `NoRoom`. The decider is
the only game-op leg if there's exactly one, else the first Credit leg, else the last
(`Tx/Call/Terms.luau`, `ChooseDecider`).

## The bottom rows

- **`Quantity:Open`** writes every part, every call, even when they exist: `Parts` writes. Once per
  quantity, ever. After `Close` it makes the stock again; `Closed = true` in the declaration makes it
  throw in this build. `Hot/Calls/Open.luau`.
- **`Quantity:Close`** writes every part and removes those that are empty and more than 62 minutes past
  the first `Open` (`SealAge`): `Parts` writes plus one `RemoveAsync` per removed part. Safe from many
  servers and again later. A removed part reads `Missing`, the same as never opened.
  `Hot/Calls/Close.luau`, `Constants/Cuts.luau`.
- **`Reset`** ends the key's trade work first, then replaces the state with `Default` or a given `State`
  (newest shape, at most 1 MiB, never migrated), and names every non-zero balance field it replaced in
  the key's `Losses` for 7 days. 1 write, plus 2 per decider when marks stand. `Cuts/`.
- **`Erase`** ends the key's trade work, seals the key, then removes it with `RemoveAsync`. The destroyed
  balances come in `Cut.Losses` of the first answer only. About 200 s at worst. Roblox keeps the older
  versions 30 days; Ledger doesn't remove them. `Cuts/`.
- **`Reset` and `Erase` names** are `Ledger.Id()` names or none. A server answers `Expired` for its own
  name once it's `CutWindow` (360 s) old, and sends nothing.
- **`Store:Destroy`** releases every session on the store (up to 25 s), ends its observers, and the name
  can't be opened again on this server. **`Ledger.CloseAll`** runs `BeforeClose` functions (5 s), then
  saves every session on every store; it is bound to the platform's close already.

## Reading this against the source

```
grep -n "SettleAge\|TouchBound" Constants/Transaction.luau
grep -n "OpBound\|MarkCap\|QueueRoomOps" Constants/Record.luau
grep -n "local function ChooseDecider" -A25 Tx/Call/Terms.luau
grep -rn "WorkSeen\[" .
```

The last prints every place a read records work for this server to end. If a row here disagrees with
the source, this file is stale.
