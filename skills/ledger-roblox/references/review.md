# Reviewing a game's Ledger code

The bugs worth finding here don't throw, don't fail a test, and don't look wrong in a diff. They pay a
player twice, lose a purchase, or leave a key that answers `Unresolved` for half an hour, and they
surface weeks later, under load, or during the one DataStore outage nobody was watching. Every
detector below is one of those, and most were found the hard way: a developer built a game on Ledger 7
for a simulated year, and each of these shipped in code that type-checked and answered `true`.

Work through the detectors first. Each says what the code looks like, why it survives review, what it
costs, when it fires, and **what is not a match**, because a review that cries wolf gets ignored and
then the real finding is missed too.

Report a finding as: the file and line, what happens, when it fires, and the smallest change that
fixes it. Don't rewrite the game.

---

## D1. An unnamed write sent again after `Unresolved`

**Shape.** Any loop or second call around an `Edit`, `Commit`, `Tx`, `Take` or `Bump` that has no
`Id`.

```luau
for Attempt = 1, 3 do
	local Ok, Why = PlayerStore:Edit(UserId, { Kind = "AddGold", Amount = Reward })
	if Ok or Why ~= Ledger.Reason.Unresolved then
		break
	end
	task.wait(2)
end
```

**Why it survives review.** It looks like resilience. Every DataStore wrapper the reviewer has seen
retries, and the loop only runs during an outage, so tests never reach the second pass.

**What it costs.** Ledger names every unnamed write itself, and when one answers `Unresolved` this
server's writer **keeps sending that op** about every 16 s for the server's life. The loop's second
call is a second op with a second name. When the DataStore comes back, both land: the reward is paid
twice, three times with three attempts. For a `Tx` it is two trades.

**When it fires.** Every DataStore outage longer than about 30 s, on every player who hit the path
during it. Many players at once, all doubled.

**Fix.** Don't resend. Wait on `Info.Outcome` if the game needs to know how it ended. If the game truly
needs its own resend (a call from another server, a support tool), name the op once with `Id` and
`IdAt = Ledger.Now()` and resend those same options.

**Not a match.** A loop on `Busy` or `NoRoom`: nothing was sent, so sending again is right. A resend
with the same `Id`, the same `IdAt` and the same terms. A loop on `Unresolved` around a **read**.

---

## D2. `Unresolved` treated as a failure

**Shape.** Any `if not Ok then` that refunds, unlocks, tells the player it failed, or journals "failed"
before it has looked at the reason.

```luau
local Ok = Ledger.Tx(Legs, Options)
if not Ok then
	Trades[TradeId] = nil
	Unlock(Seller, Buyer)
	Notify(Seller, "Trade failed")
end
```

**Why it survives review.** The boolean is false, so failure is the obvious reading, and in testing it
never comes back.

**What it costs.** `Unresolved` means Ledger doesn't know, and the sending server is still driving the
change. A `Tx` keeps going with no time bound while its server lives, and commits when the DataStore
comes back. The players were told it failed and unlocked, so they trade again under a new name, and
both trades commit.

**When it fires.** During an outage, and only then, so on many players at once.

**Fix.** Branch on it first. Keep the players locked and the UI on "still saving" until
`Info.Outcome` settles (in a `task.spawn`), or until a resend of the same name answers something
definite.

**Not a match.** Code that checks `Why == Ledger.Reason.Unresolved` first and then falls through to a
generic failure path. That is handling it.

---

## D3. A name made fresh on every attempt

**Shape.** An `Id` or an `IdAt` built inside the call, or inside the retry loop.

```luau
local function Send()
	return Ledger.Tx(Legs, { Id = "trade:" .. HttpService:GenerateGUID(false), IdAt = Ledger.Now() })
end
```

```luau
Ledger.Tx(Legs, { Id = TradeId, IdAt = os.time() })
```

**Why it survives review.** A GUID is the normal way to make something unique, and `Ledger.Now()`
reads like "the time of this call". The happy path is correct.

