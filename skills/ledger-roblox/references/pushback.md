# When the ask will hurt them

Say the concern **once**, in a sentence or two, then do the work they asked for. If they say it again,
that's their call about their own game: do it and say what you did. Don't repeat the warning, don't
moralise, and don't refuse ordinary work because it touches something risky.

Every entry has a case where it's the right thing to do. Read the context before answering. The point
is to catch the common mistake, not to have an opinion about every call.

## Throwing data away

**"Erase this player to reset them."** `Erase` removes the key, needs `Erasable = true`, and hands back
the destroyed balances once, in its first answer. `Reset` puts the data back to `Default` (or a state
you give) and keeps the key.
*Right when:* it's a deletion request (GDPR, "Right to Erasure"). Then `Erase` is the call, with a
fresh `Ledger.Id()` per attempt and `Cut.Losses` logged. `learn/deleting-data`.

**"Wipe every key and start fresh."** A bulk destructive loop. Print the list and the count first, get
the count named back, and cap the pass.
*Right when:* it's a mock or a test universe. Say which before running it. For a live game, a new store
`Name` starts fresh without destroying anything.

**"Just fix it in the DataStore editor plugin."** The plugin shows Ledger's record, `{ s, b }`, not the
player's data. Writing a plain table reads `Unreadable`; editing `s` and leaving `b` can make old ops
apply again or lose escrow. An op through the reducer, or a `Reset { State = ... }`, does the same job
safely.
*Right when:* only reading, to look at old versions. Never writing.

**"Close the sale and reopen it to restock."** After `Close`, `Open` makes the whole stock again with the
same serial numbers. A restock is a new quantity with its own name and serial range.
*Right when:* never on the same name.

## Retries and names

**"Retry until it goes through."** On `Refused` the reducer said no on the saved data, and it will again;
this is a loop and a wall of warnings. Read `Info.State` and tell the player why.
*Right when:* the reason is `Busy` or `NoRoom` (nothing was sent), or `Unresolved` on a call with a name,
resent with the same `Id`, `IdAt` and terms.

**"Wrap Edit in a retry loop for outages."** An unnamed write that answered `Unresolved` is still being
sent by this server. A second call is a second change, and both land. `review.md` D1.
*Right when:* the loop resends only on `Busy`. For `Unresolved`, wait on `Info.Outcome` instead.

**"Retry with a new name."** After `Unresolved` this is how a game pays twice: the first name may still
land.
*Right when:* the first answer was definite and the player is starting a new attempt: after `Spent`,
after `Refused` when the player changed something, after `Short` on a named take, after `Expired` once
the data shows the first didn't happen.

**"Unlock the player after 30 seconds if it's still unresolved."** A trade has no time limit while its
server lives. The player trades again, and both commit. `review.md` D4.
*Right when:* the reducer already refuses a redo (one per player, a record of ids in the data).

**"Put a GUID name on every write, to be safe."** Ledger already names every write and never applies one
twice. A game name adds nothing for a call this server makes once, uses room in the key's name list,
and on bumps cuts throughput badly. A string name without `IdAt` throws unless the kind has an
`Untimed` window.
*Right when:* the resend may come from another server or a support tool, or after this server restarts.
Then `Id` plus `IdAt = Ledger.Now()`, made once and kept.

**"Use the PurchaseId as the Id."** That's an untimed name, protected only inside a window, and Roblox
can resend a receipt days later. Record the id in the player's data and let the reducer refuse it.
*Right when:* never on its own. The record is the guard. `learn/purchases`.

**"Keep the Ledger.Id() name in the GDPR queue, so any server can resend it."** A drawn name belongs to the
server that drew it, and that server answers `Expired` for it once it's 6 minutes old. A string name
throws on `Erase` and `Reset`.
*Right when:* never. Draw a fresh name per attempt; on an `Erasable` store an erase of a key that's already
gone answers `true` or `Missing`, both meaning done.

## The reducer

**"Read `os.time()` in the reducer."** The reducer runs several times per op, at different moments.
Put the time, or the day, in the op. The same goes for `math.random`, a flag table, a `Player`.
*Right when:* never. Studio warns when two runs differ; a live server doesn't.

**"`Data.Gold += 1` in the reducer."** Only Studio freezes the input. Live, this changes Ledger's own copy.
Clone each table on the path you change.
*Right when:* never.

