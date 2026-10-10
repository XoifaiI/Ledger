# Triage

Symptom first, because that's how a developer arrives. Each tree ends at a call to make or a page to
read. Run the diagnostic block before guessing, and read Ledger's own warnings, which say what
happened and what to do.

If the developer hands you a real UserId and money is involved, go to `forensics.md` **first**. The
block below reads the key, and a read can end trade work on it.

## First, read the warnings

Ledger warns in plain sentences, prefixed `Ledger:`, usually once per store, key or cause, so the first
one is the one that matters and it may be far up the log. A warning about a key reads
`Ledger: <Store>/global/<Key>: <what happened>`. Ask for the output before theorising.

| The warning says | It means | Go to |
|---|---|---|
| "holds a value no Ledger build wrote" | the key was written by something else: raw DataStore calls, another library, a plugin | **Unreadable** below |
| "holds a value this build's migrations fail on" | a migration's `Run` threw, yielded or returned `nil` for this key's shape | **Unreadable** below |
| "holds a balance this build's arithmetic rejects" | a stored amount fails the field's `Arithmetic` | **Unreadable** below |
| "names a key of the store X, which this server never opened" | trade work on this key can only be ended by a server with X open | **stuck Unresolved** below |
| "the reducer gave a state holding X, which the store does not declare" | the reducer set an undeclared field; every such op is refused | `review.md` D11 |
| "the state has passed N bytes" | the key is past 2 MiB, heading for `Full` at about 4 MB | **Full** below |
| "answered Missing, since the quantity's parts do not exist" | `Take` before `Open`, or after `Close` removed the parts | **Limited items** below |
| "the name X was used with other terms" | a name was reused for a different op; the second answers `Spent` | `review.md` D3 |
| "a DataStore request failed with error 403" (or 101 to 106) | Studio API access is off, or a bad key, scope or value | **Busy everywhere** below |
| "A reducer must give the same from the same state and op" (Studio) | two runs of the reducer on one op differed: it isn't pure | `review.md` D10 |
| at `Ledger.New` in Studio, about the reducer and an unknown kind | the reducer didn't return `nil` for a kind it doesn't know | `review.md` D8 |
| "CloseAll ended with N ops and transactions not heard" | the close ran out of time; those calls are `Unresolved`, those fates unknown | **Shutdown** below |
| "this key was written before the store X was erasable" | an erase met a key from before `Erasable = true`; erasing is only once-only when no old build runs | `learn/deleting-data` |
| "DidApply ... answered Unresolved for a name with a first send time" | pass `Probe = true` to get a definite `false` | `reference/store#support-calls` |

An error that says **"this call is never made"** or **"this report is never heard"** is Ledger breaking
its own rule, not the game. Don't work around it. Go to `escalate.md`.

## The diagnostic block

Paste this, run it once from a server that opens every store, and read the answer. It costs three reads.

```luau
local Record, RecordWhy = Store:Inspect(Key)
local Pending, PendingWhy = Store:Pending(Key)
local State, PeekWhy = Store:Peek(Key)

print("peek    ", PeekWhy, State ~= nil)
print("inspect ", RecordWhy)
print("level   ", Record and Record.Book.Level, "floor", Record and Record.Book.Floor)
print("format  ", Record and Record.Book.Format, "writes", Record and Record.Book.Writes)
print("horizon ", Record and Record.Book.Horizon, "now", Ledger.Now())
print("marks   ", Record and #Record.Book.Work)
print("pending ", PendingWhy, Pending and #Pending)
if Pending then
	for _, Item in Pending do
		print("  ", Item.Kind, "age", Item.Age, "attempt", Item.Attempt, "decided here", Item.IsDecided)
	end
end
```

How to read it:

- `peek nil, Missing`: nothing is saved. A new player, an erased key, or the wrong key.
- `marks` above 0: escrow is set aside for unfinished trades. That gold is not lost.
- `pending` items older than about 10 s: a sender probably died. They end at the next touch, or
  `Resettle` ends them now.
