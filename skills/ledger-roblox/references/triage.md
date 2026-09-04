# Triage

Symptom first, because that is how a developer arrives. Each tree ends at a call to make or a page to
read. Run the block at the foot before guessing, and read Ledger's own warnings, which say what
happened and what to do about it.

## First, read the warning

Ledger warns in plain English on every path that gives up on something. The warning names the key and
the amount. Ask for the output before theorising.

One family matters more than the rest. A warning holding **`Ledger bug:`** says Ledger broke its own
rule, not that the game did. Do not work around it. Go to `escalate.md`.

## The diagnostic block

Paste this, run it, and read the answer. It costs three requests.

```luau
local Record = Store:Inspect(Key):Wait()
local State, Why = Store:Peek(Key):Wait()

print("reason  ", Why)
print("ops     ", Record and #Record.Ops)
print("version ", Record and Record.Version, "floor", Record and Record.Floor)
print("erased  ", Record and Record.Erased)
print("held    ", State and State._Held)
print("parked  ", Record and (function()
	for _, Op in Record.Ops do
		if Op.Tx then return Op.Tx end
	end
	return nil
end)())
```

`ops` climbing and never falling is a compaction problem. `erased` set is a tombstone. `parked`
holding a transaction id is a stuck leg. `held` holding entries is money in flight.

## A write answered true and the value did not change

1. **Was it `Apply`?** `Apply` answers from live state on this server and writes on the next save. If
   another server wrote in between, the fold can refuse it when it lands. Nothing is lost and every
   server agrees afterwards, but the player saw a number that was never true. Render from state, not
   from the return value. `concepts/apply-and-commit#when-the-answer-changes-under-you`.
2. **Is the reader a different server?** A session holds its own copy and picks up outside writes on
   its next fold, which is every two minutes when it is idle. `Store:Stale()` names the keys this
   server changed so a session can be flushed at once.
3. **Did the reducer return the state unchanged?** Ledger reads any table as accepted. A Redux style
   `return State` for an unknown kind is an accepted op that changes nothing, and it will mark a
   `Once` name as applied. `concepts/reducer#nil-means-refused-not-unhandled`.

## A write answered false and the developer expected true

Read the reason before anything else. `concepts/reasons` says what each one means and
`concepts/handling-failure` says what to do.

The two that get misread: `Spent` is not success, nothing moved and a transfer went back to the
sender. `Unresolved` is not a refusal, and treating it as one is how a game pays twice.

## Money is missing

1. **Look in `_Held` on the sender.** A transfer that took the money and could not deliver leaves it
   there on purpose. It is out of the balance so it cannot be spent twice, and it has not arrived.
2. **Wait, or force it.** The sweep finishes or refunds it on its own. `Store:RecoverTransfers(Key)`
   does it now. A refund is not immediate by design: money can only go back once redelivery has
   stopped being possible, which is 8 days.
3. **Check the receiver was not erased.** A tombstoned key turns deliveries away for 8 days and the
   transfer answers `Held`.
4. **Check nobody erased the sender.** `Erase` hands over what it can and names in a warning what it
   could not. That warning is the record of money that is gone.
5. **If the totals do not add up at all**, that is conservation broken, which is Ledger's own
   invariant. Go to `escalate.md`.

## A key answers Busy and stays there

`Busy` means a transaction leg is parked on the key.

1. `Store:Resettle(Key)` settles it now. `true` means nothing is left unfinished.
2. Still `Busy` means the marker has not decided yet. A transaction is treated as dead after about a
   minute, and another server aborts it on the original's behalf.
3. The sweep gives up on a key after five goes and warns, naming the key and telling the operator to
   call `Resettle`. That warning is not a failure, it is the sweep handing the job back.
4. `Tx` does not retry `Busy` for the game, on purpose. A contended key is the last place to send
   more traffic. The backoff belongs to the game. `guides/transactions#stuck-legs`.

## Writes answer Full and nothing fixes it

Two different things wear this reason.

**The state hit 2 MB.** Ops that shrink it are still allowed, so a cleanup works.

**The log cannot compact.** This is the one that does not heal. Compaction absorbs the run of ops at
the front that this build can apply. An op at the front that the reducer refuses stops the walk for
good, the log grows, and writes answer `Full`.

It happens when a kind was deleted from the reducer while live keys still carried ops of that kind.
The fix is to put the branch back, and keep it, because a branch is not dead code while any log still
holds one of its ops. `Reset` does not help, because the reset is another op behind the one that
blocks. Only a build that folds the op, or `Erase`, clears it.
`guides/migrations#changing-the-reducer`.

## Saves stopped, or writes answer Backlog

`Backlog` means ops are piling up because saves are not going through, so 4096 queued or 1.5 MB of
unsaved bytes. In practice the datastore is down or the server is out of request budget.

Look for the autosave warning naming the budget, and check what else in the game is spending
requests. Ledger skips an autosave rather than spending the last of the budget, and says so.
This is a signal to stop writing and look, not to retry harder.

## A player loaded a fresh profile

1. **Check for `Behind` first.** A newer build wrote the record and this server cannot read it. The
   data is fine. Writing a fresh profile over the top is how it gets destroyed. It clears when the
   deploy finishes. `guides/migrations#rolling-deploys`.
2. **Check the key.** A player store keys on the UserId. A game that switched to a username or a
   composed key is reading a key nobody ever wrote, which folds to `Default` correctly.
3. **Check for a tombstone.** An erased key folds from `Default` for the 8 days its tombstone lasts.
4. **Check whether a migration dropped the field.** A migration that rebuilds the state from scratch
   drops what it did not mention, and reconcile puts back only what `Default` still declares.

## A total reads wrong or stale

1. `Total` answers a cached sum for up to about a minute and a quarter across the fleet, and this
   server's own bumps show at once. That is not a bug, it is the trade that took a polled pot from
   192 reads a minute per server to one MemoryStore unit.
2. `MaxAge` controls it. Zero reads every time.
3. It answers what was added, never what the keys hold, so the `Default` never counts toward it.
4. One unreadable shard makes the whole call answer nothing with a reason, rather than a number that
   is quietly short.

## Reserve answers Unresolved

`Reserve` is the one feature that needs MemoryStore. Without it the answer is `Unresolved` and
nothing is held. In Studio that means API access is off.

Checkout still works. The reducer is the gate, so the stock is still correct, and the cost of a lost
hold is one refused checkout rather than an oversell.

## A purchase was granted twice, or never granted

Go to `concepts/once#processreceipt` and compare the game's handler against it line by line. The
three that break it:

- Answering from the `Commit` result rather than `DidApply`. A replay answers `Refused`, which is
  indistinguishable from the reducer refusing, and `DidApply` is the question Roblox is asking.
- Not checking `Unresolved` before `DidApply`, so a fold that a stuck leg can still flip gets read as
  settled.
- Asking `DidApply` on a different store from the one the name was written to, which always answers
  false, so the receipt never finishes.

`Store:DidApply` answers nothing when it could not read. Compare against `true`, not truthiness.

## The reducer behaves differently in Studio

Studio refolds the log after every commit and compares it against live state. A mismatch names the
field that moved and means the reducer is not deterministic. That check does not run live, so the
same break is silent in production. Fix what it names.

The usual causes are `os.time()`, `math.random()`, an upvalue that moves, and reading something
outside the two arguments.

## Nothing here fits

Reproduce it on the mock in ten lines before theorising further, and read `working.md` before
touching live data to test a hypothesis.
