# Cross-server

There are no locks, so there is no such thing as an unreachable key. These methods work on
any key: a player online here, online elsewhere, or offline, and on an entity store, any
string key at all. They all append to the same log the session folds, which is what makes
them safe.

- `Store:Peek(Key)` is a read-only fold of the current record.
- `Store:Edit(Key, Kind, Fields?)` appends one op to a key's log.
- `Store:Transfer(From, To, Amount)` moves a balance between two keys.
- `Store:Tx(Legs)` runs an atomic multi-key transaction.

On a player store a key is a UserId. On an entity store it is a string. Everything below uses
a UserId; the entity store section covers the difference.

## Peek

```luau
local State = Store:Peek(UserId):Wait()
```

A read-only fold for display: profile viewers, support tooling, leaderboard hydration. It is
eventually consistent (a live session may hold unflushed ops), so show it, never decide on it.
Decisions belong to ops, where the reducer arbitrates.

## Edit

```luau
Store:Edit(UserId, "AddGold", { Amount = 500 })
```

Appends an op to any key's log. Offline, it folds on the next load. Online elsewhere, that
session folds it on its next flush (within the autosave interval). The op goes through the
same reducer as everything else, so an Edit cannot create an invalid state any more than
gameplay can.

This is the tool for offline rewards, support grants, and scheduled jobs.

## Transfer

Transfer moves one numeric balance, so the store has to know which field that is. Name it with
`Balance` when you build the store:

```luau
local Store = Ledger.New({
	Name = "PlayerData",
	Default = { Gold = 100 },
	Balance = "Gold", -- the field Transfer moves
	Reducer = Reducer,
})

local Ok = Store:Transfer(FromUserId, ToUserId, 100):Wait()
```

It moves the balance through an escrow: reserve the amount into a held state on the sender,
deliver to the receiver, settle the hold. Each leg is single-key atomic and deduped by
transfer id, so money is never minted, lost, or double-spendable, and held money is
unspendable. Without `Balance` named, `Transfer` warns and returns false.

A crash mid-transfer resolves itself. On the sender's next load, or when an operator calls
`RecoverTransfers(UserId)`, any stranded hold is finished: a recent one re-drives to the
receiver, and one past a week is settled if the delivery landed or refunded to the sender if
it did not. Delivery ids are remembered for thirty days, so inside that window the receiver's
record is authoritative and a refund is safe. Past it the record may have pruned the id, so a
hold with no matching delivery is settled rather than refunded, because a wrong refund would
mint; it warns so you can compensate from the audit log if the transfer never actually
delivered. That only arises when a sender is gone for over a month after a crash in the settle
step. You never have to reconcile a stuck transfer by hand.

For swaps involving items, or anything beyond one balance, use
[transactions](transactions.md) instead.

## Entity stores

Build a store with `Keys = "String"` and it is keyed by plain strings instead of player ids.
This is for shared state that no single server owns: a clan bank, a market listing, a global
record. Many servers write the same key at once, and the validating fold is the arbiter,
which is exactly the case a session lock cannot serve because no server can hold the lock.

```luau
local Clans = Ledger.New({
	Name = "Clans",
	Keys = "String",
	Default = { Gold = 0, Motd = "" },
	Balance = "Gold",
	Reducer = ClanReducer,
})

Clans:Edit("sunreavers", "Deposit", { Amount = 100 })
local Bank = Clans:Peek("sunreavers"):Wait()
```

An entity store gets the cross-server surface only: `Peek`, `Edit`, `Transfer`, `Tx`,
`History`, `Reset`, `Erase`. There is no `Load`, no resident session and no autosave, because
there is no player to attach a session to. Keys are strings of 1 to 50 characters, validated
as UTF-8; a number, an empty string or an over-long key is refused benignly.

Do not route a global counter through an entity store. A log of a million `{ Add, 1 }` ops is
pure churn with nothing for a reducer to validate. A counter wants a sharded `UpdateAsync` on
plain keys instead.

## Choosing between them

- One key, any change: `Edit`.
- Two keys, one balance: `Transfer`. It works with either side offline and needs no
  coordination.
- Two to four keys, arbitrary changes that must happen together or not at all: `Tx`, including
  legs that span two different stores.

## Keep in mind

An owning session only notices foreign appends on its next flush, so up to the autosave
interval can pass before an online player's screen reflects an `Edit` from elsewhere. Force it
with `Session:Flush()` if you need it sooner.
