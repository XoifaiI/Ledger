# The model

## State is a fold

The state you read is never stored directly. What is stored is a snapshot plus an
append-only log of ops, and the state is derived:

```
State = fold(Snapshot, Ops)
```

An op is one immutable change: `{ Id, Kind, ...fields }`. The `Id` makes appends
idempotent (a retried write never duplicates), and the `Kind` names the intent so your
reducer, and any human reading the log later, knows what it meant.

Your reducer replays every op in order. For each one it either returns the next state or
`nil` to reject. Because the reducer runs at fold time, on whatever server folds the log,
an invalid change is not "prevented", it is unreachable. Two servers spend the same
100 gold, both append their op, and every fold everywhere accepts the first and rejects
the second. No lock needed, because there is nothing a lock would protect.

Periodically the log is compacted: the ops fold into a fresh snapshot so the log stays
short. Dedup survives compaction through a bounded set of already-folded ids.

## Reducer rules

This is the state machine of your game. Get it right.

**The return replaces the entire state.** Always clone the old state and mutate the copy.
A partial literal like `{ Gold = ... }` silently drops every other field the moment your
profile grows a second one.

```luau
local function Reducer(State, Op)
	if Op.Kind == "AddGold" then
		local Next = table.clone(State)   -- clone, never mutate State
		Next.Gold += Op.Amount
		return Next
	elseif Op.Kind == "SpendGold" then
		if Op.Amount > State.Gold then
			return nil                    -- nil rejects, the fold skips it
		end
		local Next = table.clone(State)
		Next.Gold -= Op.Amount
		return Next
	end
	return nil
end
```

**Pure and deterministic.** The same `State` and `Op` must give the same result on every
server and every replay. No `os.time`, no `math.random`, no reading anything outside the
two arguments. When an op needs the time (a daily claim), capture it at the call site and
pass it in the fields, like `Apply("Claim", { Timestamp = os.time() })`, so the replay
stays deterministic.

**Never mutate `State`.** It is shared with the stored snapshot and the running fold.
Clone nested tables too before writing into them; a shallow clone that mutates a nested
table corrupts shared prior state. Ledger deep-freezes state everywhere, so this mistake
throws at the line that did it instead of quietly corrupting the shared table.

**Never yield.** Compaction folds inside a datastore transform where a yield would fail
the save, so every reducer call runs through a yield guard. A throw or a yield is treated
as a rejection of that op, so one bad op can never break the whole fold. A reducer that
returns something other than a table or `nil` is also treated as a rejection, loudly at
the call site.

**Reserved names.** State keys starting with `_` (like `_Held` and `_Received`) belong to
Ledger's bookkeeping. Op kinds starting with `__` and the op fields `Tx` and `TxHome` are
reserved and refused; `Id` and `Kind` are overwritten with a warning if supplied.

## One op per meaningful change

The `Kind` is how the reducer, and later a human, reads the log. "Spent 100 in the shop"
and "lost 100 in a trade" are different intents with different validation and different
audit meaning, so they are different kinds, even if both subtract from the same field.

Record the effect, not the derivation: an op that says `{ Kind = "QuestReward", Gold = 250 }`
replays identically forever, while one that says "grant whatever the quest table says"
changes meaning every time you rebalance.

## What this buys you

- **Idempotency.** Retried writes cannot double-apply. This is what makes purchase grants
  and cross-server operations safe to retry blindly.
- **Convergence without locks.** Any number of writers, one deterministic outcome.
- **An audit trail.** The log is history with names, not just the latest table.
- **Recovery.** Because state is derived, a historical record folds back into readable
  state at any time. See [recovery](recovery.md).

The trade is discipline: every change is an op with a name, validated by the reducer.
[The design doc](design.md) walks through every shortcut around that discipline and shows
where each one breaks.
