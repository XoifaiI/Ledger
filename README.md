<div align="center">

# Ledger

Player data as a ledger, not a document.

[![Luau](https://img.shields.io/badge/Luau-strict-00A2FF?style=for-the-badge&logo=lua&logoColor=white)](https://luau.org)
[![Roblox](https://img.shields.io/badge/Roblox-DataStore-E2231A?style=for-the-badge&logo=robloxstudio&logoColor=white)](https://create.roblox.com/docs/cloud-services/data-stores)
[![Realm](https://img.shields.io/badge/Realm-Server-555555?style=for-the-badge)]()
[![Dependencies](https://img.shields.io/badge/Dependencies-0-success?style=for-the-badge)]()
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

</div>

## What is this?

Ledger is a datastore library for Roblox with no session locks. State is a pure fold of an
append-only op log: every change is a small validated intent, a reducer you write decides
whether each one is legal, and anything invalid is unreachable no matter how many servers
write at once. Two servers spend the same 100 gold, both writes land, the fold accepts one and
rejects the other. Every server agrees, every time.

A session lock serializes writers. A validating fold makes the invalid state unreachable,
which is a stronger guarantee that also costs nothing when a server crashes: there is no lease
to wait out, no locked-player join stall, and no side channel needed to touch a player who is
offline or on another server. What you pay instead is discipline: changes are ops with names,
and a reducer validates them.

The whole thing is about 3,700 lines of strict Luau including its vendored utilities, with no
external dependencies. It is server-only, never replicates, and has no client half. It is
small enough to read in a sitting and feature complete enough to build a real game against.

## Features

- **Lock-free validating fold.** State is a deterministic fold of an append-only op log, so an
  invalid state is unreachable rather than rejected after the fact, and every server computes
  the same result without a lock.
- **Apply for gameplay, Commit for side effects.** `Apply` is an instant local call; `Commit`
  is durable and tells you whether your op won, so exactly one server lands a one-time grant.
- **Cross-server writes.** `Edit`, `Transfer`, and `Tx` work on any player, online here,
  elsewhere, or offline.
- **Entity stores.** `Keys = "String"` gives a store keyed by plain strings for shared state no
  single server owns: clans, listings, world records.
- **Transfers.** One numeric balance moved through an escrow, deduped by id, self-healing after
  a crash: money is never minted, lost, or double-spent.
- **Atomic transactions.** A lock-free two-phase commit across two to four keys, which may span
  two stores; both sides move or neither does, and a stale one aborts itself within a minute.
- **Migrations with rolling-deploy safety.** Versioned shape upgrades, a hard guard against old
  servers folding new formats down, and a `Compatible` flag for additive changes.
- **Recovery.** The datastore's 30-day version history as `History` and `PeekVersion`, plus
  `Reset` (append a correction, keep the log) and `Erase` (hard delete).
- **Idempotent by construction.** Every op has an id and appends dedupe by it, even across
  compaction, so retries can never double-apply.
- **Loud misuse.** Bad options throw at build time, junk input refuses benignly, and state is
  deep-frozen so a stray mutation throws at the line that did it.

## Quick example

```luau
local Ledger = require(ServerStorage.Ledger)

local Store = Ledger.New({
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

Store:Load(Player)
Store:Expect(Player):Apply("SpendGold", { Amount = 25 })
```

The full method list lives in the [API reference](docs/api.md).

## Installing

**Wally**

```toml
[server-dependencies]
Ledger = "xoifaii/ledger@2.0.0"
```

**Rojo**: clone the repo and add `src` to your project as `ServerStorage/Ledger` (the folder
becomes the module, `init.luau` is its root).

**Model file**: insert the `Ledger` module anywhere server-side. `ServerStorage` is the natural
home.

Ledger is server-only. It never replicates and has no client half.

## Testing

The suite is 79 tests across 9 suites, run with Studio API access: sync `src` and `Tests` next
to each other (the bundled `test.project.json` builds that shape), require the `Tests` folder,
and call `RunAll` from the server.

```luau
local Tests = require(ServerStorage.LedgerDev.Tests)
Tests.RunAll()
```

The chaos suite is written from the perspective of someone trying to break the runtime:
conservation storms with injected datastore failures and lost acknowledgements, every
transaction crash window, cross-store atomicity, aborted legs that must not resurrect,
idempotency across single and double compaction, and stranded transfers resolved by horizons.
Type-check the whole tree, sources and tests, with `analyze.ps1`.

## Docs

- [Getting started](docs/getting-started.md): install, build a store, wire the lifecycle, and
  migrate from 1.x
- [API reference](docs/api.md): every method, in one place
- [The model](docs/the-model.md): ops, the fold, and the reducer rules
- [Sessions](docs/sessions.md): the per-player API, Apply vs Commit
- [Cross-server](docs/cross-server.md): Peek, Edit, Transfer, and entity stores
- [Transactions](docs/transactions.md): atomic multi-key trades, including across stores
- [Migrations](docs/migrations.md): evolving your data shape safely
- [Recovery](docs/recovery.md): version history, resets, erasure
- [Design](docs/design.md): why it works this way, the "why not X" ladder

## License

This project is licensed under the [MIT License](LICENSE).