**What it costs.** A name is the only thing that makes a resend land once. A new `Id` per attempt makes
every resend a new trade. A new `IdAt` with the same `Id` is worse than it looks: the key judges
whether it still remembers a name from its `IdAt`, so a later `IdAt` can make a forgotten name look
new, and it applies a second time. `os.time()` counts from 1970 where Ledger counts from 2026, so it
reads as decades ahead and throws, and inside a `task.spawn` that throw is never seen.

**When it fires.** Only on a resend, so never in testing, and on every resend in production.

**Fix.** Make the options table once, where the trade or the purchase is created, keep it with the
trade, and pass the same table on every send.

**Not a match.** A GUID made once when the trade opens and stored on it. Look at where the name is
made, not at what it is.

---

## D4. A move redone while the first can still land

**Shape.** A lock, a "pending" flag or a cooldown that clears on a timer, on a timeout, or when the
player leaves, while the move it guards is still `Unresolved`.

```luau
local Ok, Why, Info = Ledger.Tx(Legs, Options)
if Why == Ledger.Reason.Unresolved then
	task.delay(30, function()
		Locked[Player] = nil
	end)
end
```

**Why it survives review.** Thirty seconds, or thirty minutes, sounds like plenty, and the lock has to
end somehow.

**What it costs.** There is no time limit on an `Unresolved` trade while its server lives: it was
measured committing after a 25-hour outage. Any lock shorter than the server's life lets the player
start the same move under a new name, and both commit. The same goes for a lock that lives in one
server's memory: the player can rejoin elsewhere and redo it there.

**When it fires.** Outages longer than the lock. The longer the outage, the more players it hits.

**Fix.** Keep the lock until `Info.Outcome` settles or a resend of the same name answers something
definite. For moves the game must never double, put the guard in the data: a record of the move's
id in the state that the reducer refuses twice, the way `learn/purchases` records receipts. That
guard survives server hops; a lock in memory does not.

**Not a match.** A move the reducer already refuses twice (one per player, a record of ids). A redo is
then refused, not doubled.

---

## D5. A `Future` timeout read as a "no"

**Shape.** `Outcome:Wait(Timeout)` and its first value read as a boolean.

```luau
local Saved = Info.Outcome:Wait(10)
if not Saved then
	Refund(Player)
end
```

**Why it survives review.** Everything else in Ledger answers a boolean first, so this reads the same.

**What it costs.** `Wait` returns **nothing** when the timeout runs out. `Saved` is `nil`, the code
refunds, and the change lands afterwards: paid back and paid. The real `false` comes with a reason.

**When it fires.** Whenever the outage outlasts the timeout.

**Fix.** Tell the two apart: `Outcome:Happened()` says whether it settled. With no answer yet, keep
waiting or keep the player on "still saving". Only a settled `false` is a no.

**Not a match.** `Wait()` with no timeout, inside a `task.spawn`.

---

## D6. A failed read treated as an empty one

**Shape.** Any read whose `nil` falls back to a default, a zero, or a fresh profile.

```luau
local Data = PlayerStore:Peek(UserId)
local Gold = if Data then Data.Gold else 0
```

```luau
OnLoadFailed = function(Player, Why)
	FreshProfiles[Player] = table.clone(DEFAULT)
end,
Kick = false,
```

**Why it survives review.** It reads as graceful degradation, and it stops a player being stuck.

**What it costs.** `nil` from a read always comes with a reason, and only `Missing` means nothing is
saved. `Unresolved`, `Busy`, `Behind` and `Unreadable` mean the data is there and this server couldn't
read it. A leaderboard shows zero for a rich player; a gift checks "has no pet" and gives a second; a
fresh profile saved over `Behind` destroys a real one. This is the most expensive line on the list,
because the overwrite can't be undone past Roblox's version window.

**When it fires.** During an outage, and during every rollout with a breaking migration, when old
servers answer `Behind` for players the new build already wrote.

**Fix.** Branch on the reason. `Missing` is a new player. Anything else is "don't know": show
"loading", try later, or for a load, let Ledger kick (the default) and send `Behind` players to a new
server.

**Not a match.** A read that only displays and says "loading" on `nil`.

---

## D7. `Spent` or `Expired` read as success, or `Expired` read as "didn't happen"

