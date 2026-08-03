<div align="center">

# Ledger

Player data as a ledger, not a document.

[![Luau](https://img.shields.io/badge/Luau-strict-00A2FF?style=for-the-badge&logo=lua&logoColor=white)](https://luau.org)
[![Roblox](https://img.shields.io/badge/Roblox-DataStore-E2231A?style=for-the-badge&logo=robloxstudio&logoColor=white)](https://create.roblox.com/docs/cloud-services/data-stores)
[![Docs](https://img.shields.io/badge/Docs-Read-8B5CF6?style=for-the-badge)](https://xoifaii.github.io/LedgerDocs/)
[![Dependencies](https://img.shields.io/badge/Dependencies-0-success?style=for-the-badge)]()
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

</div>

## What is this?

A datastore library for Roblox with no session locks. You never write state. You write down
the change you want, a function you own decides whether it is legal, and state is what falls
out of replaying those changes.

```luau
local Store = Ledger.New({
	Name = "PlayerData",
	Default = { Gold = 100, Items = {} },
	Reducer = function(State, Op)
		if Op.Kind == "SpendGold" then
			if Op.Amount > State.Gold then
				return nil -- refused, on every server, forever
			end
			local Next = table.clone(State)
			Next.Gold -= Op.Amount
			return Next
		end
		return nil
	end,
})

Store:Load(Player)
Store:Expect(Player):Apply("SpendGold", { Amount = 25 })
```

Two servers spend the same 100 gold, both writes land, the fold accepts one and refuses the
other. Every server agrees, every time.

A session lock serializes writers. A validating fold makes the invalid state unreachable,
which is a stronger guarantee that also costs nothing when a server crashes: no lease to wait
out, no locked player join stall, no side channel to touch someone offline or on another
server. What you pay instead is discipline. Changes are ops with names, and a reducer
validates them.

## Features

- **Lock-free validating fold.** Invalid state is unreachable, not rejected after the fact,
  and every server computes the same result without a lock.
- **Apply for gameplay, Commit for side effects.** `Apply` is an instant local call. `Commit`
  is durable and tells you whether your op won, so exactly one server lands a one time grant.
- **Cross-server writes.** `Edit`, `Transfer` and `Tx` work on any player, online here,
  elsewhere, or offline.
- **Entity stores.** `Keys = "String"` gives you clans, listings, world records: shared state
  no single server owns.
- **Transfers.** One balance moved through an escrow, deduped by id, self healing after a
  crash. Name the transfer and a retry is safe.
- **Atomic transactions.** Lock-free two phase commit across two to four keys, which may span
  two stores. Both sides move or neither does, and a stale one aborts itself within a minute.
- **Migrations with rolling deploy safety.** Versioned shape upgrades, a hard guard against
  old servers folding new formats down, and a `Compatible` flag for additive changes.
- **Recovery.** 30 days of version history as `History` and `PeekVersion`, plus `Reset` and
  `Erase`. A transaction leg stranded on a shared key is swept up in the background, so there
  is no periodic job for you to write.
- **Idempotent by construction.** Every op has an id and appends dedupe by it, even across
  compaction, so retries cannot double apply.
- **`Once` for ids you do not own.** Name an op after a receipt, a webhook or an order and it
  lands at most one time on that key, forever, across compaction, rejoins and two servers
  racing the same replay. `DidApply` answers whether it ever landed.
- **Loud misuse.** Bad options throw at build time, junk input refuses benignly, and state is
  deep frozen so a mutation throws at the line that did it.

## Installing

**Wally**

```toml
[server-dependencies]
Ledger = "xoifaii/ledger@3.3.0"
```

**Rojo**: clone the repo and add `src` to your project as `ServerStorage/Ledger`.

**Model file**: insert the `Ledger` module anywhere server side.

## License

This project is licensed under the [MIT License](LICENSE).
