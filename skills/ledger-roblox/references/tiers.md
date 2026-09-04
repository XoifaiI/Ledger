# What each call actually touches

The table in `SKILL.md` is the short form. This is the same thing with the path behind each row, so
it can be checked rather than believed. Paths are inside the library's own `src`, which ships with
the package.

## Reads that touch nothing else

`Inspect`, `History`, `PeekVersion`, `Read`, `Get`, `Expect`, `IsLoaded`, `WaitForLoaded`, `Stale`,
`Session:Get`, `Session:Observe`, `Session:DidApply`, `LogSize`, `LogBytes`.

`Inspect` deep copies and freezes the record before handing it over, so nothing a caller does to the
result can reach what the server folds from. `Session:DidApply` reads live state, which includes ops
that are queued and not yet written, so it can answer `true` before the write is durable. `DidApply`
on the **store** reads the record, which does not include them.

## Reads that enrol background work

`Peek` and `Store:DidApply` both go through one private helper (`Store/Api/Read.luau`, `Followed`)
that calls `Watch` and `WatchHeld` (`Store/Api/Write.luau`). Those add the key to the recovery sweep
when the record has a parked transaction leg, or when the folded state has money in `_Held`.

The sweep runs every 60 seconds and calls `Repair`, which settles legs and redrives or refunds
transfers. So a `Peek` on a key with a stranded transfer starts something that moves money a minute
later. Nothing is wrong with that, it is how a crashed server gets cleaned up. It is worth knowing
before saying "I only read it".

`Inspect`, `History` and `PeekVersion` do not enrol anything. Use `Inspect` when the intent is to
look without touching.

## Reads that write to MemoryStore

`Total` (`Store/Api/Ops.luau`) reads the cached sum, and when that sum is stale it writes a claim so
one server refills it, reads the 16 shards, and writes the new sum back. Two of those are `Update`
calls, which cost two request units each.

`MaxAge` is what decides whether it calls at all. It defaults to one minute, and zero forces a read
every time. A pot polled every five seconds with `MaxAge = 0` costs twelve times what the default
costs, for the same answer.

`Holds` is a single `Get` and writes nothing.

## Writes to the record

`Apply` queues an op and writes nothing until the next save, so its answer is this server's opinion
and not a settled fact. Everything else in this group writes when it answers: `Commit`, `CommitOp`,
`Flush`, `Compact`, `Edit`, `Bump`, `Confirm`, `Transfer`, `Tx`, `Resettle`, `RecoverTransfers`,
`ClearDelivered`, `Unload`, `Session:Release`, and `Ledger.Sweep`.

Three of them are more than they look:

- **`Load`** reads, and settles what it finds. `Session.Load` calls `Tx.Settle` on a record with a
  parked leg, and `Store.PickUp` starts a transfer recovery when the state has money in `_Held`. A
  player joining can therefore complete a transaction another server abandoned.
- **`Confirm`** writes the op through the ordinary write path and then drops the hold in MemoryStore.
  The two are not atomic and are not meant to be. A retry is deduped by the op id, which derives from
  the reservation name, until the key compacts. After that the record cannot tell whether the op took
  or was turned away, and a repeat answers `Unresolved`.
- **`Transfer`** is three ops across two keys. It can leave money in `_Held` on purpose, which is the
  only safe place for it, and answers `Held` when it could not hand it over.

## Writes to MemoryStore only

`Reserve` and `Release` never touch the record. A hold is not in the fold, so `Peek` shows the field
at its full value while a hold stands, and an `Edit` can spend units somebody holds. That is by
design: the reducer is the gate at checkout, so a lost hold costs one refused checkout and never an
oversell.

`Tx` also leases each of its keys in MemoryStore before it drives, in a fixed order. The lease only
decides who tries first. The marker still decides the transaction, and a server that cannot reach
MemoryStore drives without one.

## The bottom rows

- **`Reset`** appends an op that writes the default state back. It keeps `_Received` and `_Held`,
  because dropping either would let an old delivery pay twice or strand money in flight. It cannot
  free a key whose log holds an op this build refuses, because the reset is another op behind that
  one.
- **`Erase`** hands over what the key owes first, then buries it. The tombstone turns away anything
  sent to the key for 8 days and a write does not clear it. A second `Erase` after that window calls
  `RemoveAsync` and takes the record off. It also removes the key's holds from MemoryStore.
- **`Destroy`** saves every live session on that store, frees the name, and makes every later call
  throw. **`CloseAll`** does it for every store and stops the sweep.

## Reading this against the source

Every row above can be checked in one grep inside the library:

```
grep -rn "self:Watch\|:WatchHeld\|Sweep:Add" src
grep -rn "self.Tallies\|self.Leases\|self.Bookings" src
```

The first prints every place a key is handed to the sweep. The second prints every place MemoryStore
is touched. If either prints a line this file does not account for, this file is stale.
