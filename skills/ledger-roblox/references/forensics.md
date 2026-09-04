# A money bug on a real player

A developer hands you a UserId and says gold went missing. Treat it as evidence, not as a bug report.
The record is the only account of what happened, it ages out, and several of the obvious next calls
change it.

**Capture first, reason second, fix last.** Do not touch the key until the capture is in the
developer's hands.

## What is safe to run before you have captured

| call | safe | why |
|---|---|---|
| `Inspect` | **yes** | reads the record, copies it, freezes it, touches nothing |
| `History` | **yes** | lists versions |
| `PeekVersion` | **yes** | folds an old version, read only |
| `Holds` | yes | one MemoryStore read |
| `Peek` | **no** | reads, and hands the key to the recovery sweep when it finds a parked leg or money in `_Held` |
| `Store:DidApply` | **no** | same path as `Peek` |
| `Resettle`, `RecoverTransfers` | **no** | these write. They settle legs and move money |
| `Reset`, `Erase` | **no** | these destroy the evidence and the data |

`Peek` and `DidApply` are the trap. They read, so they feel safe, and a minute later the sweep
repairs the key: a stranded transfer is redelivered or refunded, a parked leg is settled. The state
you were sent to explain is gone, and you caused it. Neither is wrong, it is Ledger healing itself,
but it must happen **after** the capture and it must be recorded as something you did.

## The capture

Run this first, in this order, and give the whole output to the developer before analysing any of it.

```luau
local Key = 12345                                  -- the UserId, as given

local Record = Store:Inspect(Key):Wait()           -- the evidence
local Versions = Store:History(Key, 100):Wait()    -- the timeline

print("captured at", os.time())
print("record", Record)
print("versions", Versions)
print("online here", Store:IsLoaded(game:GetService("Players"):GetPlayerByUserId(Key)))
```

Then, only if the field is one that can be reserved:

```luau
print("held", Store:Holds(Key, "Stock"):Wait())
```

Note three things in writing beside the output: **when** you captured it, **whether the player was
online anywhere**, and **what you have run since**. That last one matters because your own calls
become part of the history.

## Evidence ages, and writes age it faster

Roblox keeps a version for 30 days after a newer write replaces it, and the newest version never
expires. So every write to that key, including an autosave from a live session, starts the clock on
the version before it. A player who keeps playing is overwriting the evidence.

If the incident is older than a few days, take `History` first and take it wide.

## Reading the record

`Inspect` gives the record rather than the state, and that is the point. The state is the answer, the
record is the working.

- **`Snapshot`** is the state as of the last compaction. It is not the current balance.
- **`Ops`** replay on top of it, in order. The current balance is snapshot plus ops.
- **`Seen`** holds ids already folded into the snapshot, so a name in there happened and has been
  absorbed.
- **`Erased`** set means a tombstone. Deliveries to this key were being turned away.
- **`Version` and `Floor`** say which build wrote it. A floor above what this server knows is why a
  read answered `Behind`.

### The op ids tell you the story

Ledger's own ops carry ids with a fixed prefix and the transfer id after it. Read them off the list:

| prefix | leg |
|---|---|
| `res:` | reserve, money left the sender into `_Held` |
| `del:` | deliver, money arrived on the receiver |
| `stl:` | settle, the hold cleared |
| `exp:` | expire, the hold was given back |
| `tx:`  | a transaction leg, and it carries a `Tx` field while it is parked |

That gives you the answer in most money cases without any reasoning:

- `res:` present and no `stl:`, with an entry in `Snapshot._Held`, means the money is in escrow. It
  is not lost. Recovery finishes or refunds it.
- `res:` and `exp:` means it was given back. The sender has it.
- An op carrying a `Tx` field means a transaction is parked and the key is frozen until it settles.
- A `del:` on the receiver's record proves the money arrived, whatever the sender's key says.

Check the receiver's record too. A transfer is two keys and half the evidence is on the other one.

## Replaying it by hand

The record is a log, so you can fold it yourself and watch the balance move op by op. This is what
finds the exact op that did it.

```luau
local State = Record.Snapshot or Default
print("start", State.Gold)

for Index, Op in Record.Ops do
	local Next = YourReducer(State, Op)
	print(Index, Op.Kind, Op.Id, if Next then Next.Gold else "REFUSED")
	if Next then
		State = Next
	end
end
```

**Your reducer is not the whole reducer.** Ledger wraps it with the escrow, names and tally layers,
so every `__Transfer` kind comes back `REFUSED` from this walk. That is expected and it is not the
bug. The walk is for the game's own kinds. For the Ledger ones, read the ids as above.

A refusal in that list is often the whole answer: an op that landed in the log and folded to nothing.

## Rebuilding it somewhere safe

There is no call that copies a key. Work from the captured `Inspect` output instead, and use a mock
store with the game's own reducer to try hypotheses:

```luau
local Probe = Ledger.New({
	Name = "Forensics",
	Default = TheGamesDefault,
	Reducer = TheGamesReducer,
	Mock = { Players = 8, Throttled = false },
})
```

Replay the sequence you think happened, and see whether it reproduces the balance in the capture. If
it does not, the hypothesis is wrong. Never test a hypothesis against the real key.

## If the player is online

A live session holds its own copy and its queue is not in the record yet. So the record is not the
whole story, and the queue dies with the server.

Say so in the capture. If the queue matters, `Session.LogSize` and `Session.LogBytes` say how much is
waiting, and a `Flush` writes it, which is a change and belongs after the capture, not before.

## Only then, the fix

When the cause is known, the fix is an ordinary write with a `Once` name on it, because somebody will
run it twice:

```luau
Store:Edit(Key, "AddGold", { Amount = 250, Once = `ticket:{TicketId}` }):Wait()
```

Record what you ran, under which name, and what the balance was before and after. `Reset` and `Erase`
are not fixes for a money bug, they are ways to lose the evidence and the rest of the profile.

If the conclusion is that Ledger itself did this, stop and go to `escalate.md`. The capture you
already took is most of what a report needs.