- `level` below this build's migration count: no write from this build has landed since the update.
- `floor` above this build's last breaking migration: this build answers `Behind` on the key.
- `format` not 0: another Ledger release wrote the key.
- `horizon` later than `now - 180`: the key's name room filled and dropped names early; resends of
  those names answer `Expired`.

## A write answered `true` and the value didn't change

1. **Was it `Apply`?** `Apply` answers from the session's view and is saved later, where it's judged
   again. A trade or another server's write in between can turn it away, and the view drops it. The
   only signal is a `Turned` fate on `ObserveFates`. `learn/players`.
2. **Is the reader looking at a session view?** A `Tx`, a `Take` or another server's `Edit` reaches a
   session at its next save, its idle read (every 120 s), or `Session:Refresh()`. The saved data is
   right; the view is behind.
3. **Is the reader on another server?** Same as 2, from the other side. `learn/shared-data` shows how
   to nudge a session elsewhere with `MessagingService` and `Refresh`.
4. **Did the reducer return the input?** A fall-through `return Data` accepts any kind and changes
   nothing. `review.md` D8.
5. **Was it a `MaxAge` read?** `Peek(Key, MaxAge)` can return the shared copy from before this server's
   own write. Read plainly to check.

## A write answered `false` and the developer expected `true`

Read the reason before anything else. `learn/answers` says what each means, and the call's page in
`reference/` says what to do.

The four that get misread:

- `Unresolved` isn't failure. The change may land; Ledger is still sending it.
- `Spent` isn't success. This call changed nothing.
- `Expired` says nothing about earlier sends. After an `Unresolved` the first may have landed.
- `Refused` is the reducer's `nil` on the **saved** data, which can differ from what the view showed.
  `Info.State` is the data it was judged on.

## Gold doubled, or a reward paid twice

In order of how often it's the cause:

1. **An unnamed write sent again after `Unresolved`**, by a loop or by the player pressing again.
   `review.md` D1.
2. **A name or `IdAt` made fresh per attempt.** D3.
3. **A lock that let the move be redone while the first was still in flight.** Look for two moves of
   the same kind minutes apart, the first around an outage. D4.
4. **A `Future` timeout read as "no", then refunded or redone.** D5.
5. **`Expired` read as "didn't happen".** D7.
6. **A purchase guarded by an untimed name, or a receipt list trimmed too short.** D12.
7. **A support fix paid by hand while the original was still `Unresolved`.** The writer landed the
   original later.
8. **Old servers in a rollout** still running the bug the new build fixed.

## Gold vanished

1. **In escrow.** `Inspect(Key).Book.Work` shows marks with amounts. A trade hasn't ended. It ends at
   the next touch of any key in it; `Resettle` ends it now. Not lost.
2. **Handed back.** `Losses(Key).Returns` lists escrow returned from abandoned trades.
3. **Destroyed by a cut.** `Losses(Key).Events` lists every balance field a `Reset` or `Erase`
   replaced. Only balance fields: items are not named.
4. **An `Apply` turned away at save.** The player saw it, then it left the view. Fates.
5. **An `Apply` lost in a crash.** Queued ops die with the server if no save landed. `Apply` is
   hopeful; `Commit` for what must not be lost.
6. **A trade leg.** The player was in a `Tx` they forgot, or that a market or auction sent.
7. **A migration** that rebuilt the state and dropped a field. Check `Book.Level` against the list.

If the totals across the keys involved don't add up even counting escrow and losses, that's Ledger's
conservation broken. `escalate.md`.

## A purchase was granted twice, or never

Compare the game's handler against `learn/purchases` line by line. What breaks it:

- An untimed `Id` on the grant instead of a record in the data: protected only inside its window. D12.
- Answering from `Ok` alone: a resend refused as a duplicate answers `NotProcessedYet` for ever, and
  Roblox keeps resending a purchase that was granted. Check `Info.State` for the id.
