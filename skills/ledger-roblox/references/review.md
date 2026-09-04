# Reviewing a game's Ledger usage

The bugs worth finding here do not throw, do not fail a test, and do not look wrong in a diff. They
duplicate or destroy money, and they surface weeks later or only under load. Everything below is one
of those.

Work through the detectors first. Each one says what the code looks like, why it survives review,
what it costs, when it fires, and **what is not a match**, because a review that cries wolf gets
ignored and then the real one is missed too.

Report a finding as: the file and line, what happens, when it fires, and the smallest change that
fixes it. Do not rewrite the game.

---

## D1. A reducer that accepts what it does not handle

**Shape.** A handler table, a dispatch, and a fall through that returns the state.

```luau
local Handler = Handlers[Op.Kind]
if Handler == nil then
	return State        -- or: return table.clone(State), or an `or State` on the end
end
```

**Why it survives review.** It is what Redux and Rodux ask for, it reads as a harmless no-op, and
every test passes because the kinds under test all have handlers.

**What it costs.** Ledger reads any table as accepted. So an op nobody handles is applied. If it
carried a `Once` name, that name is written into `_Received` as granted while nothing was granted:
`DidApply` answers true, `ProcessReceipt` answers `PurchaseGranted`, and the player paid for nothing.
A transaction leg does the same and commits on a key that did nothing.

**When it fires.** The first time an op reaches the reducer without a handler. A kind from a newer
build during a deploy, a kind behind a feature flag, a typo in a kind name, or a retired kind still
in the log.

**Fix.** `return nil`.

**Not a match.** A handler that returns `State` deliberately, for an op whose whole job is to be
recorded, is fine and is not this. The tell is the `nil` handler branch, not the returned value.

---

## D2. Unresolved treated as a failure

**Shape.** Any `if not Ok then` that lumps `Unresolved` in with a refusal.

```luau
local Ok, Why = Store:Transfer(From, To, Amount, Id):Wait()
if not Ok then
	Refund(Player)              -- or: return false, or tell the player it failed
end
```

**Why it survives review.** The boolean is false, so treating it as failure is the obvious reading,
and in testing it never comes back.

**What it costs.** `Unresolved` means Ledger does not know. The write may have applied. Refunding,
retrying under a new name, or telling the player it failed all pay twice or hand out twice.

**When it fires.** Only during a datastore incident or against a key with a parked transaction leg.
So it fires exactly when nobody is watching closely, and on many players at once.

**Fix.** Branch on it. Retry under the same id, or read the key back, or ask `DidApply`.

**Not a match.** Code that checks `Why == Ledger.Reason.Unresolved` first and then falls through to a
generic failure path is handling it.

---

## D3. An id minted at the call site

**Shape.** An id generated inside the call, or derived from anything that changes.

```luau
Store:Transfer(From, To, 250, HttpService:GenerateGUID(false)):Wait()
Store:Tx(`trade:{os.time()}`, Legs):Wait()
Store:Edit(UserId, "Grant", { Once = `grant:{tick()}` }):Wait()
```

**Why it survives review.** A GUID is the normal way to make something unique, and the code is
correct on the happy path.

**What it costs.** The id is the only thing that makes a retry land once. A new id per attempt makes
every retry a fresh transfer, so the money moves again.

**When it fires.** Only on a retry. So it is invisible until the first incident, and then it
duplicates for every player who retried.

**Fix.** Mint the id where the thing being settled is created, a trade, an order, a receipt, and
read the same one on every attempt.

**Not a match.** A GUID minted once when a trade opens and stored on the trade is correct, even
though it is a GUID. Look at where it is created, not what it is.

---

## D4. A read compared truthily

**Shape.**

```luau
if Store:DidApply(UserId, Name):Wait() then          -- wrong
if Store:Peek(UserId):Wait().Gold >= Price then      -- wrong, and it can index nil
```

**Why it survives review.** It reads naturally and works whenever the datastore answers.

**What it costs.** Every read answers a value and a reason, and `nil` always means the read failed.
A failed `DidApply` read is `nil`, which is falsy, so a datastore hiccup reads as "never granted" and
the game grants a second time.

