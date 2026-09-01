<div align="center">

# Ledger
[![GitHub](https://img.shields.io/badge/GitHub-Ledger-181717?style=for-the-badge&logo=github&logoColor=white)](https://github.com/XoifaiI/Ledger) [![Docs](https://img.shields.io/badge/Docs-Read-8B5CF6?style=for-the-badge)](https://xoifaii.github.io/LedgerDocs/)

</div>

## What is this?

A datastore library for Roblox with no session locks. You never write state. You write down
the change you want, a function you own decides whether it is valid, and state is what falls
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
server. Changes are ops with names, and a reducer validates them.

## Features

- **Lock free** | every server, same result, no locks
- **Cross server** | write to any player, even offline
- **Entity stores** |  clans, listings, world records
- **Transfers** | escrowed, deduped, self-healing
- **Transactions** | all keys move or none do
- **Migrations** | old servers can't corrupt new data
- **Recovery** | 30 days of history, auto cleanup
- **Idempotent** | a write retried applies one time
- **`Once`** | receipts and webhooks land exactly once
- **Typed ops** | name them once, every write is checked
- **Loud misuse** | bad code throws, immediately

## Installing

**Wally**

```toml
[dependencies]
Ledger = "xoifaii/ledger@4.5.0"
```

**Model file**: insert the [Ledger](https://github.com/XoifaiI/Ledger/releases) module anywhere server side.

## License

This project is licensed under the [MIT License](https://github.com/XoifaiI/Ledger/blob/main/LICENSE).
