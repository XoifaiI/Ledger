# When it is Ledger's own bug

Most surprises are the game's. A few are not, and the ones that are not tend to be the expensive
kind, so they are worth reporting rather than working around.

## What says it is Ledger's

**A warning holding `Ledger bug:`.** That line exists for exactly one purpose: Ledger noticed it had
broken its own rule. It asks to be reported. Do not silence it, do not work around it, and do not
tell the developer it is normal.

**Money that does not add up.** Sum every balance plus everything in `_Held` across the keys
involved, before and after. Ledger's first invariant is that money is never made and never destroyed.
If that sum moved, and no `Erase` warning named what it destroyed, that is Ledger's.

**An operation that answered `true` and is not in the final state.** A settled `true` from `Commit`,
`Edit`, `Transfer` or `Tx` means it is in the log and every server will agree from there on. If a
later read disagrees, and no other write explains it, that is Ledger's.

**A key that answers `Behind` when every server is on the same build.** That means somebody is
running an old build, or the floor on the record is wrong.

**A refusal with no reason, or a reason that is not one of the ten.** The set is closed.

## What is almost never Ledger's

A refusal the reducer made. A number that lagged on another server. A `Busy` on a contended key. A
hold that was lost while MemoryStore was down. A total that is a minute old. A write that answered
`Unresolved` during a datastore outage. Each of those is documented behaviour, and the page that
documents it is the answer.

Read the page before reporting. Most candidates do not survive a careful read of the page that covers
them, and saying "I thought this was a bug and it is documented here" is more useful to the developer
than a report that gets closed.

## The evidence to collect

A report without these is a report nobody can act on.

1. **The exact warning line**, copied, not paraphrased. Ledger's warnings name the key and the
   amount.
2. **`Store:Inspect(Key)` output** for every key involved, taken as close to the event as possible.
   The snapshot, the op count, the version, the floor, and whether any op carries a `Tx` field.
3. **The reducer**, or the branch that handles the kinds involved.
4. **The version**, from `wally.toml`.
5. **A repro on the mock**, if one can be found. Ten lines beats a paragraph, and the mock keeps the
   real caps and the real refusals.
6. **What was expected and what happened**, in one sentence each.

If the repro will not reduce, say what was tried. A repro that needs two servers or a rolling deploy
is worth reporting without one, and say that is why.

## Where it goes

The library repo, at `https://github.com/XoifaiI/Ledger`.

## While waiting

Do not paper over it. A workaround that makes the symptom quiet and leaves the cause is worse than
the symptom, because the next person believes the behaviour is intended.

If the game has to keep running, prefer the change that is easiest to take back out, name it in the
code as temporary, and say in the report that it is in place.
