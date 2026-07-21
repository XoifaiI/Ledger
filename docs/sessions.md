# Sessions

A session is the live per-player authority on the server that loaded them. It holds the
folded state in memory, applies changes optimistically, and pushes batches to the
datastore on a 30 second autosave (plus a final save on `Unload` and `CloseAll`).

## Store methods

`Ledger.New` builds the store and `Ledger.CloseAll` closes every store at once. The rest are
methods on the store `New` returned. The session lifecycle here is player-store only; an
entity store has no sessions.

- `Ledger.New(Options)` returns a store. Call it once, before anyone joins.
- `Ledger.CloseAll()` flushes and releases every store. Call it from `BindToClose`.
- `Store:Load(Player)` folds a session onto the player and starts the autosave. It kicks the
  player if the load fails.
- `Store:Unload(Player)` does a final save and releases the session.
- `Store:Get(Player)` returns the live session, or `nil` if the player is not loaded.
- `Store:Expect(Player)` returns the session and asserts it is loaded, so it throws rather than
  returning `nil`.
- `Store:IsLoaded(Player)` returns whether a session is loaded.
- `Store:WaitForLoaded(Player)` yields until the session is loaded, and returns `nil` if the
  player leaves first.
- `Store:Read(Player)` returns the current state table, or `nil` if not loaded.

## Session methods

- `Session:Get()` returns the current state table.
- `Session:Apply(Kind, Fields?)` runs the reducer against live state, updates it optimistically,
  and queues the op for the next flush. It returns `true` if the reducer accepted the op.
- `Session:Commit(Kind, Fields?)` appends the op durably and returns a `Future<boolean>` that
  resolves to whether your op was the one accepted. This is the path to gate a side effect on.
- `Session:CommitOp(Op)` is `Commit` for a pre-built op whose `Id` you own.
- `Session:Flush()` pushes pending ops, then folds in what other servers wrote.
- `Session:Compact()` folds the log into a fresh snapshot.
- `Session:Release()` does a final push and afterwards rejects any further `Apply` or `Commit`.
- `Session:Observe()` returns an `Observer<State>` that fires on every change.
- `Session.LogSize` and `Session.LogBytes` are the count of ops since the last snapshot and
  their measured size.

## Apply vs Commit

This is the one distinction that matters day to day.

**`Apply` is for gameplay.** It is a local function call: the reducer runs against live
state, the answer comes back the same frame, and the op rides the next autosave. Use it
for everything whose worst case under a rare race is acceptable, which is almost
everything, because the reducer already guarantees the stored data can never go invalid.

**`Commit` is for side effects that must not fire twice.** It durably appends the op,
re-folds, and answers whether *your* op was the one accepted. Two servers commit the same
one-time grant, exactly one gets `true`. Gate the badge, the product grant, the
irreversible thing on that boolean. It costs a datastore round trip, so it belongs behind
a button or a receipt, not in a combat loop.

The rare race, precisely: an accepted `Apply` can only be overturned by a *foreign*
writer (a cross-server `Edit`, a transfer leg, a moderation reset) landing between the
apply and its fold. Within one session, local answers are final. Two rules make even the
foreign case a non-event:

1. **One op, never two.** "Spend coins and gain the effect" is a single op whose reducer
   checks the cost and writes the effect in the same step. Rejected means neither
   happened.
2. **Derive effects from state.** Store the boost deadline in the profile and render the
   buff from observed state. Then a corrected fold removes the deadline and the buff
   removes itself. No revocation code.

## Observing state

```luau
Session:Observe():Subscribe(function(State)
	print(State.Gold)
end)
```

The value is the live state table by reference. Never mutate it; clone first if it leaves
your hands. Listeners run inline on the session's thread and must not yield. The state is
deep-frozen everywhere, so a mutating listener throws at the line that did it.

## What a crash costs

Pending ops live in server memory between flushes. A soft shutdown (updates, migrations,
nearly every server death) flushes through `CloseAll` and loses nothing. A hard crash
loses at most 30 seconds of `Apply` traffic; everything routed through `Commit` was
durable before its side effect fired. There is deliberately no lock and therefore no
lockout: a player rejoining after a crash loads immediately.

## Backpressure

During a datastore outage the session refuses to grow without bound: past a cap of
pending ops or bytes, `Apply` starts rejecting with a warning rather than eating memory
and pretending progress is being saved.