**Shape.**

```luau
if Ok or Why == Ledger.Reason.Spent then
	GiveItem(Player)
end
```

```luau
if Why == Ledger.Reason.Expired then
	PayAgain(Player)
end
```

**Why it survives review.** `Spent` sounds like "already spent", so a duplicate of something that
happened. `Expired` sounds like "it timed out, so it didn't go".

**What it costs.** `Spent` means this call changed nothing: the name was used with other terms, or a
trade under it ended without going through. Giving the item on it is giving it for free. `Expired`
means the key has forgotten the name, so it can't say anything about earlier sends. After an
`Unresolved`, the first send may well have landed; paying again on `Expired` pays twice.

**When it fires.** `Spent` on a name reused for a different move or a trade that was fenced. `Expired`
when a resend comes after the name's window (180 s by default), or sooner on a key whose name room
filled and dropped old names early.

**Fix.** `true` is the only answer that means it happened. On `Expired` after an earlier `Unresolved`,
compare the data with what the change would have done, and if the game can't tell, keep a record of
the move in the state so it can.

**Not a match.** Logging them separately, or treating `Spent` as "try again under a new name" after
checking that nothing happened.

---

## D8. A reducer that accepts what it doesn't handle

**Shape.** A dispatch that falls through to the input.

```luau
local Handler = Handlers[Op.Kind]
if Handler == nil then
	return Data
end
```

**Why it survives review.** It's what Redux and Rodux ask for, it reads as a harmless no-op, and every
test passes because the kinds under test all have handlers.

**What it costs.** Ledger reads any table as accepted. A kind nobody handles, a typo in a kind, or a
kind from an older or newer build is applied as "nothing changed", and the caller gets `true`. In a
`Tx` that leg commits while doing nothing: the buyer's typo'd `BuyItm` takes no gold and the seller is
paid. Studio warns about this once at `Ledger.New` (it sends an unknown kind as a probe); a live server
says nothing.

**When it fires.** The first time an unhandled kind arrives: a typo in an untyped call, a feature flag,
a kind during a rollout.

**Fix.** End the reducer with `return nil`.

**Not a match.** A handler that returns `Data` on purpose for a known kind whose job is only to be
recorded or refused.

---

## D9. A reducer that changes the table it was given

**Shape.** `Data.Gold += Op.Amount`, `table.insert(Data.Items, Op.Item)`, `Data.Pets[Id] = nil`, then
`return Data`. Also a clone of the top table only, then a change one level down.

```luau
local New = table.clone(Data)
New.Inventory[Op.Item] = (New.Inventory[Op.Item] or 0) + 1
return New
```

**Why it survives review.** It looks like a clone. Studio throws on it, so the bug lives in branches
nobody ran in Studio: a rare kind, an admin path, a nested table one level below the clone.

**What it costs.** Inputs are frozen **only in Studio**. On a live server the change lands in Ledger's
own copy of the state, the one it judges the next op against and lays queued ops on. The data drifts
from what was saved, silently, until a refresh or a rejoin shows something else.

**When it fires.** On every live call through that branch.

**Fix.** Clone every table on the path you change, top table first.

**Not a match.** Sharing unchanged sub-tables between the old and new state. That is fine and cheap.

---

## D10. A reducer that isn't a pure function of its two arguments

**Shape.** `os.time`, `os.clock`, `DateTime`, `math.random`, `Random.new`, `game:GetService`, a
`Player`, an upvalue that changes (a config table, a "double gold" flag), or a read of another key.

**Why it survives review.** It gives the right answer every time you check it.

**What it costs.** Ledger runs the reducer several times for one op: on the session's view, again at
the save, again when queued ops are laid on fresh data, again in a trade's tentative step. A clock or a
dice roll gives a different answer each time, so the op the player saw is not the op that was saved,
or it is refused at the save after the player saw it succeed. A "double gold weekend" flag read in the
reducer pays double or single depending on when the save ran.

**When it fires.** On every op, most visibly around the moment a flag or a day flips.