**"Return `Data` for kinds we don't handle."** Ledger reads any table as accepted. A typo'd kind in a
trade commits that leg doing nothing. End with `return nil`.
*Right when:* never. It's the Redux habit, and it costs money rather than throwing.

**"Store the refusal reason in the data so we can show it."** A reducer can only say no with `nil`, and a
refused op stores nothing. `Info.State` is the data the op was judged on: run the same check in the
script (`WhyNot(Info.State, Op)`) to tell the player why.
*Right when:* never in the data.

**"Migrate by building the new shape from scratch."** `Run` gets the whole stored table, fields the build
no longer declares included. A rebuild drops whatever it didn't mention. Copy the input and change what
the step is for.
*Right when:* the step really is meant to drop everything, which is a reset, not a migration.

**"Just fix the old migration, it has a bug."** Migrations are identified by position; keys that already
ran it keep the old result. Append a new step that repairs what the old one did.
*Right when:* the migration never shipped to a live server.

## Cost and shape

**"Commit on every click."** One write per click runs the server out of budget. `Apply` answers at once
and rides the next save: one write per 30 s however many ops.
*Right when:* the result is acted on outside the data: a badge, a webhook, a purchase answer.

**"Peek the settings key every few seconds on every server."** A plain `Peek` is one read per server per
call, all on one key. `Peek(Key, MaxAge)` or `Follow` shares one read across the fleet.
*Right when:* one server needs the saved data once, before a decision.

**"Use `Peek(Key, 30)` everywhere, it's cheaper."** For a key only this server reads, a `MaxAge` read
makes this server the copy's holder: 2 reads a minute for 30 minutes. A plain `Peek` is one read.
*Right when:* many servers read the same key often: a leaderboard, a guild panel, a shop index.

**"Use `{ Fresh = true }` to be sure."** It's a write, every time.
*Right when:* a decision must be on current data and the reducer can't check it itself. Rare.

**"Put the whole economy on one key."** A key takes about 4 MB of writes a minute, and game-op legs off
the decider hold it.
*Right when:* the limit really is one thing, like one item's stock. Even then a quantity splits it over
parts.

**"Use `Tx` for one player's purchase."** One key is an `Edit` or `Commit`; a one-leg `Tx` throws. A
limited item is a `Take` with the buyer's payment in `Legs`.
*Right when:* two keys must change together.

**"Name the bumps so the count is exact."** Measured: 3,000 named bumps counted 1,599 under load;
unnamed, all 3,000.
*Right when:* a quiet total where a count must survive a server restart exactly.

**"Keep the whole history in the profile."** About 4 MB per key, and a big key can be written only a
few times a minute. Bound it, or move it to its own store.
*Right when:* it's small and bounded. Say what bounds it.

**"Key it by username."** A rename orphans the data. Use the UserId; a `Player` store does it for you.
*Right when:* the key isn't a player, which is what `Keys = "String"` stores are for.

## Answers and failure

**"Wrap it in pcall and carry on."** Ledger throws only on misuse: a wrong kind, a bad key, an `IdAt`
from `os.time()`. That throw is a bug in the call. Answers are never thrown, so a `pcall` hides bugs
and catches nothing else.
*Right when:* wrapping the **reducer** in `xpcall` with a `warn`, so a reducer that throws on bad data
says so instead of being a silent refusal.

**"Turn off the warnings."** There's no switch, and they're the only place Ledger says what went wrong
with a key nobody asked about. If they're noisy, that's a finding.
*Right when:* never.

**"Let them play on a fresh profile if the load fails."** On `Behind` or `Unresolved` the data is fine
and this server couldn't read it. A fresh profile that saves destroys it.
*Right when:* never for a profile that saves. `Kick = false` with a handler that retries `Unresolved`
or teleports on `Behind` is fine.

**"Spent means it already went through, give the item."** `Spent` means this call changed nothing.
*Right when:* never.

**"Save everything in BindToClose."** Ledger closes first; every call there answers `Closed`.
`Ledger.BeforeClose`, or `Apply` as things happen.
*Right when:* the `BindToClose` work isn't Ledger's.

**"Add a session lock so two servers can't load the same player."** Ledger merges ops at the key; that
is the design every guarantee rests on. A lock adds a failure mode and protects nothing.
*Right when:* never.

**"Read the v6 data straight from the DataStore for the import."** v6 stored a log, not the state; the
raw value isn't the player's data. Read it with v6's own `Peek` under another module name.
*Right when:* never. `migrate-v6.md`.
