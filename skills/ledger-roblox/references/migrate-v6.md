# Moving a game from Ledger 6 to 7

Ledger 7 is a rewrite, and it can't read Ledger 6's data. Plan a rewrite of the Ledger calls and an
import of the data, not a version bump. Work in this order, and show the developer the plan from step 1
before changing any code.

## 1. Inventory

Search the game for every Ledger use and list it by file:

- **Configs**: `Ledger.New` with `Name`, `Balance`, `Shards`, `BumpEvery`, `Migrations`, `Keys`, `Mock`,
  `Hook`, `OnLoadFailed`.
- **Writes**: `:Edit(`, `:EditOp(`, `:Apply(`, `:Commit(`, `:CommitOp(`, `:Confirm(`, `:Tx(`,
  `:Transfer(`, `:Reserve(`, `:Release(`, `:Bump(`, `:Reset(`, `:Erase(`, `:Flush(`, `:Compact(`.
- **Reads**: `:Peek(`, `:Inspect(`, `:Follow(`, `:Total(`, `:Holds(`, `:History(`, `:PeekVersion(`,
  `:DidApply(`, `:Stale(`.
- **Recovery**: `Resettle`, `RecoverTransfers`, `ClearDelivered`, `Ledger.Sweep`.
- **Every `:Wait()`** on a Ledger answer, every `Once =`, every compare against a reason, every read of
  `_Held` or `_Received` in game code.
- **`ProcessReceipt`**: how it decides, and what name it uses.

The count of each tells you the size of the job. Say it.

## 2. Decide what moves, and how

**v7 can't read v6 data.** v6 stored a log of ops; v7 stores the state with its own bookkeeping. Every
v7 store gets a **new `Name`** (`PlayerDataV7`), and each player's v6 data is imported into it the first
time they join a v7 server.

To read the v6 data, keep v6 in the game under another name (the v6 package as `LedgerV6`), open the
old store with its **old config, unchanged** (same reducer, same migrations: v6 folds the log with
them), and read it with v6's own `Peek(UserId):Wait()`. Reading the raw DataStore value gives v6's log,
not the player's data.

What each kind of v6 data needs:

| v6 data | In v7 |
|---|---|
| A player's state | an `Import` op, once per player, on their first v7 join |
| `_Held` (a v6 transfer in flight) | don't import a key with entries in `_Held`. Run v6's `RecoverTransfers(Key)` first, or retry the import later. Gold in `_Held` isn't in the balance, and importing without it loses it |
| `_Received` (v6 `Once` names) | the game's own records. If receipts were granted with `Once = PurchaseId`, copy those ids into the v7 receipt list in the import, or Roblox's resend of an old receipt grants again |
| Other underscore fields | drop them. They're v6's bookkeeping |
| Shared stores (guilds, markets) | the same `Import` op per key, from an admin script that lists the old keys with `DataStoreService` `ListKeysAsync` on the v6 store's name, skipping keys v6 made for itself (its tally shards: check v6's source) |
| Tallies (`Bump`/`Total`) | one admin `Bump` of the old total into the v7 total, with an `Id` and `IdAt` so a rerun counts once; or add the old number as a constant where it's shown |
| `Reserve` holds | none. Let open checkouts finish before the switch |
| Erased players | v6 folds them to `Default`, so they import as defaults. Fine |

**Run the import on the mock and in a test universe before any live player meets it.** Once every active
player has been imported, the v6 package can come out.

## 3. The import op

The docs' version is `learn/changing-data#data-from-before-ledger`. For a v6 import it looks like this:

```luau
if Op.Kind == "Import" then
	if Data.IsImported then
		return nil
	end

	local Receipts = table.clone(Data.Receipts)
	for _, PurchaseId in Op.Receipts do
		if not table.find(Receipts, PurchaseId) then
			table.insert(Receipts, PurchaseId)
		end
	end

	local New = table.clone(Data)
	New.Gold += Op.Gold
	New.Inventory = Op.Inventory
	New.Receipts = Receipts
	New.IsImported = true
	return New
end
```

