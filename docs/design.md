# Design: why Ledger works this way

Ledger is a lock-free event-sourced fold: state is `fold(Snapshot, Ops)`, every change is
an immutable op validated by a reducer at fold time, and nothing anywhere takes a session
lock. That combination is unusual enough that everyone who evaluates it asks the same
questions, in roughly the same order. This doc is that ladder, because each answer is one
forced move: by the bottom you have either rebuilt this design or accepted a weaker one.

If you want the API instead, start at [getting started](getting-started.md). This is the
why, not the how.

## Why not session locking like every other library?

A lock serializes writers. A validating fold makes the invalid state unreachable. Those
sound similar but they are not the same guarantee: a buggy write under a lock still
corrupts, it just corrupts alone. A fold rejects the overdraft no matter which server
folds it, in what order, or how many times.

The lock also charges rent whether or not it ever saves you. A crashed server locks its
players out until the lease expires (minutes in most libraries). Teleports wait on lock
handoff. Nothing can touch a locked player from another server, so offline grants,
cross-server trades and moderation edits all need side channels. And the lock does not
survive the failure people actually fear: a hard crash loses unsaved changes under a lock
exactly as it does without one.

Locking is what you do when state is a mutable document and any write could clobber any
other. Once writes are validated intents in an append-only log, there is nothing left for
a lock to protect.

## Why not capture changes instead of writing a reducer?

The tempting design: hand game code a draft of the state, record every write it makes (a
path, a before, an after), and store those recorded diffs. No reducer to write, changes
fall out of ordinary assignments.

The problem is that a diff is an effect, and effects cannot be revalidated. `SpendGold 100`
is an intent: the reducer checks it against the state at its position in the log, so when
two servers spend the same 100 gold, one append folds accepted and the other folds
rejected. `Set Gold = 400` is an effect: fold two of them and the last write wins, and the
double spend succeeds silently. Deltas instead of sets (`Gold += -100`) apply twice and go
negative.

Capture is what a locked document store does, and there it is sound, because the lock has
already serialized the writers. In a lock-free log, validation at fold position is what
replaces the lock, and only intents can be validated. Diff capture and lock-free are not
two features you can combine; each one exists to avoid needing the other.

## Why not validate with the recorded before and after?

So keep the capture, but store `{ before = 500, after = 400 }` and reject the change when
the current value no longer matches `before`. That is per-field compare-and-swap, and it
fails in the opposite direction: now any interleaved foreign write (a transfer landing, an
admin edit, a trade leg) changes `before` and rejects an honest local change wholesale for
touching a field someone else touched.

Intent merges under concurrency; effects do not. "Spend 100" composes with a concurrent
"gain 50". "Set to 400" can only conflict with it. CAS punishes exactly the concurrency
the system is supposed to absorb.

## Can't the validation be generated from the change itself?

Partially, and the partial cases are real. A numeric delta with a static bound (gold,
clamped at zero) validates mechanically. So does a set add or remove (add requires absent,
remove requires present). If a profile were nothing but counters and flags, generated
validation would cover it.

Three things break past that point:

- **The rule is not in the diff.** Knowing the change is -100 does not say whether -100 is
  legal here. "No overdraft", "one claim per day", "cannot drop what you do not own" have
  to be written by someone and present on every server, because the fold replays the
  change later against a different state than the one that captured it. You cannot
  serialize the validation closure into a datastore, so the rules end up statically
  registered per field. That is a reducer indexed by path instead of by kind.
- **The kind is load-bearing.** A -100 from a shop, a trade and an admin correction are
  three intents with three rules and three audit meanings. Diffs collapse them into one
  anonymous delta, so generated validation must apply one rule to all three, and the log
  stops being an audit trail.
- **Fields do not change alone.** "Spend 100 gold AND grant the sword" must validate and
  apply as one unit. Two independent captured writes can split under replay: the gold
  rejects at its fold position, the sword applies, and the sword was free. The thing that
  groups several field changes under one name with accept-or-reject-whole semantics
  already exists. It is an op.

## Why not batch the captured changes per frame?

Batching does create grouping, but a frame is the wrong boundary. Everything that touched
the player in one heartbeat fuses into one atomic unit: the shop purchase, the quest tick,
the passive regen, all systems at once. If the purchase is invalid at fold position, does
the unrelated quest progress die with it? Splitting the batch by which writes belong
together requires semantic information no frame timing carries; `Gold -100` and
`Sword = true` in the same frame look identical whether they are one purchase or two
coincidences. A frame is a when. A transaction is a why.