**When it fires.** Only when a read fails.

**Fix.** Compare against `true`. Handle `nil` as "do not know" and do nothing this time.

**Not a match.** `Session:DidApply` returns a plain boolean and cannot fail, so truthiness is fine
there. Only the store version answers `nil`.

---

## D5. A receipt answered from the write rather than from the name

**Shape.** Inside `ProcessReceipt`, deciding from the `Commit` or `Edit` result.

```luau
local Ok = Session:Commit("Grant", { ProductId = Id, Once = Name }):Wait()
return if Ok then Enum.ProductPurchaseDecision.PurchaseGranted else NotProcessedYet
```

**Why it survives review.** The first purchase works, and every manual test is a first purchase.

**What it costs.** A replay of an already granted receipt answers `Refused`, which is
indistinguishable from the reducer refusing. So the handler answers `NotProcessedYet` for ever, and
Roblox keeps retrying a purchase that was granted.

**When it fires.** On any replay, which Roblox does after a lost acknowledgement, and on a second
server if the player rejoins before the first answered.

**Fix.** Check `Unresolved` first, then answer from `DidApply`, which asks about the name rather than
about this call.

**Not a match.** Answering from `Session:DidApply` after `Commit`. That is the documented shape.

---

## D6. A grant answered before it is durable

**Shape.** `Apply` on the path that decides a receipt or a purchase.

```luau
Session:Apply("Grant", { Once = Name })
if Session:DidApply(Name) then
	return Enum.ProductPurchaseDecision.PurchaseGranted
end
```

**Why it survives review.** `Apply` is the right call almost everywhere else, and `DidApply` answers
true immediately, so it looks like it worked.

**What it costs.** `Apply` queues the op and writes nothing. `Session:DidApply` reads live state,
which includes the queue, so it answers true before anything is durable. If the server dies before
the next save, the receipt is answered granted and the grant is gone.

**When it fires.** Only on a crash or shutdown inside the 30 second autosave window.

**Fix.** `Commit` for anything that decides a receipt, or `Apply` then `Flush` before answering.

**Not a match.** `Apply` for gameplay. This is only about paths that tell something outside the game
that the thing happened.

---

## D7. A durable name on a hot shared key

**Shape.** A `Once` name, a `Transfer`, or a `Tx` leg on a key that many players write.

```luau
Shop:Edit("global-shop", "Sell", { Once = `order:{OrderId}` }):Wait()
```

**Why it survives review.** Naming a write is good practice everywhere else, and the key works fine
for months.

**What it costs.** Every name goes into `_Received` on that key, about 40 bytes, kept 30 days. At
roughly 1,700 a day the names alone reach the 2 MB state cap. The set is trimmed by age, not by
count, so once it is full it cannot be pruned back and the key stops taking writes for good.

**When it fires.** Weeks in, at scale, on the busiest key in the game. It does not recover.

**Fix.** Spread the entity over more keys before that point. `Edit`, `Reserve` and `Confirm` write no
name, so use them where a name is not needed.

**Not a match.** A name on a player's own key. One player cannot generate that rate.

---

## D8. A reducer branch deleted with the feature

**Shape.** A kind that the game once wrote and the reducer no longer handles. Look for kinds in the
game's history, in old op constants, in migration comments, or in a removed feature's code.

**Why it survives review.** The feature is gone, nothing writes the kind, and the branch reads as
dead code.

**What it costs.** Compaction absorbs the run of ops at the front that this build can apply. An op
it refuses stops the walk for good. The log grows until every write answers `Full`, and only a build
that folds the op or an `Erase` clears it. `Reset` does not, because the reset is another op behind
the blocking one.

**When it fires.** Weeks later, on the keys that happen to still carry one of those ops, one player
at a time.

**Fix.** Keep the branch, and keep it correct through later migrations. Do not replace it with one
that accepts and changes nothing, because compaction then writes that result into the snapshot for
good.

**Not a match.** A kind that never shipped.

---

## D9. A reducer that is not a pure function of its two arguments

