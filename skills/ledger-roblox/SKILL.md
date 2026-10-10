---
name: ledger-roblox
description: Expert help for a Roblox game built on Ledger 7, the DataStore library where every change is an op a reducer judges and every call answers (Ok, Result, Info). Covers Ledger.New and its settings (Balances, Migrations, Windows, Totals, Quantities, Mock), sessions (Load, Get, Apply, Commit, Flush, Refresh, ObserveFates), Store:Edit, Peek, Inspect, Follow, Ledger.Tx and Store:Leg, quantities (Open, Take, Hold, Confirm, Close), Bump and Total, Reset and Erase, Ledger.Id and Ledger.Now, Info.Outcome, and the fifteen reasons (Refused, Spent, Busy, Full, Invalid, Behind, Unreadable, Closed, Backlog, Expired, NoRoom, Missing, Short, SoldOut, Unresolved). Use it to pick the right call, read an answer, write or review a reducer, review a game's Ledger code for bugs that lose or duplicate gold, debug symptoms (gold vanished or doubled, a purchase granted twice, a trade that went through twice after an outage, a key stuck Unresolved or Busy, Behind or Unreadable after an update, a session showing old data, a sale that oversold, never opened or reopened), investigate a real player's data safely, move a game from Ledger 6 to 7, and update a game's code for a new Ledger release. It carries the rules for touching live player data. Not for ProfileService, ProfileStore, DataStore2 or raw DataStoreService projects, and not for the Ledger library's own source.
---

# Ledger 7

Ledger saves Roblox data as ops. The game sends a change as a table with a `Kind`, its own reducer
decides whether the change is allowed, and Ledger saves each op exactly once, even when a server
crashes or two servers change one key. There is no session lock: two servers can hold the same
player, and their ops are merged at the key. Every call answers `(Ok, Result, Info)`. `true` means
saved; anything else is one of fifteen reasons, each with one meaning on every call.

**This file is judgement, not reference.** The reference is the documentation, and it covers the
whole surface. Do not state a number, a signature or a rule from memory. Read the page, then answer,
and check the source when the answer decides money.

## Three checks, before anything else

**Is this project on Ledger?** Look for `xoifaii/ledger` in `wally.toml`, `@xoifail/ledger` in
`package.json`, a `Ledger.rbxm`, or a module tree holding `Shell/Runner.luau` and `Api/Store.luau`.
If none is there, say the project isn't on Ledger and stop. Nothing here transfers to ProfileService,
DataStore2 or a raw DataStore, and telling someone to handle `Unresolved` when their library has no
reasons wastes their time.

Two exceptions. Someone **deciding whether to adopt Ledger** gets an honest answer: server only, no
client replication, no queries across keys, no history of old versions, and it won't hide a reducer
that is wrong. And a question in a Ledger project that **isn't about Ledger** is just a question.

**Is this the Ledger library itself?** A tree holding `src/Shell/Runner.luau` together with
`internal/` and `spec/` is Ledger's own source. Stop and follow its own briefs. This skill assumes
you may not change the library.

**Which version?** This file is pinned to **Ledger 7.0.0**. Find theirs: the `xoifaii/ledger` line in
`wally.toml`, then `@xoifail/ledger` in `package.json`. There is no `Ledger.Version`, and a `.rbxm`
install has nothing to read, so ask once if it matters.

Then act on it, rather than only noting it:

- **7.0.x.** Answer normally.
- **6.x or older.** Signs: `:Wait()` on answers, `Transfer`, `Reserve`, `Once =`, `Apply(Kind,
  Fields)`, the reason `Held`. Nothing in this file applies to their calls. If they want to move to 7,
  follow `references/migrate-v6.md`. Otherwise say this skill is for 7 and work from their source.
- **A 7.x newer than this file, or 8.x.** Read that release's notes before answering anything, and
  follow `references/updating.md` if they're upgrading.
- **No version anywhere.** Say so once, treat every number here as unverified, and prefer the source
  over this file for anything that decides money.

## The reference lives here

Three copies, in the order to reach for them. Don't assume the later ones are available.

1. **`references/docs-bundle.md`**, beside this file. The whole documentation in one file, about
   4,000 lines. It's here because it is the only copy always readable: a game installed from a
   `.rbxm` has no source tree, and an agent may have no web access. Search it first.
