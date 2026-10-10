<div align="center">

# Ledger
[![GitHub](https://img.shields.io/badge/GitHub-Ledger-181717?style=for-the-badge&logo=github&logoColor=white)](https://github.com/XoifaiI/Ledger) [![Docs](https://img.shields.io/badge/Docs-Read-8B5CF6?style=for-the-badge)](https://xoifaii.github.io/LedgerDocs/)

</div>

## What is this?

A datastore library for Roblox with no session locks. You never write state. You write down
the change you want, a function you own decides whether it is valid, and Ledger saves each
change exactly once.

```luau
type PlayerData = {
	Gold: number,
	Items: { [string]: number },
}

type PlayerOps = {
	SpendGold: { Amount: number },
}

local PlayerStore = Ledger.New<<PlayerData, PlayerOps>>({
	Name = "PlayerData",
	Keys = "Player",
	Default = { Gold = 100, Items = {} },
	MustExist = false,
	Erasable = true,
	Reducer = function(Data, Op)
		if Op.Kind == "SpendGold" then
			if Op.Amount > Data.Gold then
				return nil -- refused, on every server
			end
			local New = table.clone(Data)
			New.Gold -= Op.Amount
			return New
		end
		return nil
	end,
})

local Session = PlayerStore:Load(Player)
if Session then
	local Ok, Why = Session:Commit({ Kind = "SpendGold", Amount = 25 })
	if not Ok then
		warn("Couldn't spend gold:", Why)
	end
end
```

Two servers spend the same 100 gold at once: the reducer accepts one and refuses the other.
Every server agrees, every time, and every call says what happened.

A session lock serializes writers. A validating fold makes the invalid state unreachable,
which is a stronger guarantee that also costs nothing when a server crashes: no lease to wait
out, no locked player join stall, no side channel to touch someone offline or on another
server. Changes are ops with names, and a reducer validates them.

## Features

- **Lock free** | every server, same result, no locks
- **Cross server** | write to any player, even offline
- **Entity stores** |  clans, listings, world records
- **Transactions** | up to 29 players or keys, all move or none do
- **Balances** | gold keeps moving while a trade is in progress
- **Limited items** | sold from every server, never oversold
- **Global counters** | every server adds, reading is free
- **Migrations** | old servers can't corrupt new data
- **Idempotent** | a write retried applies one time
- **Typed ops** | name them once, every write is checked
- **Loud misuse** | bad code throws, immediately

## Installing

**Wally**

```toml
[dependencies]
Ledger = "xoifaii/ledger@7.0.0"
```

**Model file**: insert the [Ledger](https://github.com/XoifaiI/Ledger/releases) module anywhere server side.

**roblox-ts**

```
npm install @xoifail/ledger
```
The same types work for TypeScript: see [Types](https://xoifaii.github.io/LedgerDocs/docs/reference/types).

## License

This project has the [MIT License](https://github.com/XoifaiI/Ledger/blob/main/LICENSE).