**Fix.** Work the value out in the script and put it in the op: `{ Kind = "OpenEgg", Pet = Pet }`,
`{ Kind = "ClaimDaily", Day = Today }`, `{ Kind = "AddGold", Amount = Base * Multiplier }`.

**Not a match.** Reading the clock or rolling the dice at the call site to build the op. That's the
fix.

---

## D11. A reducer that writes a field the store doesn't declare

**Shape.** A field set by the reducer that isn't in `Default` and isn't in an additive migration's
`Fields`, or a field that is `nil` in `Default`.

```luau
Default = { Gold = 0, Title = nil },
```

**Why it survives review.** Lua tables take any key, and `nil` reads like "no title yet".

**What it costs.** Only `Default`'s fields and additive migrations' `Fields` are declared, and `nil` in
`Default` declares nothing. Every op that sets an undeclared field is refused. Ledger warns once per
store and field, and after that every such op is just `Refused`, which the game probably shows as
"not enough gold".

**When it fires.** On every op that sets the field, from the first one.

**Fix.** Give the field a real value in `Default` (`0`, `""`, `{}`) and add an additive migration with
`Fields = { "Title" }` for keys saved before it existed.

**Not a match.** Fields inside a nested table. Only top-level fields are declared; but see D21 for
nested fields added without a migration.

---

## D12. A purchase guarded by anything but a record in the data

**Shape.** One of these inside `ProcessReceipt` or `BindReceiptHandler`:

```luau
local Ok = PlayerStore:Edit(Receipt.PlayerId, Op, { Id = Receipt.PurchaseId })
return if Ok then Granted else NotProcessedYet
```

```luau
Session:Apply({ Kind = "GrantPurchase", PurchaseId = Receipt.PurchaseId, Gold = Gold })
return Granted
```

**Why it survives review.** The first purchase works, and every manual test is a first purchase.

**What it costs.** A `PurchaseId` has no first send time, so as an `Id` it is an **untimed** name: it
throws unless the kind's `Windows[Kind].Untimed` was set, and once set it protects only inside that
window. Roblox resends an unanswered receipt the next time the player buys or joins, which can be days
later, and then it grants again. Answering from the boolean alone answers `NotProcessedYet` for ever
once a retry is refused as a duplicate. `Apply` answers before anything is saved, so a crash in the
next 30 s loses a grant Roblox was told happened.

**When it fires.** On any receipt resend: a lost acknowledgement, a player who switched servers
mid-purchase, an outage.

**Fix.** The pattern in `learn/purchases`: the op records the `PurchaseId` in the player's data and the
reducer refuses an id it already holds; `Store:Edit` with no `Id`; `true` is granted; `Refused` with
the id in `Info.State` is granted; anything else is `NotProcessedYet`.

**Not a match.** That pattern. Check the record is bounded (D21) and that its bound is far above any
resend delay: the docs keep 1,000 ids, and a game that kept 100 was found to grant twice after 100
newer purchases.

---

## D13. An `Apply` that tells something outside the game it happened

**Shape.** `Session:Apply(...)` followed by a badge, a webhook, a Discord log, a purchase answer, a
leaderstat bump, or another player's reward, with no look at the fate.

**Why it survives review.** `Apply` is the right call almost everywhere, and it answered `true`.

**What it costs.** `Apply` is judged on the session's view and saved later. The save judges it again,
and a trade or another server's write in between can turn it away (`Turned` fate). A crash before the
save loses it with no fate at all. Whatever was told outside the game can't be taken back.

**When it fires.** On a turned-away save, which needs two writers on one key: a trade, a gift, an
`Edit` from another server. And on every crash inside a save window.

**Fix.** `Commit` (or `Edit`) for anything with a side effect outside the data, and act on its `true`.
Or `Apply`, then act in the `ObserveFates` listener on `Took`.

**Not a match.** `Apply` for gameplay, shown from `Session:Observe()`. A turned-away op leaves the
view, so the screen corrects itself.

---

## D14. A trade on a loaded player with no `Flush` before it or `Refresh` after

**Shape.** `Ledger.Tx`, `Take` with legs, or a `Store:Edit` on a key whose session is loaded on this
server, with no `Session:Flush()` first and no `Session:Refresh()` after.

