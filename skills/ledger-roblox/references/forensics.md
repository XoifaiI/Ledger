# A real player's gold went wrong

A developer hands you a UserId and says gold went missing, or doubled, or an item vanished after a
trade. Treat it as evidence, not as a bug report. The key is the only account of what happened,
parts of it age out within minutes, and several of the obvious next calls change it.

**Capture first, reason second, fix last.** Don't change anything until the capture is in the
developer's hands.

## No read in Ledger is perfectly passive

When any read on this server meets unfinished trade work on a key (a mark a dead server left, a
decision not yet delivered), this server notes it and comes back to end it: from 10 s later for a
session's load, staggered up to about 30 minutes otherwise. Ending it applies decided legs, aborts
undecided ones, and returns escrow. That is how a crashed server's trades get finished, and it's
right, but it means the state you were sent to explain can change because you looked.

So: take the capture in **one quick pass**, all reads together, and write down when you took it.

## What is safe to run, and in what order

| Call | What it costs | What it can change | Use |
|---|---|---|---|
| `Store:Inspect(Key)` | 1 read | schedules this server to end dead work it saw | **first**: the state, the migration level, the escrow marks, the loss records |
| `Store:Pending(Key)` | 1 read | same | **second**: unfinished trade work, with its age |
| `Store:Losses(Key)` | 1 read | same | **third**: what a `Reset`/`Erase` destroyed and escrow handed back, 7 days |
| `Store:Peek(Key)` | 1 read | same | only the state; `Inspect` already has it |
| `Store:DidApply(Key, Name)` | 1 read | same | did one named op take? Only with a name the game kept |
| `Store:DidApply(Key, Name, { IdAt = At, Probe = true })` | **1 write** | lands on the key | **not** during capture |
| `Peek(Key, { Fresh = true })` | **1 write** | lands on the key | **not** during capture |
| `Store:Resettle(Key)` | read + writes | **ends the work now, returns escrow** | after the capture, as a decision |
| The player joining, `Store:Load` | 1 read | **acts on dead work after 10 s** | the player rejoining is a write to the evidence |
| `Edit`, `Commit`, `Tx` | writes | the state | the fix, last |
| `Reset`, `Erase` | destroy | everything | **never** as a fix for a money bug |

Raw DataStore reads of the key's **older versions** (`ListVersionsAsync`, `GetVersionAsync` on the
store's DataStore, named the store's `Name`, scope `"global"`) are safe and change nothing. They are the
only history there is: Ledger keeps none. The value is Ledger's record, `{ s = state, b = bookkeeping }`,
so read `s` and nothing else, and never write a raw value back. Its format is Ledger's own and can
change between releases.

## The capture

Run this as one Script, once, and give the whole output to the developer before analysing any of it.

```luau
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Ledger = require(ReplicatedStorage.Packages.Ledger)
local Stores = require(ServerStorage.Stores)

local Store = Stores.PlayerStore
local Key = 12345

local Record, RecordWhy = Store:Inspect(Key)
local Pending, PendingWhy = Store:Pending(Key)
local Losses, LossesWhy = Store:Losses(Key)

print("captured at", os.time(), "Ledger.Now", Ledger.Now())
print("record", RecordWhy, Record and HttpService:JSONEncode(Record))
print("pending", PendingWhy, Pending and HttpService:JSONEncode(Pending))
print("losses", LossesWhy, Losses and HttpService:JSONEncode(Losses))
```