- `Apply` on the grant path: a crash in the next 30 s loses a grant Roblox was told happened.
- The receipt list trimmed short: a resend after N newer purchases grants again.

## A key answers `Unresolved` and stays that way

1. **A dead sender's trade work.** `Peek` and `Inspect` beside an undecided mark from a crashed server
   answer `Unresolved` for up to about 30 minutes, on every server, until a touch ends it.
   `Store:Resettle(Key)` ends it now. `Pending` shows the items and their ages.
2. **A store not opened on this server.** The work names a store this server never opened; only a
   server with it open can end it, and this server's reads of the key stay `Unresolved` for its life.
   Ledger warns, naming the store. Open every store on every server (`review.md` D16).
3. **Another Ledger release wrote the key.** `Book.Format` isn't 0, or every older-release server
   answers `Unresolved` or `Unreadable` on keys a newer release touched. Ledger has no compatibility
   across releases: every place on one release, full shutdown.
4. **A balance field removed or its arithmetic changed** while an older build held escrow on it. This
   build can't settle that escrow, so writes to the key stay `Unresolved` until an older server does.
   `review.md` D23.
5. **A DataStore outage.** Everything is `Unresolved` everywhere for a while. Don't resend unnamed
   writes; wait.
6. **An `Edit` on a key a trade still holds.** It waits for the trade to finish and answers
   `Unresolved` after 30 s, not `Busy`, when the trade's server went down. Ledger keeps sending it;
   don't resend an unnamed one. `Pending(Key)` shows the trade work.

## `Busy`

- **`Apply` answers `Busy`**: a trade's mark on the key decides whether this op is allowed. Try again in
  a moment.
- **`Ledger.Id()` answers `Busy`** at a server's start during an outage: no server number yet. Ask again;
  it answers within 5 s per call.
- **Writes answer `Busy` everywhere, reads `Unresolved`**: Studio without API access, or a bad
  request. The 403 warning says which.
- **A bump answers `Busy`**: its shard write couldn't carry it (named bumps fill fast). Send again; use
  unnamed bumps.
- **A named `Edit` resent after `Unresolved` answers `Busy`**: Ledger is still sending the first one
  and won't send one name twice at once. Expected for a moment; send it again shortly.
- **4,096 unanswered writes on one key**: the key's writer is backed up. The key is too hot; spread it.

`Busy` always means nothing was sent: the same call again is safe.

## `Behind` or `Unreadable` after an update

**`Behind`**: a newer build wrote a breaking migration to this key, and this server is older. The data
is fine. This server must stop writing the key; the player belongs on a new server
(`TeleportService` to a fresh server, or a rejoin once old servers close). Never save a fresh profile
over it. A load that answers `Behind` already runs `OnLoadFailed` and kicks.

During a rollout this hits players who join an old server after a new one wrote their key, and an
old server's last saves for a player who moved to a new server can be turned away `Behind` (fate
`Turned`, `Why = "Behind"`). A full shutdown avoids both. `learn/changing-data`.

**`Unreadable`**: the key holds something this build can't read. The warning names the cause: a value no
Ledger build wrote (raw DataStore writes, a plugin, another library), a migration that fails on this
key's shape, or a balance the arithmetic rejects. Fix the build (a migration that handles the shape) or
repair the value; a retry gives the same answer. A failed migration doesn't store anything, so a fixed
build reads the key fine. But a `Refused` already stored under a call's name stays that name's answer.

## Players are kicked on join

`OnLoadFailed` runs, then the kick unless `Kick = false`. The reason says why:

- `Unresolved`: the read failed or took over 30 s. An outage. Retrying a few times from `OnLoadFailed`
  with `Kick = false` is fine.
- `Behind`: an old server; send them to a new one. Don't retry here.
- `Unreadable`: see above.
- `Busy`: the read landed but there was no server number yet. Retry.