**Why it survives review.** The trade answers `true` and the data is right.

**What it costs.** A trade is judged on the **saved** data, not the session's view. Without the
`Flush`, gold the player just spent with `Apply` is still in the saved data, so the trade spends it
too, and the queued `Apply` is turned away at the next save: the player keeps the item they "bought"
in the view for up to 30 s, then it vanishes. Without the `Refresh`, the player doesn't see the trade
for up to two minutes, and a game that reads the view to build the next trade builds it on stale data.

**When it fires.** Every trade that follows an `Apply` within a save window, which in a busy game is
most of them.

**Fix.** The `FlushIfHere` and `RefreshIfHere` helpers in `learn/trading`, looked up fresh each time.

**Not a match.** A trade between players who aren't on this server. Their servers see it at their next
save or idle read; `learn/shared-data` shows how to nudge them.

---

## D15. A hot shared key held by a trade's mark

**Shape.** A `Tx` with a game-op leg on a key every server writes (a shop index, a guild roster, an
auction list) that is **not** the decider. Remember the rule: the only game-op leg decides if there is
exactly one, else the first Credit leg, else the last leg.

```luau
Ledger.Tx({
	MarketStore:Leg("Index", { Kind = "Add", Listing = Id }),
	PlayerStore:Leg(Seller, { Kind = "ListItem", Item = Item }),
})
```

**Why it survives review.** The order of legs looks cosmetic.

**What it costs.** Every game-op leg off the decider takes an exclusive mark that holds that key's game
ops until the trade ends: seconds normally, and up to about 30 minutes if the sending server dies
mid-trade. On the index that's every listing on every server, waiting. A key takes 16 marks; the 17th
leg answers `NoRoom`. Here the last leg (the seller) decides, so the index is held.

**When it fires.** At scale, and catastrophically when a server dies mid-trade.

**Fix.** Order the legs so the hottest key decides: put it last when every leg is a game op, or make
the money legs balance kinds so they only escrow. Comment the order where the legs are built, because
the rule belongs to this release. Split a hot index over shard keys.

**Not a match.** Two players' own keys. One player can't make a key hot.

---

## D16. A store not opened on every server that meets its keys' work

**Shape.** A place, or a script path, that never requires the module opening a store the game uses in
trades or takes. The classic case is a second place (an arena, a lobby) that opens `PlayerData` but
not `Market` or `LimitedStock`.

**Why it survives review.** That place never calls the market, so it doesn't seem to need the store.

**What it costs.** A trade leaves work on each key that names the other keys' stores. Only a server
with those stores open can end it. On a server without them, `Peek` and `Inspect` of that player answer
`Unresolved`, the work is never ended there, and an escrowed amount stays unavailable. Ledger warns
once per pair of stores, naming the store to open.

**When it fires.** When a player who just traded joins the other place, for that server's life.

**Fix.** One `Stores` module that opens every store the game has ever sent a `Tx` or `Take` through,
required by every place's main script before anything else. `Ledger.New` sends no request, so opening
a store costs nothing. Keep retired stores in it.

**Not a match.** A store only ever written with `Edit`, `Commit` and `Apply` and never in a trade.

---

## D17. A quantity opened on `Missing` with no guard

**Shape.**

```luau
local Ok, Result = Stock:Take(1, Options)
if Result == Ledger.Reason.Missing then
	Stock:Open()
end
```

**Why it survives review.** The docs say "open it once if it was never opened", and this does.

**What it costs.** After `Close` removes a quantity's empty parts, `Take` answers `Missing` again, the
same as never opened. This code opens it again, which makes the whole stock again: a limited item that
sold out sells a second batch, with the same serial numbers. Also, every `Open` costs one write per
part even when nothing changes.

**When it fires.** After the event ends and `Close` has run, the next time anyone tries to buy.

**Fix.** Open only while the sale is on, and once per server: a time check, a flag, or `Closed = true`
on the quantity's declaration once it's retired (then `Open` throws in this build). A restock is a new
quantity name.

**Not a match.** An `Open` from an admin command, once, before the sale.