```luau
local function Import(Player: Player, Session: Ledger.TypedSession<PlayerData, PlayerOps>)
	if Session:Get().IsImported then
		return
	end

	local Old, Why = OldStore:Peek(Player.UserId):Wait()
	if Old == nil then
		Player:Kick("We couldn't load your old data. Please rejoin in a minute.")
		return
	end

	if next(Old._Held or {}) ~= nil then
		OldStore:RecoverTransfers(Player.UserId):Wait()
		Player:Kick("Your old data is still settling. Please rejoin in a minute.")
		return
	end

	Session:Commit({
		Kind = "Import",
		Gold = Old.Gold,
		Inventory = Old.Inventory,
		Receipts = ReceiptIdsFrom(Old._Received),
	})
end
```

The edge cases that matter:

- **The op is additive and refuses a second run.** Gold is added, not set, so gold the player earned on
  v7 before the import landed (a receipt, a gift) isn't overwritten. `IsImported` makes a second import,
  from a second server or a rejoin, a refusal.
- **v6's `nil` is a failed read, not a new player.** v6 answered a fresh key with its `Default`, so `nil`
  always means it couldn't read. Kick and let them rejoin; don't import zero.
- **`Commit`, not `Apply`.** The import must be durable before the player spends what it gave.
- **`Unresolved` on the import** is fine: Ledger keeps sending it, and the reducer refuses a second one.
  Don't resend it under a new name.
- **`ReceiptIdsFrom` is the game's to write.** v6 keeps `Once` names in `_Received` in its own layout,
  tagged and kept 30 days; read v6's `Core/Applied.luau` for it rather than guessing. Only names given
  as `Once = PurchaseId` are receipts.
- **A big inventory can ride in the op.** The 4,096-byte limit on terms is for `Tx` and `Take` legs only.
- **v6 shapes v7 refuses.** Arrays with gaps, mixed keys, `NaN`, number-keyed sets: the `Commit` answers
  `Invalid`. Convert in the import code, and count how many players hit it.
- **v6's machinery runs while the v6 package is loaded.** Opening the old store starts v6's sweep and
  its close binding on every server. Only `Peek` it, and `RecoverTransfers` for `_Held`. Never write
  game ops through v6 after the switch.

## 4. Config

| v6 | v7 |
|---|---|
| `Keys` optional | `Keys = "Player"` or `"String"`, required |
| (implicit) | `MustExist` and `Erasable`, both required. Decide `Erasable` now, before the store holds a key |
| `Balance = "Gold"` | `Balances = { Gold = { Credit = "AddGold", Debit = "SpendGold", Max = ... } }`. Those kinds never reach the reducer |
| `Shards`, `BumpEvery` | `Totals = { Name = { Shards = 16 } }`; no batching option, bumps batch per shard on their own |
| `Migrations = { Step }` or `{ Apply, Compatible = true }` | `{ Run, Fields = { "NewField" } }` for an added field, `{ Run, IsBreaking = true }` otherwise. The new store starts with an **empty** list and `Default` in today's shape |
| `Mock = true` or `{ Players, CCU, Throttled }` | `Mock = Mock.New({ Players, CCU, Throttled })` from the `xoifaii/mock` package |
| `Hook` | gone |
| `OnLoadFailed` returning `true` to skip the kick | `OnLoadFailed` returns nothing; `Kick = false` skips the kick; `KickMessage` sets its text |
| `Ledger.New<<Data, Ops>>` | the same, and now every op the game sends is checked against `Ops` under `--!strict` |

## 5. Calls

Every answer now comes back straight away as `(Ok, Result, Info)`. Remove every `:Wait()`.