`Load` never answers `Missing`: a player with no saved data starts from `Default`, even on a `MustExist = true` store,
where only the player's own session may create their data (an `Edit` or a trade leg to them answers `Missing` instead).
`Load` returns `nil, nil` when the player left or the server is closing; that's not a failure.

## A session shows old data

A session's view updates at its own saves, at its idle read (every `IdleReadInterval`, 120 s), and on
`Session:Refresh()`. Changes from a `Tx`, a `Take`, a `Store:Edit` from another server, or a support
tool wait for one of those. `Refresh` after anything that changed the player outside the session.
`Store:Stale()` emits keys this server wrote that its view is behind on.

## `Full`, `Invalid`, `Backlog`

- **`Full`**: the state would pass about 4 MB. Ops that shrink it still work, so a cleanup op fixes it.
  The cause is a list with no bound. `review.md` D21.
- **`Invalid`**: the op can't be stored: a function, an Instance, `NaN`, an array with gaps, a table
  with number and string keys mixed. Or a quantity's part holds another declaration than this build's:
  someone changed `Parts`, `Stock` or `Serials` on a live quantity.
- **`Backlog`**: `Apply` only. 4,096 ops or 1.5 MiB are queued unsaved: saves aren't landing, or the
  game applies hundreds of ops a second. `Flush`, and batch the ops.

## Limited items

- **Never opened**: `Take` answers `Missing` and Ledger warns once. `Open()` once, from an admin command
  or the first `Missing` while the sale is on.
- **Opened again after the sale**: a second batch sold with the same serials. `Close` removed the
  parts, `Missing` came back, and the game opened it. `review.md` D17. The units already sold can't be
  unsold by Ledger; the fix is a guard and, for the extras, the game's own call.
- **`Short` while units remain**: an unnamed take tries at most 3 parts. Use named takes. A named take's
  `Short` uses up the name: a retry needs a new name.
- **Sold count looks low after `Close`**: `Total().Sold` loses parts `Close` removed on a server that
  never saw them. Count sold as `Stock - Free - Held`, and log `Total()` before the first `Close`.
- **Serial numbers left behind after a trade**: the game's trade op moves the item and not the serial.
  `review.md` D27 shows how a stale view causes it too.

## A total reads wrong, stale or low

1. A `MaxAge` read answers a cached sum. Zero reads every time and costs more.
2. A total counts bumps that took effect, not what the keys hold. A bump lost at shutdown or never sent
   after an op is a count lost. Totals are statistics.
3. Named bumps undercount badly under load. `review.md` D19.
4. `Shards` was changed: the total restarted under a new identity.

## A `Follow` or `MaxAge` read doesn't update on another server

1. **How long?** A write shows on the copy's holder within about 30 s, and on other servers at their
   next tick: 30 s, doubling to 240 s on a quiet key. Four minutes isn't a bug.
2. **`"Behind"`** is the only non-state value `Follow` emits. Filter it.
3. **Failed reads and absent keys emit nothing.** A key that was never saved never emits.
4. **For a decision, don't use it**: `review.md` D20.

## Shutdown lost data

1. Data held in Lua tables until the end of a round, never applied. `Ledger.BeforeClose`, or `Apply` as
   it happens.
2. Saves in the game's own `BindToClose`: Ledger is already closed, every call answers `Closed`.
3. The close ran out of time (25 s): the warning counts what wasn't heard. Those `Unresolved` calls may
   still have landed; their fates are unknown.

## The reducer behaves differently in Studio

Studio freezes the reducer's inputs, runs it three times per call, and warns when the runs differ or
when it doesn't refuse an unknown kind. None of that happens live, so the same reducer is silently
wrong there. Fix what Studio names: a change to the input (D9), something impure (D10), a fall-through
(D8).

## Nothing here fits

Reproduce it on the mock in a few lines before theorising further, and read `working.md` before
touching live data to test a hypothesis.
