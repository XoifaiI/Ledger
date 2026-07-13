# Sessions

A session is the live per-player authority on the server that loaded them. It holds the
folded state in memory, applies changes optimistically, and pushes batches to the
datastore on a 30 second autosave (plus a final save on `Unload` and `CloseAll`).

## Store methods

```
Configure(Options)                  set up the store, once, before anyone joins
Load(Player)                        fold a session, start autosave; kicks on failure
Unload(Player)                      final save and release
CloseAll()                          flush and release everyone, for BindToClose
Get(Player) -> Session?             the live session, or nil if not loaded
Expect(Player) -> Session           the session, asserts it is loaded
IsLoaded(Player) -> boolean
WaitForLoaded(Player) -> Session?   yields until loaded, nil if the player left first
Read(Player) -> State?              the current state table, or nil
```

## Session methods

```
Get() -> State                      the current state
Apply(Kind, Fields?) -> boolean     optimistic, instant, queues the op for the next flush
Commit(Kind, Fields?) -> Future<boolean>   durable append, then an authoritative answer
CommitOp(Op) -> Future<boolean>     raw commit of a pre-built op whose Id the caller owns
Flush() -> Future<()>               push pending ops, then fold in what other servers wrote
Compact() -> Future<()>             fold the log into a fresh snapshot
Release() -> Future<()>             final push; Apply and Commit are rejected afterwards
Observe() -> Observer<State>        a stream of state, fires on every change
LogSize / LogBytes                  ops since the last snapshot, and their measured bytes
```

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
your hands. Listeners run inline on the session's thread and must not yield. In Studio the
state is deep-frozen, so a mutating listener throws in development.

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