2. **The library source**, when the install left it on disk: `Packages/Ledger/` or
   `Packages/_Index/xoifaii_ledger@*/ledger/` (Wally), `node_modules/@xoifail/ledger/` (npm), or a
   Rojo `src`. When it's there it's the truth. `references/verify.md` says which file answers which
   question.
3. **The site**, if you can fetch. The bundle is a copy of its `llms-full.txt`, so fetching only buys
   being newer.

The documentation has been wrong before, and fixes have landed in the source after the docs were
written. When the source and the docs disagree, the source wins; say so plainly rather than quietly
following one. If you can reach neither, answer and **say you couldn't check it**, naming the page
that would settle it. An unchecked number offered as a fact is how a skill does harm.

## What each call touches

Classification is a property of the call, not of the intent behind it. "I only read it" is not
always true in Ledger.

| Call | DataStore | Can it finish other work? | Notes |
|---|---|---|---|
| `Session:Get`, `Store:Get`, `Read`, `Expect`, `IsLoaded`, `Session:Observe`, `ObserveFates`, `Stale` | none | no | this server's memory |
| `Session:Apply` | none at the call | no | queued; written by the next save, and **judged again there** |
| `Inspect`, `Losses`, `Pending` | 1 read | **yes** | a read that meets a dead sender's trade work can pay the writes that end it |
| `Peek(Key)` | 1 read | **yes** | same; can answer `Unresolved` for up to ~30 min beside a dead sender's mark |
| `Peek(Key, MaxAge)`, `Follow` | MemoryStore copy; a holder reads 2/min for 30 min | yes, through the holder's reads | a rarely read key makes **this** server the holder |
| `Peek(Key, { Fresh = true })` | **1 write** | yes | changes nothing, but it is a write |
| `Store:DidApply` | 1 read; `Probe = true` is **1 write** | yes | a support question, not the way to learn an outcome |
| `Load`, `Session:Refresh` | 1 read | **yes**: `Load` acts on a dead sender's mark once it is 10 s old | |
| `Commit`, `Edit`, `Flush`, `Release`, `Unload` | 1 write | yes | `Edit` on a key a session here holds goes through that session's writer |
| `Ledger.Tx` (N keys), `Take`/`Confirm` with legs | N writes to the answer, 2N-1 at most (the tidy-ups ride on saves when they can) | yes | game-op legs off the decider **hold their key** until the trade ends |
| `Bump` | 1 write per shard per server batch | no | **yields 0 to 60 s**, ~90 s when writes fail |
| `Resettle` | 1 read + 1 write, more per mark | **that is its job** | ends unfinished trade work now; returns escrow; a fence costs a live sender one attempt |
| `Quantity:Open` | 1 write **per part, every call** | | **never after `Close`** |
| **`Quantity:Close`** | 1 write per part, removes empty parts past 62 min | | removed parts read `Missing`, the same as never opened |
| **`Reset`** | 1 write, more with marks | yes | replaces the state; names destroyed balances in `Losses` |
| **`Erase`** | 1 write + `RemoveAsync` | yes | `Erasable = true` stores only; `Cut.Losses` comes **once** |
| **`Destroy`**, **`CloseAll`** | final saves | | ends every session on the store, or the server |

Five of those surprise people, and each has cost somebody time:

- **Reads can write.** `Peek`, `Inspect`, `Load` and the rest end a dead server's trade work when they
  meet it: committed legs get applied, undecided ones aborted, escrow returned. A read can therefore
  move money. That is Ledger healing itself, not a bug, but it means a read before a capture changes
  the evidence. `references/forensics.md` has the safe order.
- **`Apply` true is not saved, and not final.** It's judged on the session's view, then again at the
  save. Another server's write or a `Tx` in between can turn it away, and the only signal is a
  `Turned` fate on `ObserveFates`. An autosave answers no caller.
- **`Flush` and `Release` true mean the push was answered,** not that the ops saved. Fates say what
  saved.
- **`Unresolved` keeps going.** An unnamed `Edit` or `Commit` is resent by this server's writer about
  every 16 s for the server's life. A `Tx` is driven to its end with **no time bound** while its
  sender lives (measured: it committed after 30 min, 2 h and 25 h outages). There is no cancel.
- **The decider rule.** One leg's key decides a `Tx`: the only game-op leg if there's exactly one,
  else the first Credit leg, else the last leg. Every other game-op leg takes an **exclusive mark**
  that blocks that key's game ops until the trade ends. A balance leg only escrows its amount. This
  is this release's rule; comment it where legs are ordered.

