# Ledger

Player data as a ledger, not a document.

Ledger is a datastore library for Roblox with no session locks. State is a pure fold of an
append-only op log: every change is a small validated intent, a reducer you write decides
whether each one is legal, and anything invalid is unreachable no matter how many servers
write at once. Two servers spend the same 100 gold, both writes land, the fold accepts one
and rejects the other. Every server agrees, every time.

```luau
local Ledger = require(ServerStorage.Ledger)

Ledger:Configure({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {} },
	Reducer = function(State, Op)
		if Op.Kind == "SpendGold" then
			if Op.Amount > State.Gold then
				return nil -- rejected, on every server, forever
			end
			local Next = table.clone(State)
			Next.Gold -= Op.Amount
			return Next
		end
		return nil
	end,
})

Ledger:Load(Player)
Ledger:Expect(Player):Apply("SpendGold", { Amount = 25 })
```

## Why no locks

A session lock serializes writers. A validating fold makes the invalid state unreachable,
which is a stronger guarantee that also costs nothing when a server crashes: there is no
lease to wait out, no locked-player join stall, and no side channel needed to touch a player
who is offline or on another server. The lock-based failure modes (minutes-long lockouts
after a crash, teleport handoff waits, unreachable locked data) simply do not exist here.

What you pay instead is discipline: changes are ops with names, and a reducer validates them.
[The design doc](docs/design.md) walks through every alternative and why each one collapses
back into this shape.

## What you get

- **Idempotent by construction.** Every op carries an id and appends dedupe by it, so a
  retried write after a lost response can never double-apply. Receipts and grants are safe
  to retry blindly.
- **An audit trail for free.** The log records what happened and why, with names. A
  moderation reset appends the correction instead of erasing the evidence.
- **Cross-server writes that just work.** `Edit`, `Transfer` and `Tx` operate on any player,
  online or not, in this server or none.
- **Atomic multi-player transactions, no locks.** A lock-free two-phase commit where a
  committed trade becomes ordinary durable ops. Any server can resolve a crashed
  coordinator's leftovers, and a stale transaction aborts itself within a minute.
- **Migrations with rolling-deploy safety.** Versioned shape upgrades, a hard guard that
  stops old servers folding new formats back down, and a `Compatible` flag so additive
  changes do not kick players off stale servers.
- **Built-in recovery.** The datastore's 30-day version history exposed as
  `History` and `PeekVersion`, folded into readable state.
- **Loud misuse.** Bad configuration throws at boot, not at the first player. Junk input
  refuses benignly instead of writing garbage keys. In Studio, session state is deep-frozen
  so a consumer that mutates instead of cloning throws in development.

## Crash behavior, stated plainly

Pending ops live in server memory between flushes. A soft shutdown (updates, migration,
nearly every server death) flushes everyone through `CloseAll` and loses nothing. A hard
crash loses at most the autosave interval (30 seconds) of optimistic gameplay ops, and
anything routed through `Commit` was durable before its side effect fired. No library
survives the power cord; the honest levers are the width of the window and what you route
around it.

## Docs

- [Getting started](docs/getting-started.md): install, configure, wire the lifecycle
- [The model](docs/the-model.md): ops, the fold, and the reducer rules
- [Sessions](docs/sessions.md): the per-player API, Apply vs Commit
- [Cross-server](docs/cross-server.md): Peek, Edit and Transfer
- [Transactions](docs/transactions.md): atomic multi-player trades
- [Migrations](docs/migrations.md): evolving your data shape safely
- [Recovery](docs/recovery.md): version history, resets, erasure
- [Design](docs/design.md): why it works this way, the "why not X" ladder

## License

MIT
