# Transactions

`Tx` is for trades: changes across two to four players that must be atomic. Both sides
change or neither does, with no locks, no same-server requirement, and no requirement
that anyone involved is online.

```luau
local Committed = Ledger:Tx({
	{ UserId = 123,   Kind = "Delta", Fields = { Gold = 25,  Drop = "Sword" } },
	{ UserId = 456, Kind = "Delta", Fields = { Gold = -25, Gain = "Sword" } },
}):Wait()
```

Each leg is an ordinary op kind your reducer already handles. The transaction machinery
only decides whether the whole set happens.

## How it works

The transaction writes a `Pending` marker to a side store, then appends one leg to each
player's log with a `Tx` stamp on it. Every fold skips stamped ops, so a prepared leg
simply has not happened yet. Each leg is validated by your reducer at its position in the
log, and because the log is append-only that position never changes: nothing can ever be
inserted before a prepared leg, so a leg the reducer accepted at prepare is still accepted
when the stamp comes off.

If every leg validates, the marker flips to `Committed` and the stamps strip. Each leg is
now an ordinary durable, idempotent, audited op. If any leg rejects, the marker flips to
`Aborted`, the prepared legs are removed, and their ids are retired so a retry can never
resurrect them.

## Crash safety

Every window is covered, and crashes are someone else's problem, literally: any server
that runs into a pending leg resolves it from the marker, and whoever finds a marker
still `Pending` after 60 seconds aborts it. A crashed coordinator can never wedge a key
for longer than that. A cleanup counter deletes the marker once every leg has folded its
outcome.

## The rules

- **One pending transaction per key at a time.** A second one answers busy and aborts
  whole. The window is seconds; just retry.
- **Sessions keep working during the pending window.** `Apply` is unaffected. `Commit` on
  a key with a fresh pending leg returns false rather than answer while the ground might
  shift; retry after the window.
- **Compaction waits out a pending leg**, since the leg must keep its log position. The
  next autosave compacts as usual.
- **The `Tx` op field is reserved.** `Apply`, `Commit` and `Edit` refuse ops carrying it,
  so a game op can never impersonate a transaction leg.
- **Legs validate against the state at prepare time.** Ops appended later fold after the
  leg, so their acceptance may shift when the leg materializes, which is the same rule as
  any cross-server write.

## When to use it

Use `Tx` when changes on different players depend on each other: item trades, bundled
swaps, anything where one side applying without the other is a dupe or a theft. For plain
balance movement, [`Transfer`](cross-server.md) is simpler and needs no coordination. For
one player, one op is already atomic on its own; never use a transaction where a single
multi-field op would do.
