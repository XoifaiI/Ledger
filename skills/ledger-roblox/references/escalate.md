# When it's Ledger's own bug

Most surprises are the game's. A few aren't, and those tend to be the expensive kind, so they're worth
reporting rather than working around.

## What says it's Ledger's

**An error saying "this call is never made" or "this report is never heard".** Ledger's modules assert
their own rules with those words. Seeing one means Ledger broke an internal rule, not that the game
misused it. Don't wrap it in a `pcall`, don't work around it, and don't tell the developer it's normal.

**Money that doesn't add up.** Ledger promises that a balance field's total is conserved: a trade moves
amounts, it never makes or destroys them. Sum every balance plus the escrow in `Inspect(Key).Book.Work`
across the keys involved, before and after. If the sum moved and no `Reset` or `Erase` named the
difference in `Losses`, that is Ledger's.

**A durable `true` that isn't in the data.** `Commit`, `Edit`, `Tx` and `Take` answer `true` only once the
change is saved, and it stays until a later `Reset` or `Erase`. If a later plain `Peek` disagrees and no
other write explains it (check the history), that is Ledger's. `Apply`'s `true` is not this: it is
judged again at the save.

**A change applied twice under one name.** A named op that carries its first send time (`Id` with `IdAt`,
or a `Ledger.Id()` name) applies at most once for all time, across retries, restarts, erases and resets.
Two landings of one such name are Ledger's. Two landings of **two** names (an unnamed resend, a new
`IdAt`, a redo) are the game's.

**A plain `Peek` or a session view going back** to older data than this server already showed for the
same key, without an erase in between. (A `MaxAge` read right after this server's own write can return
the copy from before it; that is known and not this.)

**A call that never answers.** Every call answers exactly once: reads by 30 s, writes by their bound, and
everything by the close. A call that hangs past those is Ledger's. `Outcome:Wait()` with no timeout is
not a call; it waits for the change.

**A reason not in `Ledger.Reason`**, or an answer whose shape differs from the call's page.

**`Behind` when every server of every place runs the same build**, or `Unreadable` on a key only this
build ever wrote.

## What is almost never Ledger's

A refusal the reducer made. A session view that lags another server's write. `Unresolved` during a
DataStore outage. `Busy` on a hot key. A `MaxAge` read that's a few minutes old. A total that's behind. A
`Short` while units remain on other parts. `Behind` during a rollout. A key stuck `Unresolved` beside a
dead server's trade for up to 30 minutes. A store not opened on this server. Each of those is documented
behaviour, and the page that documents it is the answer.

Read the page first. Most candidates don't survive a careful read of the page that covers them, and "I
thought this was a bug and it's documented here" is more useful to the developer than a report that gets
closed.

## The evidence to collect

A report without these is one nobody can act on.

1. **The exact error or warning**, copied, not paraphrased.
2. **The capture** from `forensics.md` for every key involved: `Inspect`, `Pending`, `Losses`, taken as
   close to the event as possible, with the time.
3. **The version history** of those keys around the event, if money is involved.
4. **The reducer**, or the branches for the kinds involved, and the store's config.
5. **The Ledger version**, from `wally.toml` or `package.json`, and whether every place runs it.
6. **A repro on the mock**, if one can be found. A short script beats a paragraph.
7. **What was expected and what happened**, one sentence each.

If the repro won't reduce, say what was tried. One that needs two servers, an outage or a rollout is
worth reporting without a repro; say that's why.

## Where it goes

The library's repository, `https://github.com/XoifaiI/Ledger`, as an issue. Don't put a player's
UserId or data in a public issue; describe the shape.

## While waiting

Don't paper over it. A workaround that quiets the symptom and leaves the cause is worse than the
symptom, because the next person believes the behaviour is intended.

If the game has to keep running, prefer the change easiest to take back out, mark it in the code as
temporary with the issue link, and say in the report that it's in place.