`references/tiers.md` is the long form with the call path behind each row.

## Stop before you destroy

`Reset`, `Erase`, `Quantity:Close`, `Destroy`, `CloseAll`, and any loop that writes more than one
key. Before any of them:

1. The **human named the key** in their own words. A key you worked out is not a named key.
2. You **captured it first** (`Inspect`, and `Losses` and `Pending` where money is involved) and
   showed the output.
3. You said **which rung** of the ladder in `references/working.md` this is.
4. You got **one confirmation for that key**. Approval for one key isn't approval for the next.

Never run a destructive call to find out what it does. That is what the mock is for.

## Prove it on the mock

The Mock package (`xoifaii/mock`) is an in-memory DataStore and MemoryStore with the real limits: the
request budget, per-key throughput, value sizes, MemoryStore quotas, and `UpdateAsync` transforms that
rerun on a conflict. Ledger takes it as a config option and the whole server runs on it.

```luau
local Ledger = require(ReplicatedStorage.Packages.Ledger)
local Mock = require(ReplicatedStorage.Packages.Mock)

local Probe = Ledger.New<<Data, Ops>>({
	Name = "Probe",
	Keys = "String",
	Default = TheGamesDefault,
	Reducer = TheGamesReducer,
	Balances = TheGamesBalances,
	MustExist = false,
	Erasable = true,
	Mock = Mock.New({ Players = 8, Throttled = false }),
})

print(Probe:Edit("k", { Kind = "SpendGold", Amount = 30 }))
print(Probe:Peek("k"))
```

**Any answer you're not certain of gets run there first**: what a reducer does with an op, which
reason comes back, whether a migration keeps a field, whether a call throws. A probe never runs on a
real key, and a real UserId is never a fixture.

The mock is per server, and three rules bite: it must be given **before Ledger's first request** (a
mock given later throws), **every store runs on it** including ones that leave `Mock` out, and a
**different mock** on a later store throws. So build the probe in a script or place of its own, never
next to the game's real stores.

What the mock can't show, so don't claim it did: two builds during an update, another live server,
real throttling under real contention, real DataStore outages, MemoryStore's real memory accounting,
and anything about the game's own data at scale.

**When nothing here answers the question, work down this ladder and stop at the first rung that
settles it.** Most questions are about this game's reducer meeting this library, so most are not in
any file here.

1. Read the source. `references/verify.md` says which file.
2. Run it on the mock.
3. Hand the developer a paste-and-run snippet and ask what it printed.
4. Say you don't know, and name the experiment that would settle it.

Never skip from 1 to 4. The mock is a package anyone can install, so an unrun experiment is not an
unknown. An invented answer about somebody's economy is the worst outcome on this list.

## Data is not code

The stop rules are about **live player data**, not the game's code.

- Asked to fix a reducer, fix the reducer. That is ordinary work.
- A reversible write on a key the developer named, in a session they're driving, gets done and
  reported. Don't stop to ask.
- Anything in the bold rows above stops and asks, every time.
- Don't edit files nobody named, don't tidy code beside the thing you were asked to fix, and don't run
  git commands unless asked.

## Where to look

Answer the question asked. A question about one reducer isn't an invitation to audit the game. Load
one of these, not all of them. Pages are in the bundle under their path.