| v6 | v7 |
|---|---|
| `Store:Load(Player)` then `Store:Get(Player)` | `local Session, Why = Store:Load(Player)` |
| `Session:Apply("AddGold", { Amount = 5 })` | `Session:Apply({ Kind = "AddGold", Amount = 5 })` |
| `Session:Commit(Kind, Fields):Wait()`, `CommitOp(Op)` | `Session:Commit(Op)` |
| `Store:Edit(Key, Kind, Fields):Wait()`, `EditOp` | `Store:Edit(Key, Op)` |
| `Fields.Once = "receipt-123"` | a record in the data (`learn/purchases`), or `Edit(Key, Op, { Id = Name, IdAt = Ledger.Now() })` |
| `Store:Transfer(From, To, Amount, Id, Field)` | `Ledger.Tx({ Store:Leg(From, { Kind = "SpendGold", Amount = A }), Store:Leg(To, { Kind = "AddGold", Amount = A }) }, { Id = Id, IdAt = Ledger.Now() })` with those kinds in `Balances` |
| `Store:Tx(Id, { { UserId, Kind, Fields } })` | `Ledger.Tx({ Store:Leg(Key, Op), ... }, { Id = Id, IdAt = Ledger.Now() })` |
| `Reserve`, `Holds`, `Release`, `Confirm` on gold | an escrow store and `Ledger.Tx` (`guides/auctions-and-markets`) |
| `Reserve`/`Confirm` for limited stock | `Quantities`, then `Quantity:Take`, or `Hold`/`Confirm`/`Release` (`learn/limited-items`) |
| `Store:Bump(Name, Field, Amount)` | `Store:Bump(Name, Amount)`, in `task.spawn` |
| `Store:Total(Name, Field, MaxAge)` | `Store:Total(Name, MaxAge)` |
| `Store:Peek(Key, MaxAge):Wait()` | `Store:Peek(Key, MaxAge)`; a never-saved key is now `nil, Missing`, not `Default` |
| `Session:DidApply(Id)` returning a boolean | `Session:DidApply(Name, Options)` returning `(boolean?, Reason?, Info?)` |
| `Store:Erase(Key)` twice, 8 days apart | `Store:Erase(Key, { Id = Ledger.Id() })` once, on an `Erasable` store |
| `Ledger.Id()` returning text | `Ledger.Id()` returning an opaque name, or `nil, "Busy"`; for `Edit`, `Commit`, `Reset`, `Erase` only |
| `Resettle`, `RecoverTransfers`, `ClearDelivered`, `Ledger.Sweep` | `Store:Resettle(Key)`; the rest happens on its own |
| `History`, `PeekVersion`, `Compact`, `LogSize`, `LogBytes`, `Holds` | gone |
| reading `_Held`, `_Received` in game code | gone. `Store:Pending`, `Store:Losses` and `Inspect(Key).Book.Work` for support |

The meaning changes that bite hardest:

- **`Peek` of a never-saved key** was `Default` in v6 and is `nil, Missing` in v7. Code that did
  `Peek(Key):Wait().Gold` now indexes `nil`.
- **`Transfer` is a `Tx`.** v6's `Held` answer (money parked) is gone; a v7 trade either happens or
  doesn't, and `Unresolved` means it's still being driven.
- **`Once` is gone.** A name now rides in the options, and a string name without `IdAt` is untimed and
  throws unless the kind has an `Untimed` window. For purchases, a record in the data.
- **The reducer never sees balance kinds.** Delete their branches.

## 6. Answers

v6 had ten reasons, v7 has fifteen. `Held` is gone. `Unreadable`, `Expired`, `NoRoom`, `Missing`,
`Short` and `SoldOut` are new. Go through every place the game compares a reason, against
`learn/answers`. Unchanged: never retry `Refused`, never resend an unnamed write after `Unresolved`,
never treat `Spent` as success, never read `Behind` as "no data".

## 7. Reducers

The shape is the same: `(Data, Op) -> NewData or nil`, pure, never changing its input. Check each one
against `review.md` D8 to D11, remove the balance kinds' branches, and make sure every field it sets is
in `Default`.

## 8. Check, then ship

1. Type-check under `--!strict`. `Ledger.New<<Data, Ops>>` catches a wrong kind or a wrong field.
2. Run the game on the mock, import included, with v6 data made on v6's own mock.
3. Run it in a test universe with a copy of real v6 data shapes, and count import failures by reason.
4. Publish every place, then **shut down all servers**. v6 and v7 servers must never run side by side:
   a v6 server still saving a player after their v7 import is a change the import never sees.
5. Watch the import counts and the warnings for the first days. Keep the v6 package until active
   players have all imported.
