# Cross-server

There are no locks, so there is no such thing as an unreachable player. These methods
work on any UserId: online here, online elsewhere, or offline. They all append to the
same log the session folds, which is what makes them safe.

```
Peek(UserId) -> Future<State>                    read-only fold of their current record
Edit(UserId, Kind, Fields?) -> Future<()>        append one op to their log
Transfer(From, To, Amount) -> Future<boolean>    move a balance between two players
Tx(Legs) -> Future<boolean>                      atomic multi-player transaction
```

## Peek

```luau
local State = Ledger:Peek(UserId):Wait()
```

A read-only fold for display: profile viewers, support tooling, leaderboard hydration.
It is eventually consistent (their live session may hold unflushed ops), so show it,
never decide on it. Decisions belong to ops, where the reducer arbitrates.

## Edit

```luau
Ledger:Edit(UserId, "AddGold", { Amount = 500 })
```

Appends an op to any player's log. Offline, it folds on their next load. Online
elsewhere, their session folds it on its next flush (within the autosave interval).
The op goes through the same reducer as everything else, so an Edit cannot create an
invalid state any more than gameplay can.

This is the tool for offline rewards, support grants, and scheduled jobs.

## Transfer

```luau
local Ok = Ledger:Transfer(FromUserId, ToUserId, 100):Wait()
```

Moves a numeric balance between two players through an escrow: reserve the amount into a
held state on the sender, deliver to the receiver, settle the hold. Each leg is
single-key atomic and deduped by transfer id, so money is never minted, lost, or
double-spendable, and held money is unspendable.

A crash mid-transfer is completed automatically from the sender's held map on their next
load, or manually via `RecoverTransfers(UserId)`. There is deliberately no cancel: the
sender's side cannot see whether delivery landed, so a refund could mint. The fix for a
mistaken transfer is to complete it and transfer back.

Transfer requires your reducer to route two internal op kinds; if you only ever move one
field (gold), it works out of the box because the escrow ops carry their own semantics.
For swaps involving items, use [transactions](transactions.md) instead.

## Choosing between them

- One player, any change: `Edit`.
- Two players, one balance: `Transfer`. It works with either side offline and needs no
  coordination.
- Two to four players, arbitrary changes that must happen together or not at all: `Tx`.

## The one gotcha

An owning session only notices foreign appends on its next flush, so up to the autosave
interval can pass before an online player's screen reflects an `Edit` from elsewhere.
Force it with `Session:Flush()` if you need it sooner.