**Shape.** `os.time`, `os.clock`, `tick`, `DateTime`, `math.random`, `game:GetService`, an upvalue
that changes, a read of another player's data, or anything captured from outside.

**Why it survives review.** It runs correctly on one server, and the answer looks right every time
you check it.

**What it costs.** Two servers fold the same log at different moments and get different state. The
divergence is silent, it compounds, and a compaction writes whichever version compacted first into
the snapshot.

**When it fires.** Whenever two servers hold the same key, so on any transfer, transaction, or
rejoin.

**Fix.** Pass the value on the op. `Apply("Bonus", { At = os.time(), Roll = math.random(1, 6) })`.

**Not a match.** Reading the clock at the call site to build the op. That is the fix, not the bug.

---

## D10. State that only grows

**Shape.** An array appended on every action, a log of purchases, a kill feed, a set keyed by
`UserId` as a number.

**Why it survives review.** It is small in testing and the cap is far away.

**What it costs.** State caps at 2 MB and every compaction rewrites the whole snapshot, so it is
expensive long before it is refused. A table with only number keys is an array, and an array with
gaps cannot be stored, so each op passes on its own and then the key fails to compact.

**When it fires.** Months in, on the most engaged players, who are the ones who complain.

**Fix.** Bound the array. Use `tostring(UserId)` for a set keyed by player.

**Not a match.** A bounded array with an explicit trim.

---

## D11. Rendering from the answer rather than from state

**Shape.**

```luau
local Ok = Session:Apply("SpendGold", { Amount = 25 })
if Ok then
	Gui.Gold.Text = tostring(State.Gold - 25)
end
```

**Why it survives review.** It is instant and correct on one server.

**What it costs.** `Apply` answers from this server's live state and the op reaches the log on the
next save. Another server's write can refuse it when it lands, after the player was told it worked.

**When it fires.** Only when two servers write one key, so on a trade, a gift, or a rejoin race.

**Fix.** Render from `Session:Observe()`, so the correction arrives on its own.

---

## D12. `ProcessReceipt` assigned late

**Shape.** The callback assigned after something that yields, or inside a function called later.

```luau
local Store = Ledger.New({ ... })
Store:Load(...)                                  -- anything that yields
task.wait(1)
MarketplaceService.ProcessReceipt = Handler      -- too late
```

**Why it survives review.** The handler itself is correct, and in testing the server is up long
before anyone buys anything.

**What it costs.** Roblox acknowledges receipts on its own while no callback is assigned, and an
acknowledged receipt can never be handed back. The player paid and gets nothing, permanently, with no
retry to catch it.

**When it fires.** On a purchase in the first seconds of a server's life, and on every server.

**Fix.** Assign it first, at the top of the script, and let the callback yield for the store rather
than making the assignment wait for the store.

**Not a match.** A handler that yields on `WaitForLoaded` inside itself. That is the correct shape.

---

## D13. `DidApply` asked on the wrong store

**Shape.** A grant written to one store and the name checked on another.

```luau
Profiles:Edit(UserId, "Grant", { Once = Name }):Wait()
Sales:Edit("ledger", "Record", { Once = Name }):Wait()

if Profiles:DidApply(UserId, Name):Wait() == true then   -- which store owns this name?
```

**Why it survives review.** The name is the same string in both places, so it reads as one thing.

**What it costs.** A name lives on one key of one store. Asking the wrong store always answers
false. The write is refused as a replay and the check says it never landed, so the handler never
finishes and the receipt comes back for ever.

**When it fires.** On the first replay, then permanently for that player.

**Fix.** One name per store, each checked on its own store.

**Not a match.** Two different names for two stores, each asked of its own. That is the fix.

---

## D14. `Once` used as a permanent guard

**Shape.** A `Once` name as the only thing stopping something being granted twice, for something
meant to last for ever.

```luau
Store:Edit(UserId, "UnlockSkin", { Skin = "Gold", Once = `unlock:{SkinId}` }):Wait()
```

with no check in the reducer that the player already has it.

**Why it survives review.** It works, and it keeps working for a month.