Run it from a server that opens **every** store (the game's `Stores` module), or a key whose work
names an unopened store reads `Unresolved` on this server and the capture is empty.

Then the history, from the same Script, if the incident is older than a few minutes:

```luau
local DataStoreService = game:GetService("DataStoreService")

local Raw = DataStoreService:GetDataStore("PlayerData", "global")
local Pages = Raw:ListVersionsAsync(tostring(Key), Enum.SortDirection.Descending)
for _, Version in Pages:GetCurrentPage() do
	local Value = Raw:GetVersionAsync(tostring(Key), Version.Version)
	print(Version.CreatedTime, Version.IsDeleted, Value and HttpService:JSONEncode(Value.s))
end
```

Write three things beside the output: **when** it was captured, **whether the player was online
anywhere**, and **what you have run since**. Your own calls become part of the history.

If the player is in the game right now, their session is writing the key every 30 s and starting the
clock on older versions. Roblox keeps a replaced version 30 days. Take the history first if the
incident is old.

## Reading the record

`Inspect` gives the record, not just the state. These parts are supported to read; the rest of `Book`
is bookkeeping and means nothing to the game.

- **`State`**: the data, migrated to this build's shape. Escrowed amounts are not in it.
- **`Book.Level`**: how many migrations are stored on the key. `Level >= n` says migration `n` was
  saved. A level below this build's count means no write from this build has landed since.
- **`Book.Floor`**: the last breaking migration the key went through. Above this build's last breaking
  entry means this build answers `Behind` on it.
- **`Book.Format`**: the stored format, 0 in this release. Another number means another Ledger release
  wrote it.
- **`Book.Writes`**: how many writes have landed. Two captures with the same count saw no write between.
- **`Book.Horizon`**: if it is later than `Ledger.Now() - 180`, the key dropped names early because its
  name room filled, and resends of those names answer `Expired`.
- **`Book.Work`**: the unfinished trade work on the key. An escrow mark has `Field`, `Amount`,
  `IsDebit`, `IsClean` and `Decider` (the key that decides the trade); an `Exclusive` mark is a game-op
  leg holding the key; a `Pinned` item is a trade's record on its deciding key. **Money in an escrow
  mark is not lost**: it is set aside for a trade that hasn't ended.

`Pending` lists the same work with ages. `Escrow` is a balance leg's reservation, `Exclusive` a game-op
leg holding the key, `Pinned` a trade's record on its deciding key. `Age` under about 10 s is a trade
in flight: wait. Older, and the sender is probably gone: it ends at the next touch, or `Resettle` ends
it now. `Pinned` is normal for up to about 30 minutes. `IsDecided` true means **this** server holds a
decision it hasn't delivered; false says nothing.

`Losses` holds what was destroyed or handed back:

- **`Events`**: a `Reset` or `Erase`, with every non-zero **balance** field it replaced, and the name
  and time. Only balance fields: an item list wiped by a `Reset` is not named here.
- **`Returns`**: `"Returned"` on a leg's key means a trade was abandoned and this key's escrow came back.
  `"Orphan"` on a deciding key means its record was dropped after a leg key was proven gone.
- Kept 7 days, then folded into sums per 15-day period. `Stamp` is in Ledger's clock: add
  1,767,225,600 for Unix time. An amount is `{ High, Low }`: the value is `High * 34,359,738,368 + Low`.

## What the capture usually says

- **Gold in a `Book.Work` mark, and a `Pending` item.** The gold is in escrow for a trade that hasn't
  ended. It is not lost. It comes back or moves on when the trade ends.
- **A `Returns` entry.** A trade was abandoned and the escrow came back to this key. If the player says
  they paid and got nothing, this is the refund.
- **An `Events` entry.** Somebody ran `Reset` or `Erase`. The fields and amounts are what was destroyed.
- **The history shows the gold go up twice for one reward.** A write was sent twice: look for D1, D3 and
  D4 in `review.md`, and for a support fix paid by hand while the original was still `Unresolved`.
- **The history shows the gold go down with no op the game remembers.** A trade leg, or an `Apply`
  turned away at save after the player saw it succeed (D13, D14).
- **The key reads `Behind`, `Unreadable` or `Unresolved`.** Not a money bug yet. `triage.md`.

There is no op log to replay in v7: the state is stored folded, and Ledger keeps no history of its own.
The versions are the timeline, the game's own journal (if it has one) is the explanation, and the
reducer is the only thing that turns one into the other.

## Rebuilding it somewhere safe

There is no call that copies a key. Work from the capture, and use a mock store with the game's own
`Default`, `Reducer`, `Balances` and `Migrations` to try each hypothesis:

```luau
local Mock = require(ReplicatedStorage.Packages.Mock)

local Probe = Ledger.New<<Data, Ops>>({
	Name = "Forensics",
	Keys = "Player",
	Default = CapturedState,
	Reducer = TheGamesReducer,
	Balances = TheGamesBalances,
	Migrations = TheGamesMigrations,
	MustExist = false,
	Erasable = false,
	Mock = Mock.New({ Players = 8, Throttled = false }),
})
```

`CapturedState` is the `s` of the version before the incident, so key `1` starts there. Replay the ops
you think happened with `Probe:Edit(1, Op)` and see whether you reach the state in the next version. If
you don't, the hypothesis is wrong. A state saved at an older migration level has to be migrated by
hand first, because `Default` is never migrated. Never test a hypothesis on the real key.

## If the player is online

A live session holds queued `Apply`s that aren't in the key yet, and they die with the server. Say so
beside the capture. A `Flush` writes them, which is a change: it belongs after the capture, as a
decision, not before.

## Only then, the fix

When the cause is known, the fix is an ordinary op the reducer understands, and it records its own
ticket id in the state, because somebody will click the button twice:

```luau
local Ok, Result, Info = PlayerStore:Edit(Key, { Kind = "SupportGrant", Ticket = TicketId, Gold = 250 })
```

with a reducer branch that refuses a `Ticket` it already holds. A `Ledger.Id()` name on the `Edit`
covers a resend from this server for a few minutes; the ticket record covers the next support agent
next week.

**Never pay by hand for a move that answered `Unresolved`** while the server that sent it may still be
alive. Its writer is still sending it, and a trade has no time limit. Wait until that server is surely
gone (a day after the outage, or after a full shutdown), then compare and fix.

Record what you ran, under which name, and the state before and after. `Reset` and `Erase` are not
fixes for a money bug; they are ways to lose the evidence and the rest of the profile.

If the conclusion is that Ledger itself did this, stop and go to `escalate.md`. The capture you already
took is most of what a report needs.