| The developer says | Go to |
|---|---|
| "how do I start", "install" | `learn/getting-started` |
| "how do I structure my data", "ops", "the reducer" | `learn/your-data`, then `learn/bigger-reducers` |
| "gold", "gems", "a currency", `Balances` | `learn/your-data#balances-let-ledger-handle-gold`, `reference/ledger#balances` |
| "Apply or Commit or Edit" | `learn/players` |
| "what does this reason mean" | `learn/answers`, then the call's table in `reference/` |
| "is it safe to retry", "once per day", "codes" | `learn/once-only` |
| "developer products", "ProcessReceipt", "BindReceiptHandler" | `learn/purchases` |
| "a trade", "a gift", "move gold between players" | `learn/trading`, `learn/shared-data` |
| "guild", "clan", "shared data", "global shop" | `learn/shared-data` |
| "show another player's data", "a board every server reads" | `learn/reading-data` |
| "limited item", "serial numbers", "stock" | `learn/limited-items`, `reference/quantity` |
| "a counter across servers", "total spent" | `learn/global-counters` |
| "add or rename a field", "update", `Behind`, `Unreadable` | `learn/changing-data` |
| "GDPR", "delete a player", "wipe" | `learn/deleting-data` |
| "shutdown", "BindToClose", "testing", "mock" | `learn/shutdown-and-testing` |
| "auction", "market", "escrow" | `guides/auctions-and-markets` |
| "look at a player's data", "stuck trade", "admin tools" | `guides/support-tools` |
| "how many requests", "limits" | `limits` |
| "it said true and nothing changed", "gold vanished", "stuck" | `references/triage.md` |
| a real UserId and "their gold went wrong" | **`references/forensics.md` first**, before any call |
| "review my Ledger code" | `references/review.md` |
| "move us from Ledger 6" | `references/migrate-v6.md` |
| "Ledger released a new version" | `references/updating.md` |
| a request that will hurt them | `references/pushback.md` |
| "I think this is a Ledger bug" | `references/escalate.md` |
| you're about to touch live data | `references/working.md` |
| you need to check a claim | `references/verify.md` |

## How an AI gets this wrong

These are the mistakes a model makes with Ledger, not the ones a person makes. Check your own answer
against them before sending it.

- **Writing v6.** `:Wait()`, `Transfer`, `Reserve`, `Once =`, `Apply("Kind", Fields)`,
  `Ledger.Credit`. v7 has none of them, and older posts, older skills and your own memory are mostly
  v6. Check the surface with the grep in `references/verify.md` before naming a method.
- **Writing ProfileService habits.** Session locks, "wait for the other server to release", `:Save()`,
  "load the profile and edit the table". In Ledger the table is frozen and every change is an op.
- **Reading `if not Ok then` as failure.** `Unresolved` is not failure. Branch on it before anything
  that refunds, retries or tells the player.
- **Inventing a retry loop.** Ledger already resends unnamed work. A hand-written loop around an
  unnamed `Edit` or `Tx` is the double-pay bug, not resilience.
- **Treating `nil` from a read as empty.** Only `Missing` means nothing is saved.
- **Quoting a number from memory.** Windows, rooms, bounds and costs are in `limits` and the source.
- **Taking the docs' examples as the whole answer.** The docs trade sample waits on `Outcome` with no
  lock, which is right for the page and wrong for a game with a trade button the player can press
  again. Read the example, then ask what the game does around it.

## Never

Say it once, plainly, then do the work asked. Don't repeat it and don't moralise.

- Never resend an **unnamed** write after `Unresolved`. Ledger is still sending it; a second send is a
  second change. A named write resends with the **same** `Id`, the **same** `IdAt` and the same terms.
- Never take a new `IdAt` for a retry, and never use `os.time()` for one. `Ledger.Now()`, once.
- Never redo a move under a **new** name while the first can still land: after `Unresolved`, until
  `Info.Outcome` settles or a resend of the same name gives a definite answer.
- Never retry `Refused`. The reducer said no on the stored data, and will again.
- Never treat `Spent` or `Expired` as success, and never treat `Expired` after an `Unresolved` as
  "didn't happen". Look at the data.
- Never treat `nil` from a read as empty, and never save a fresh profile over `Behind`.
- Never put time, randomness, an Instance, an upvalue that changes, or a Ledger call inside a reducer,
  migration or `Schema`, and never change the `Data` or `Op` it was given. Only Studio freezes them.
- Never write `return Data` for a kind the reducer doesn't handle. End with `return nil`.
- Never suggest a session lock or waiting for another server. Ledger has none by design.
- Never match on error or warning text. Compare reasons with `Ledger.Reason`.
- Never call `Quantity:Open` after `Close`, and never on `Missing` without knowing it was never opened.
- Never edit, remove, reorder or insert a shipped migration, and never remove a field from `Balances`.
- Never read or write a Ledger key with raw DataStore calls.
- Never write a bulk destructive loop on a first pass. Print the list and the count instead.
- Never invent a method. `reference/store`, `reference/session`, `reference/quantity` and
  `reference/ledger` list all of them.

## What this is checked against

Ledger 7.0.0 and its documentation, on 2026-10-10. Every claim here can be checked in under a minute
with `references/verify.md`. If a check fails, the source is right and this file is stale: say so.