A coalescing optimizer on top makes it worse: netting `-100, +30` into `-70` erases
ordering (rules that depend on sequence can pass on the net and fail on the truth) and
erases audit (the log records the optimizer's output, not what happened).

And note that batching as a transport optimization is already here: a session's pending
ops go to the datastore as one append per flush. Batching earns its keep moving bytes. It
cannot stand in for correctness.

## What happens when an optimistic op gets invalidated after its effect fired?

`Apply` is optimistic: the reducer runs locally and synchronously (it is a function call,
not a round trip), and the buff can be on the humanoid the same frame. The accepted op can
only be overturned by a foreign writer, another server's edit, a trade leg, a moderation
reset, landing in the log between the Apply and its fold. Rare, but real. Three rules make
it a non-event:

- **One op, never two.** "Spend coins and gain the effect" is a single op whose reducer
  checks the cost and writes the effect in the same step. Rejected means neither happened;
  accepted means both.
- **Derive effects from state, do not grant them from the call site.** Store the boost
  deadline in the profile; make the effects layer a view of session state (deadline in the
  future means buff on). Then invalidation is self-healing: the same re-fold that rejects
  the op removes the deadline and the buff dies with it. No revocation code. The view
  cannot disagree with the fold for longer than one flush.
- **Pick the direction errors fall.** With the two rules above, the worst case of the race
  is a briefly free ephemeral effect, never a charged player and never wrong stored data.
  For stakes where even that is unacceptable (permanent items, badges, anything witnessed),
  gate on `Commit`: durable append first, effect second, one datastore round trip behind a
  button spinner.

## What about the cascade, ops earned under a later-invalidated effect?

If the buff let a player earn loot and the buff op then invalidates, the loot ops stand.
They were independently valid, and the fold does not trace causality through gameplay,
because the dependency ran through the physical world, not the data. No storage layer can
roll that back. Locked stores have the identical hole the moment they contain any optimism
at all.

The full solution exists and nobody wants it: determinism all the way down, the entire
game as the fold, every input an op, gameplay pure and replayable, so invalidation
re-folds the world and the cascade undoes itself. That is lockstep RTS netcode
generalized. It forfeits the engine (Roblox physics and humanoids are not deterministic),
resimulation cost grows with the window, and the real killer is witnessed state: you can
re-fold data, you cannot re-fold what players saw. Fighting games cap rollback near seven
frames because that is the edge of what eyes forgive.

So everyone converges on the same compromise, and Ledger says it out loud: a
deterministic core (the log), a non-deterministic shell (gameplay), and compensation at
the seam. Keep the invalidation window one flush wide. Gate roots whose downstream matters
on `Commit`, so nothing builds on unconfirmed state. And when something slips through
anyway, do what banks do: not rollback, compensation. The audit log shows exactly what was
earned under the invalid effect, and an `Edit` claws it back. That is the quiet argument
for the log: cascades cannot be undone anywhere, but here they can always be seen and
corrected. A state store cannot even see.

## Why do trades need a whole protocol?

Because "remove from A" and "add to B" live in two logs with two independent folds, and
every simple composition of them has a crash window that loses or duplicates the item:
after the first write, between write and acknowledgement, during a retry. The
[transaction protocol](transactions.md) is the minimum machinery that closes those windows
without a lock: prepared legs that no fold counts yet, a marker that decides, any
bystander able to resolve or abort a stale transaction, and idempotent leg ids so a retry
cannot resurrect an aborted trade. Ledger's test suite injects faults into exactly those
windows, including writes that succeed while reporting failure, because that is where item
duplication is actually born in live games.

## Where do unsaved changes live, and what does a crash cost?

Pending ops live in server memory until the next flush. A soft shutdown (updates,
migrations, which is nearly every server death) flushes everyone through `CloseAll` and
loses nothing. A hard crash loses at most the autosave interval of optimistic gameplay,
30 seconds here, against several minutes in the locked libraries, and anything that went
through `Commit` was durable before its side effect fired. Nobody's lock survives the
power cord; the only honest lever is the width of the window and what you route around it.

## The shape of the whole argument

Every alternative above fails the same way: it handles what is visible on one server in
the happy path, and leaves what lives in concurrency and failure. Datastore correctness is
only the second part. The designs that survive it keep being the same three structures
wearing different names: a validated intent (the op), a deterministic judge (the reducer),
and a protocol for the windows (the transaction). Ledger just calls them what they are.
