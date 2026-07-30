# Cross-server

No locks, so no unreachable key. Everything here works on a player online in this server,
online somewhere else, or offline, and on any entity key.

```luau
Store:Peek(Key)                       -- Future<State>, read only fold
Store:Edit(Key, Kind, Fields?)        -- Future<boolean, Reason?>, append one op
Store:DidApply(Key, Name)             -- Future<boolean>, has a Once name landed here
Store:Transfer(From, To, Amount, Id?) -- Future<boolean, Reason?>, move the Balance field
Store:Tx(Id, Legs)                    -- Future<boolean, Reason?>, atomic multi key
```

| Shape | Use |
| --- | --- |
| one key, any change | `Edit` |
| one key, at most once under a name you own | `Edit` with `Once` |
| two keys, one balance | `Transfer` |
| two to four keys, arbitrary changes, all or nothing | `Tx` |

## Peek

```luau
local State = Store:Peek(UserId):Wait()
print(State.Gold)
```

For display: profile viewers, support tools, leaderboards. Eventually consistent, because a
live session may hold unflushed ops. Show it, never decide on it.

## Edit

```luau
Store:Edit(UserId, "AddGold", { Amount = 500 })
```

Offline, it folds on their next load. Online elsewhere, that session folds it on its next
flush. Same reducer as everything else, so it can be refused:

```luau
local Ok, Why = Store:Edit(UserId, "SpendGold", { Amount = 500 }):Wait()
-- false, "Refused"     the reducer said no
-- false, "Invalid"     the fields cannot be stored
-- false, "Unresolved"  no settled answer: the write may still land, or a stuck transaction holds the verdict open
```

The tool for offline rewards, support grants, and scheduled jobs.

## Edit with Once

When the id belongs to something outside Ledger, name the op and it lands at most once on that key,
no matter how many servers replay it or how often:

```luau
Store:Edit(UserId, "AddGold", { Amount = 500, Once = `order:{OrderId}` }):Wait()
Store:DidApply(UserId, `order:{OrderId}`):Wait()   -- true, and still true on every replay
```

A replay answers `false` with `Refused`, because it changed nothing. Read `DidApply` for the question
you actually mean, which is whether the grant has ever landed.

Two servers replaying the same name at the same time is the case this is built for: one applies, and
both see `DidApply`. There is no lock, so neither is shut out and neither has to give up.

## Transfer

Name the field first:

```luau
local Store = Ledger.New({
	Name = "PlayerData",
	Default = { Gold = 100 },
	Balance = "Gold",
	Reducer = Reducer,
})

local Ok, Why = Store:Transfer(FromUserId, ToUserId, 100, `trade:{TradeId}`):Wait()
if Ok then
	Gui:Confirm()
elseif Why == "Refused" then
	Gui:Error("not enough gold")
elseif Why == "Busy" then
	Gui:Retry()
else
	Gui:Pending("this may still go through")
end
```

Reserve on the sender, deliver to the receiver, settle the hold. Each leg is single key atomic
and deduped by id, so money is never created, lost, or spent twice, and held money is
unspendable.

| Reason | What happened | What to do |
| --- | --- | --- |
| `Refused` | not enough balance | permanent, tell the player |
| `Busy` | a transaction holds the sender's key, nothing applied | try again in a moment |
| `Spent` | this id was already refunded past its horizon | use a new one |
| `Unresolved` | no final answer yet | re-read rather than retrying blind |

**Name the transfer.** With an id everything dedupes, and a retry of a completed transfer
returns `true` without moving anything again. Derive it from the thing being paid for, a trade
or receipt or order id, never from the clock. Without one, a second call is a second transfer,
so treat any failure as unresolved and leave it to recovery.

`Unresolved` means Ledger is still finishing it. Re-read the keys later. Never call it again
under a new id, which would be a second transfer.

### Crash recovery

Nothing to call. A player key recovers on the sender's next load, and any key recovers on the
background sweep, the same one that settles stranded transaction legs. `RecoverTransfers` stays
an operator tool for when you would rather not wait:

```luau
Store:RecoverTransfers(UserId):Wait()
```

| Age | What happens |
| --- | --- |
| under 7 days | tries to hand the money over again |
| 7 to 8 days | left alone, a quiet gap so a delivery in flight is never read as missing |
| past 8 days | settles if the delivery landed, refunds the sender if it did not |

Past 30 days a delivery with no record is settled rather than refunded, because refunding it
could pay the sender twice. It warns so you can pay them back by hand from the audit log. That needs a
sender gone for over a month after a crash mid transfer.

## Entity stores

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

Plain string keys, 1 to 50 characters, for shared state no single server owns: clan banks,
market listings, world records. Many servers write the same key at once and the fold arbitrates,
which is exactly what a session lock cannot do, because no server can hold it.

Cross-server surface only: `Peek`, `Edit`, `Transfer`, `Tx`, `History`, `Reset`, `Erase`. No
`Load`, no session, no autosave.

Dedupe bookkeeping lives in the key's own state and prunes at thirty days. Roughly sixty bytes
per named transfer or transaction, so a key taking five hundred a day carries about a megabyte
of its four. Size for it; it is bounded, not a leak.

Do not route a global counter through one. A million `{ Add, 1 }` ops is churn with nothing to
validate; that wants a sharded `UpdateAsync`.

## Why Transfer and not a two leg Tx

Contention and cost, not convenience.

- **A transaction holds a key; a transfer does not.** Ten servers depositing into one clan bank
  means one commits and nine answer `Busy`. Ten transfers all land.
- **A transfer is a third of the traffic.** Three writes plus one read, against roughly ten for
  a two leg transaction.
- **A stranded transfer heals itself**, on the sender's next load or on the sweep.

Reach for `Tx` when the two sides are *different kinds of change* and both must hold, like gold
one way and an item the other.

## Keep in mind

An owning session only sees foreign appends on its next flush, so up to the autosave interval
can pass before an online player's screen reflects an `Edit`. Force it:

```luau
Store:Get(Player):Flush():Wait()
```