**What it costs.** A name is kept 30 days and then dropped on the next named write to that key.
After that the same name applies again. A reopened support ticket, a re-run of a backfill, or a
gamepass check months later grants a second time.

**When it fires.** Past 30 days, on a key that has kept being written.

**Fix.** `Once` is for retry windows. Put the permanent rule in the reducer, where it refuses on the
state itself, and keep the name for the retries.

**Not a match.** A `Once` name on a receipt or an order. Those are retry windows and 30 days is far
past any retry.

---

## D15. `Spent` treated as success

**Shape.** Anything that treats not-refused as done.

```luau
local Ok, Why = Store:Transfer(From, To, Amount, Id):Wait()
if Ok or Why == Ledger.Reason.Spent then
	GiveTheItem()                                -- Spent means nothing moved
end
```

**Why it survives review.** `Spent` reads like "already spent", so it sounds like the transfer
happened earlier and this is a duplicate call.

**What it costs.** `Spent` means nothing moved, and for a transfer it means the hold expired and the
money went **back to the sender**. Handing anything over on it is paying for a refund.

**When it fires.** Past the redrive window, so about eight days after a transfer that never landed.

**Fix.** `true` is the only answer that means already happened. Treat `Spent` as a refusal and pick a
new id or tell the player.

**Not a match.** Logging `Spent` separately, or branching on it to explain the failure.

---

## D16. A failed load answered with a fresh profile

**Shape.** Any fallback that writes defaults when a read did not answer.

```luau
local State = Store:Peek(UserId):Wait()
if State == nil then
	Store:Reset(UserId):Wait()                   -- or: write a default profile
end
```

or an `OnLoadFailed` that lets the player in with an empty profile.

**Why it survives review.** It reads as graceful degradation, and it stops a player being stuck at a
loading screen.

**What it costs.** `nil` never means empty. A key nobody has written folds to the `Default` already,
so `nil` is always a failure. On `Behind` the record is fine and this server simply cannot read it,
and writing over the top destroys a real profile. This is the single most expensive mistake on the
list, because it is irreversible for that player past the version window.

**When it fires.** During a rolling deploy, when half the servers answer `Behind`, so on many players
at once.

**Fix.** Never write on a failed read. `OnLoadFailed` decides what to do with the player, and
`Behind` wants a teleport rather than a kick, because a rejoin lands them on the same old server.

**Not a match.** Kicking, teleporting, or retrying the read.

---

## D17. A `Future` timeout read as a false answer

**Shape.** A timeout passed to `Wait`, and the result read as a boolean.

```luau
local Ok, Why = Store:Edit(UserId, "Grant", Fields):Wait(5)
if not Ok then
	Retry()
end
```

**Why it survives review.** Every other call in the file returns `(boolean, Reason?)`, so this reads
identically.

**What it costs.** `Wait` returns **nothing** when the timeout runs out, so `Ok` is `nil` and `Why`
is `nil`. The write may still land afterwards. The code cannot tell a timeout from a refusal, so it
retries something that is already on its way.

**When it fires.** Whenever the datastore is slow, which is when writes are most likely to be in
flight.

**Fix.** Only pass a timeout where a missing answer is acceptable, and treat "no values at all" as
`Unresolved` rather than as false. `Happened` says whether it settled.

**Not a match.** `Wait()` with no timeout. It returns when the work returns.

---

## After the detectors

Once those are done, the rest of a review, in the order a miss costs:

**Lifecycle.** `Unload` on every path a player leaves by. `CloseAll` in `BindToClose` and nothing
else there. `WaitForLoaded` rather than `Get` in anything that fires during a join. No session kept
after `Unload`.

**Budget.** Count writes per player per minute against roughly 20. No `Commit` on a gameplay path.
`Total` with a `MaxAge` that matches how often it is drawn. No `Peek` in a loop.

**Contention.** Which keys does every server write. A key takes one transaction at a time.

**Deploys.** Migrations append only, never reordered, and each copies the state rather than
rebuilding it. `Behind` never falls back to a fresh profile.

**Destructive calls.** Who can reach `Erase`, `Reset` and `Destroy`, is it behind an admin check, is
the key from a player supplied string, and is the answer checked.