---

## D18. A named take treated like an unnamed one on `Short`

**Shape.** A retry of a `Take` with the same `Id` after `Short`, or an unnamed take's `Short` treated as
sold out.

**Why it survives review.** `Short` reads like `Busy`: "not now".

**What it costs.** A game-named take that answers `Short` records that answer under its name. A resend
of the same name answers `Short` again even after units come back, so a buy button that resends never
succeeds. The other way round: an unnamed take tries at most 3 parts and can answer `Short` while
other parts still hold units, so a game that shows "sold out" on `Short` stops selling early.

**When it fires.** Whenever holds or a busy sale leave a part empty for a moment.

**Fix.** On `Short`, a named take needs a **new** name to try again. `SoldOut` is the only "gone for
good". Use named takes when the take matters, so the walk covers every part.

**Not a match.** Resending the same name after `Busy` or `Unresolved`, which is right.

---

## D19. Totals bumped the expensive or the wrong way

**Shape.** Any of: a named `Bump`; `Bump` on a remote's thread or a player's join; a bump before the op
it counts has saved; bumps started from fate listeners or `BindToClose` at shutdown.

```luau
StatsStore:Bump("CoinsSpent", Price, { Id = HttpService:GenerateGUID(false), IdAt = Ledger.Now() })
```

**Why it survives review.** Naming writes is good practice everywhere else, and the bump is one line.

**What it costs.** A named bump keeps its name 180 s on its shard in a 12,288-byte room; one shard write
carries about 59 new GUID names, the rest answer `Busy`, and a full room cuts the shard to a fraction
of its write rate. Measured: 3,000 named bumps from 5 servers counted 1,599; 3,000 unnamed bumps
counted 3,000. `Bump` yields 0 to 60 s (90 s when writes fail), so on a remote's thread the player
waits a minute. A bump before the op saved counts sales that didn't happen. Bumps started once the
close has begun answer `Closed` and are lost.

**When it fires.** Under load, every time. At every shutdown, a little.

**Fix.** Unnamed bumps, in `task.spawn`, after the op answered `true` (or its fate is `Took`). Retry
only `Busy`; never resend an unnamed bump after `Unresolved`, because the writer is still sending it.
Totals are statistics; don't pay anyone from one.

**Not a match.** A named bump on a quiet total where an exact count across a server's restart matters
more than throughput.

---

## D20. A decision made on a shared copy

**Shape.** `Peek(Key, MaxAge)` or a `Follow` value used to decide something that moves money: whether
a bid is high enough, whether a listing is still there, whether a guild can afford a purchase.

**Why it survives review.** It's the documented cheap read, and the numbers look right.

**What it costs.** A `MaxAge` read can be minutes old: the shared copy lags up to about 4.5 minutes on
a quiet key, and right after this server's own write a `MaxAge` read can still return the copy from
before it. On an old build during a rollout, a server that hasn't yet read the key itself can serve
the copy from before the new build fenced it.

**When it fires.** On a busy key, every few seconds.

**Fix.** Let the op check: the reducer refuses a bid that doesn't beat the current one, a buy of a
listing that is gone, a purchase the bank can't afford. Then the read only shapes the UI and a stale
one costs a refusal, not money. Where the decision must be made outside the reducer, use a plain
`Peek(Key)`, or `{ Fresh = true }` when it must be current.

**Not a match.** A `MaxAge` read that only displays (a leaderboard, a guild panel), or one whose
decision the reducer checks again.

---

## D21. State that only grows, or a shape that can't be stored

**Shape.** An array appended on every action (a purchase log, a match history, a receipt list with no
trim), a set keyed by `UserId` as a number, or a nested field added to existing players with no
migration.

**Why it survives review.** It's small in testing, and the cap is far away.

**What it costs.** A key holds about 4 MB, and Ledger warns past 2 MiB; past the cap writes answer
`Full`. Long before that, a key takes only about 4 MB of writes a minute, so a 400 KB player can be
saved about 10 times a minute across every server. A table with only number keys is an array, and an
array with gaps can't be stored: the op answers `Invalid`. A field added inside a nested table is
`nil` on every player saved before, because only top-level fields are carried for you.

