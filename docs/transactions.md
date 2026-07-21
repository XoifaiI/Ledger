# Transactions

`Tx` is for trades: changes across two to four keys that must be atomic. Both sides change or
neither does, with no locks, no same-server requirement, and no requirement that anyone
involved is online.

```luau
local Committed = Store:Tx({
	{ UserId = 123, Kind = "Delta", Fields = { Gold = 25,  Drop = "Sword" } },
	{ UserId = 456, Kind = "Delta", Fields = { Gold = -25, Gain = "Sword" } },
}):Wait()
```

Each leg is an ordinary op kind your reducer already handles. The transaction machinery only
decides whether the whole set happens.

## How it works

The transaction writes a `Pending` marker to a side store, then appends one leg to each
player's log with a `Tx` stamp on it. Every fold skips stamped ops, so a prepared leg
simply has not happened yet. Each leg is validated by your reducer at its position in the
log, and because the log is append-only that position never changes: nothing can ever be
inserted before a prepared leg, so a leg the reducer accepted at prepare is still accepted
when the stamp comes off.

If every leg validates, the marker flips to `Committed` and the stamps strip. Each leg is now
an ordinary durable, idempotent, audited op. If any leg rejects, the marker flips to
`Aborted`, the prepared legs are removed, and their ids are retired so a retry can never
resurrect them.

## Legs across two stores

A leg can name a different store with `Store`, so one transaction can move value between a
player store and an entity store. The store you call `Tx` on is the coordinator: its side
store holds the marker, and every leg records where the marker lives so a server that finds a
stranded leg on the other datastore still resolves it from the right place.

```luau
PlayerData:Tx({
	{ UserId = Jack, Kind = "SpendGold", Fields = { Amount = 100 } },
	{ Store = Clans, Key = "sunreavers", Kind = "Deposit", Fields = { Amount = 100 } },
}):Wait()
```

A leg uses `UserId` or `Key` to match the key mode of the store it targets. The same key
string on two different stores is two different legs, since a transaction may only touch a key
once per store.

## Crash safety

Every window is covered, and crashes are someone else's problem, literally: any server that
runs into a pending leg resolves it from the marker, and whoever finds a marker still
`Pending` after 60 seconds aborts it. A crashed coordinator can never wedge a key for longer
than that. A cleanup counter deletes the marker once every leg has folded its outcome, and a
coordinator that decides to abort shrinks that counter to the legs it actually wrote, so a
failed transaction cleans up its own marker instead of leaving a husk behind.

A coordinator that cannot record its verdict, because the marker store is down for the whole
retry budget, does not guess. It leaves the legs pending and returns false. They settle later
from whatever the marker durably says, so a lost acknowledgement can delay a transaction but
can never split it into one side applying without the other.

## The rules

- **One pending transaction per key at a time.** A second one answers busy and aborts
  whole. The window is seconds; just retry.
- **Sessions keep working during the pending window.** `Apply` is unaffected. `Commit` on
  a key with a fresh pending leg returns false rather than answer while the ground might
  shift; retry after the window.
- **Compaction waits out a pending leg**, since the leg must keep its log position. The
  next autosave compacts as usual.
- **The `Tx` and `TxHome` op fields are reserved.** `Apply`, `Commit` and `Edit` refuse ops
  carrying either, so a game op can never impersonate a transaction leg.
- **Legs validate against the state at prepare time.** Ops appended later fold after the
  leg, so their acceptance may shift when the leg materializes, which is the same rule as
  any cross-server write.

## When to use it

Use `Tx` when changes on different keys depend on each other: item trades, bundled swaps, a
player buying into a clan bank, anything where one side applying without the other is a dupe
or a theft. For plain balance movement, [`Transfer`](cross-server.md) is simpler and needs no
coordination. For one key, one op is already atomic on its own; never use a transaction where
a single multi-field op would do.