**When it fires.** Months in, on the most engaged players, who complain the loudest.

**Fix.** Bound every list with an explicit trim. Use `tostring(UserId)` for sets keyed by player. Add a
migration for any new nested field.

**Not a match.** A bounded list with its bound written down.

---

## D22. A migration list that was edited after it shipped

**Shape.** In a diff: a migration entry changed, removed, reordered, or inserted before others; a
`Default` that isn't in the newest shape; an additive entry without `Fields`; a `Run` that can throw or
changes its input.

**Why it survives review.** It looks like tidying, and the edited step is "obviously equivalent".

**What it costs.** Migrations are identified by position. A key stores how many it has run. Change an
early entry and every key past it keeps the old result while new keys get the new one; reorder and
keys run steps they already ran. `Default` is never migrated, so a new key starts in whatever shape
`Default` is. A `Run` that throws fails the key: its reads answer `Unreadable`, its writes stay
`Refused`, and Ledger warns once per store, so one bad player shape locks that player out.

**When it fires.** At the next publish, per key, as players join.

**Fix.** Append only. Write `Default` in the newest shape. Copy the input and change the copy. Wrap
`Run` so a bad shape is repaired or left, not thrown on.

**Not a match.** A new entry appended at the end.

---

## D23. A declaration changed under live data

**Shape.** In a diff: a balance field removed from `Balances`, a field's `Arithmetic` changed, a total's
`Shards` changed, a quantity's `Parts`, `Mode`, `Stock`, `Serials` or `Proceeds` changed, a store's
`Name` or `Keys` changed, `Erasable` flipped.

**Why it survives review.** It looks like configuration.

**What it costs.** Each is stored with the data. Remove a balance field or change its arithmetic while
an older build holds escrow on it, and this build can't settle that escrow: every write to the key
answers `Unresolved` until an older server does. Change `Shards` and the total restarts from zero
under a new identity. Change a quantity and every op on its existing parts answers `Invalid`. Change
`Name` and every player is new.

**When it fires.** At the publish.

**Fix.** Keep old fields declared in `Balances` and move the value to a new field in a migration.
Declare a new total name or a new quantity name instead of editing one.

**Not a match.** Changing a kind's `Min` or `Max`, `Windows`, `SaveInterval`, `IdleReadInterval`:
those apply to later ops only.

---

## D24. A `Reset` or `Erase` name kept, shared, or used late

**Shape.** An `Erase` or `Reset` whose `Id` is a string, comes from a queue or a datastore, was drawn
at the start of a long job, or is reused across servers. Or an `Erase` whose `Cut.Losses` isn't logged.

**Why it survives review.** Names make things safe to retry everywhere else.

**What it costs.** A string `Id` throws. A `Ledger.Id()` name belongs to the server that drew it, and
that server answers `Expired` for it once it's `CutWindow` (6 minutes by default) old, sending nothing,
so a name drawn at the top of a slow GDPR job silently does nothing. `Cut.Losses`, the list of
balances the erase destroyed, comes only in the first `true`; a retry gets `true` without it.

**When it fires.** On a slow pass, and on every erase whose answer wasn't logged.

**Fix.** Draw `Ledger.Id()` just before each attempt; resend that name only within the same pass on
`Busy` or `Unresolved`; a new pass draws a new name. Log `Cut.Losses` from the first answer.
`learn/deleting-data` has the shape.

**Not a match.** No `Id` at all on a one-off admin `Reset`.

---

## D25. Saving in `BindToClose`, or data held where the close can't see it

**Shape.** `game:BindToClose` that calls Ledger, or round rewards, timers and carts kept in Lua tables
and written at the end of the round.

**Why it survives review.** That's how every other DataStore library is used.

**What it costs.** Ledger binds the close itself. By the time the game's own `BindToClose` runs, Ledger
is already closing and every new call answers `Closed`. Rewards held in a table die with the server.

**When it fires.** Every shutdown, including every update.

**Fix.** `Apply` changes as they happen. For data that must be held, `Ledger.BeforeClose(Fn)` runs `Fn`
first, for up to 5 s.

**Not a match.** A `BindToClose` that does non-Ledger work.

---

## D26. A Ledger call that waits, made inside a Ledger listener

**Shape.** `Edit`, `Commit`, `Tx`, `Peek`, `Flush` or `Outcome:Wait` inside a `Follow`, `Observe`,
`ObserveFates` or `Stale` subscriber.

**Why it survives review.** Event handlers in Roblox can usually yield.

**What it costs.** Ledger listeners run inline and must not yield. A call that would wait throws, and
the listener's error is caught and only warned, so the work silently doesn't happen.

**When it fires.** Every time the listener runs.

**Fix.** `task.spawn` the call. `Session:Apply` is allowed inside a listener; it answers at once.

**Not a match.** `Apply` or `Get` inside a listener.

---

## D27. A view used to build a trade

**Shape.** `Session:Get()` used to decide what a trade or a take sends: which serial goes with an item,
how much a guild can withdraw, whether the player has the last copy.

**Why it survives review.** The view is the player's data, and it's right there.

**What it costs.** A view can be up to two minutes behind changes made from other servers. A trade
built on it moves the wrong thing and every leg still answers `true`: in one game, a limited item's
serial number stayed with the giver because the view showed two copies when the key held one.

**When it fires.** When another server, or a support tool, changed the player shortly before.

**Fix.** Make the reducer check what the trade assumed (the op names the serial it expects, or the
count) so a stale build is refused and retried after a `Refresh`.

**Not a match.** A view used only to enable a button, when the op checks again.

---

## D28. Studio pointed at the live game

**Shape.** A place with Studio API access to the live universe and no `Mock` in Studio.

**Why it survives review.** Pressing Play feels like a test.

**What it costs.** A Studio session with API access is a full live server: it loads and writes real
players, stores migrations that fence the live servers' older build, runs the close, and can leave
trade work behind. With a newer Ledger in Studio, it can write keys the live servers can't read.

**When it fires.** Every Play in Studio.

**Fix.** In Studio, give the stores `Mock = Mock.New(...)`, or test in a separate universe.

**Not a match.** A separate test universe.

---

## After the detectors

Once those are done, the rest of a review, in the order a miss costs.

**Answers.** Every write's reason is read, and every read's reason is read. `Unresolved` is branched
first. Reasons compare against `Ledger.Reason`, never against literals typed by hand or against error
text. A game's own "DataStore is down" breaker is fed by first answers only: a resend loop on one key
that answers `Unresolved` for ever (a store not opened here, an unreadable key) can trip it for the
whole server.

**Lifecycle.** `Load` on `PlayerAdded` and for players already present. `Unload` on `PlayerRemoving`.
`Get` returns `nil` while a player loads; code that runs at join uses `WaitForLoaded`. A session object
isn't kept after `Unload`. `OnLoadFailed` doesn't let a player play on defaults.

**Budget.** Count requests per player per minute against the server's budget (60 + 40 per player for
reads and for writes). `Commit` is not on a click path. No plain `Peek` in a loop: a key many servers
poll is a `Peek(Key, MaxAge)` or a `Follow`. A rarely read key read with `MaxAge` makes this server
spend 2 reads a minute for 30 minutes.

**Contention.** Which keys does every server write? Each takes about 4 MB of writes a minute; a guild
bank, a shop index, a pot. Split them.

**Updates.** Migrations append only. A breaking migration ships with a full shutdown, or with players
sent to new servers on `Behind`. A logic fix (a lock, a guard) only protects servers on the new build:
old servers keep the old bug until they close. Every place of the universe runs the same Ledger
release and the same store configs.

**Destructive calls.** Who can reach `Reset`, `Erase`, `Quantity:Close`, `Destroy`? Is it behind an
admin check? Is the key from a player-supplied string? Is the answer checked and `Cut.Losses` logged?

**Support fixes.** A tool that pays a player by hand for a move that answered `Unresolved` pays twice
when the writer lands it. Fixes wait until the sending server is surely gone, and carry their own
ticket id in the state so a second click is refused.
