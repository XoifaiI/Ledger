---
name: ledger-roblox
description: Expert help for a Roblox game built on Ledger, the lock free datastore library where state is a fold over a log of ops (Ledger.New, NewTyped, Session:Apply, Commit, Store:Edit, Transfer, Tx, Reserve, Confirm, Bump, Total, Once, DidApply, reducers, and the ten Reason values Refused, Busy, Spent, Unresolved, Closed, Backlog, Full, Invalid, Behind, Held). Use it to answer questions about Ledger, write and review a reducer, choose between Apply, Commit, Edit, Transfer, Tx and Reserve, work out what a call costs against the request budget, review a game's Ledger usage, and debug symptoms such as a write that answered true and did not stick, money missing or stuck in _Held, a key that answers Busy or Full and stays there, a session that will not save, a total that reads stale, a purchase granted twice, or a rolling deploy answering Behind. It also carries the rules for touching live player data, which calls only read, which write, and which throw data away. Do not use it for a project on ProfileService, DataStore2 or raw DataStoreService, and do not use it inside the Ledger library repo itself, which has its own brief in internal/CLAUDE.MD.
---

# Ledger

Ledger keeps player data as a log of changes. A game writes down the change it wants, its own
reducer decides whether that change is allowed, and state is what falls out of replaying the log.
Every server folds the same log to the same answer, so there are no session locks.

**This file is judgement, not reference.** The reference is the documentation, and it covers the
whole surface. Do not restate a number, a signature or a rule from memory. Read the page, then
answer, and check it against the source when the answer decides money.

## Three checks, before anything else

**Is this project on Ledger?** Look for `xoifaii/ledger` in `wally.toml`, `@xoifail/ledger` in
`package.json`, a `Ledger.rbxm`, or a require of a module tree holding `Core/Api.luau`. If none of
those is there, say the project is not on Ledger and stop. None of the advice here transfers to
ProfileService, DataStore2 or a raw DataStore. Telling somebody to handle `Busy` when their library
has no reasons wastes their time.

Two exceptions. Somebody **asking whether to adopt Ledger** gets an honest answer, and `index` has
the honest list of what it is not: server only, no client replication, no leaderboards or ordered
stores, and it will not hide a reducer that is wrong. And a question in a Ledger project that is
**not about Ledger** is just an ordinary question. This is not the skill for their UI code.

**Is this the Ledger library itself?** If the working tree holds both `src/Core/Api.luau` and
`internal/CLAUDE.MD`, this is Ledger's own source. Stop, and follow `internal/CLAUDE.MD` instead.
That brief assumes you may change the library. This one assumes you may not.

**Which version?** This file is pinned to **Ledger 5.x**, checked against 5.0.0.

Find theirs, in this order: `Ledger.Version` if the build has one, then the `xoifaii/ledger` line in
`wally.toml`, then `@xoifail/ledger` in `package.json`. A game that installed the `.rbxm` model file
has none of those, so there may be no version to read at all.

Then behave accordingly, rather than only noting it:

- **Matches 5.x.** Answer normally.
- **Is 4.x.** Say which version you found, stop quoting this file's specifics, and go to the source in
  `Packages/`. `Confirm` takes different arguments, holds work differently, and `Grant` and
  `Reserve`'s `To` still exist. Read `releases` before answering anything about those.
- **No version anywhere.** Say so once, treat every number here as unverified, and prefer the source
  over this file for anything that decides money.

With no way to look at any of it, ask which library and which version, in one line, and answer once
they say. Do not assume Ledger because somebody said "datastore".

## The reference lives here

Three copies, in the order to reach for them. Do not assume the later ones are available.

**1. `references/docs-bundle.md`, beside this file.** The whole documentation in one file, every
page, 5,536 lines. It is here because it is the only copy that is always readable: a game may have
installed Ledger as a model file with no source tree at all, and a model may have no way to fetch a
website. Search it before anything else.

**2. The library source**, when the install left it on disk. `Packages/Ledger/` from Wally,
`node_modules/@xoifail/ledger/src/` from npm, or wherever a Rojo project put `src`. There is none to
read if the game installed the `.rbxm` model file. When it is there it is the truth, and it beats
both the bundle and the site. `references/verify.md` says which file answers which question.

**3. The website**, https://xoifaii.github.io/LedgerDocs/docs, if you can fetch. Its
`llms-full.txt` is what the bundle is a copy of, so the only thing fetching buys is being newer.

The bundle is a generated copy, refreshed with one command, so it cannot drift on its own. It can
only be stale, and the date at the foot of this file says how stale. When the source and either copy
of the documentation disagree, the source wins, and say so.

The documentation has been wrong at least once. When the source and a page disagree, the source
wins, and say so plainly rather than quietly following one of them.

If you can reach neither, answer from what you know and **say that you could not check it**, naming
the page that settles it. An unchecked number offered as a fact is how a skill does harm.

An empty list here does not mean the pages are right. It means nobody has checked since the date
above. `references/verify.md` says how to check one in a minute, and that is the habit this skill is
built around.

## What each call touches

Classification is a property of the call, not of the intent behind it. Three columns, because one is
not enough.

| call | the record | MemoryStore | starts background work |
|---|---|---|---|
| `Inspect`, `History`, `PeekVersion`, `Read`, `Get`, `Expect`, `IsLoaded`, `WaitForLoaded`, `Stale` | no | no | no |
| `Session:Get`, `Session:Observe`, `Session:DidApply`, `LogSize`, `LogBytes` | no | no | no |
| `Holds` | no | one read | no |
| `Peek`, `Store:DidApply` | reads | no | **when it finds work** |
| `Total` | reads 16 keys when its sum is stale | reads, and writes the shared sum | no |
| `Load` | reads, and **settles what it finds** | no | when it finds work |
| `Apply` | queues, written on the next save | no | no |
| `Commit`, `CommitOp`, `Flush`, `Compact`, `Edit`, `Bump` | writes | no | no |
| `Reserve`, `Release` | no | writes | no |
| `Confirm` | writes | writes after | no |
| `Transfer` | 3 ops across 2 keys | no | on `Busy` or `Held` |
| `Tx` | writes every leg and a marker | leases each key | on `Busy` or a stranded leg |
| `Resettle`, `RecoverTransfers`, `ClearDelivered`, `Ledger.Sweep` | writes | no | no |
| `Unload`, `Session:Release` | writes, then closes the session | no | no |
| **`Reset`** | **writes the default back** | no | no |
| **`Erase`** | **buries the key, and removes it on a second call** | removes the key's holds | no |
| **`Destroy`** | **saves every session on that store, then ends them** | no | stops following its keys |
| **`CloseAll`** | **saves every session on every store, then ends them** | no | stops the sweep |

Five of those surprise people, and each has cost somebody time somewhere:

- **`Peek` and `Store:DidApply` hand the key to the recovery sweep** when they find a parked leg or
  money set aside. The sweep repairs it a minute later, which settles legs and can redrive or refund
  a transfer. A read can therefore cause money to move, later. That is Ledger working, not a bug, but
  it means "I only read it" is not always true.
- **`Load` settles what it finds.** Loading a player can commit a parked transaction leg and finish a
  transfer that a dead server left half done.
- **`Total` writes.** It claims the refill and writes the summed value back for the whole fleet.
- **`Confirm` is two writes that are not atomic**, the op on the key and then the hold being let go.
  A retry is deduped by the op id until the key compacts, and answers `Unresolved` after that.
- **`Erase` is two calls.** The first leaves a tombstone that turns away anything sent to the key for
  8 days. Only a second `Erase` after that window takes the record off.

## Stop before you destroy

`Reset`, `Erase`, `Destroy` and `CloseAll` are the bottom rows, and so is any loop that calls a write
on more than one key. Before any of them:

1. The **human named the key**, in their own words. A key you worked out yourself is not a named key.
2. You **read the record first** with `Inspect`, and showed it.
3. You said **which rung of the ladder** this is, from `references/working.md`.
4. You got **one confirmation for that key**. Approval for one key is not approval for the next.

Never run a destructive call to find out what it does. That is what the mock is for.

`references/working.md` is the long form, with the ladder saying what each rung costs and what can
get it back. When this summary and that file disagree, that file is the one that was thought about.

## Prove it on the mock

Ledger ships a fake datastore with the real caps and the real request budget. Use it.

```luau
local Store = Ledger.New({
	Name = "Probe",
	Default = { Gold = 100 },
	Reducer = Reducer,
	Mock = { Players = 8, Throttled = false },
})

Store:Edit(1, "SpendGold", { Amount = 30 }):Wait()
print(Store:Peek(1):Wait().Gold)
Store:Destroy()
```

**Any answer you are not certain of gets run here before you give it.** What a reducer does with an
op, which reason comes back, whether a migration keeps a field, whether an argument throws. It costs
ten lines. A probe never runs against a real key, and a real UserId is never a fixture.

What the mock cannot show, so do not claim it did: two builds during a rolling deploy, another live
server, the real MemoryStore memory accounting, real throttling under real contention, and anything
about the game's own data at scale.

**When nothing here answers the question, work down this ladder and stop at the first rung that
settles it.** Most questions are about this game's reducer meeting this library, so most are not in
any file here.

1. Read the source. `references/verify.md` says which file.
2. Run it on the mock.
3. Hand the developer a paste and run snippet and ask what it printed.
4. Say you do not know, and name the experiment that would settle it.

Never skip from 1 to 4. The mock ships with the library, so rung 2 is available to somebody, and an
unrun experiment is not an unknown. An invented answer about somebody's economy is the worst outcome
on this list, and it has already happened once in testing.

## Data is not code

The rules above are about **live player data**. They are not about the game's code.

- The developer asked to fix a reducer, so fix the reducer. That is ordinary work.
- A reversible write on a key the developer named, in a session they are driving, gets done and
  reported. Do not stop to ask.
- Anything on the bottom rows of the table stops and asks, every time.
- Do not edit a file nobody named, do not tidy code next to the thing you were asked to fix, and do
  not run any git command.

## Where to look

Answer the question that was asked. A question about one reducer is not an invitation to audit the
game. Load one of these, not all of them.

| the developer says | go to |
|---|---|
| "how do I install this" or "where do I start" | `getting-started` |
| "which should I use, Apply or Commit or Edit or Tx" | `guides/reservations#which-one-and-when-it-really-is-a-transaction`, then `concepts/apply-and-commit` |
| "what does this reason mean" | `concepts/reasons`, then `concepts/handling-failure` |
| "is it safe to retry this" | `concepts/handling-failure#why-a-retry-is-safe` |
| "how do I make this happen exactly once" | `concepts/once` |
| "move currency between two players", "a trade", "a gift" | `guides/transfers`, then `guides/transactions` |
| "limited stock", "a hold", "how long can I hold it" | `guides/reservations`, and the known wrong note above |
| "a pot", "a counter", "a total across servers" | `guides/reservations#bump-and-total` |
| "how do I test this" | `guides/testing`, and the mock block above |
| "clans, a guild bank, a global shop, a world record" | `guides/entity-stores` |
| "how does the player see this update" | `reference/observer`, then `guides/sessions#watching-state` |
| "how do I use this from TypeScript" | `guides/typescript` |
| "it said true and the value did not change" | `references/triage.md` |
| "money is missing" or "stuck in _Held" | `references/triage.md`, then `guides/transfers#crashing-halfway` |
| gives you a real UserId and says money went wrong | **`references/forensics.md` first**, before any call |
| "the key answers Busy and stays there" | `references/triage.md`, then `guides/transactions#stuck-legs` |
| "writes answer Full and I cannot fix it" | `references/triage.md`, then `guides/migrations#changing-the-reducer` |
| "a purchase was granted twice" | `concepts/once#processreceipt` |
| "my reducer" anything | `concepts/reducer`, then `concepts/advanced-reducers` |
| "this is slow" or "I am out of request budget" | `limits#what-an-operation-costs`, then `references/review.md` |
| "review my Ledger usage" | `references/review.md` |
| "we are deploying" or "Behind" | `guides/migrations#rolling-deploys` |
| a request that will hurt them | `references/pushback.md` |
| "I think this is a Ledger bug" | `references/escalate.md` |
| you are about to touch live data | `references/working.md` |
| you need to check a claim | `references/verify.md` |

`references/tiers.md` is the long form of the table above, with the call path behind every row.

## Never

Say it once, plainly, then do the work the developer asked for. Do not repeat it and do not moralise.

- Never suggest a session lock, a wait for another server, or a check of who else holds a key.
  Ledger has no locks by design and adding one breaks the property everything else rests on.
- Never suggest reading the clock, `math.random`, an Instance or an upvalue inside a reducer.
- Never write a reducer that returns the state unchanged for a kind it does not handle. Ledger reads
  any table as accepted, so that marks a `Once` name granted while nothing was granted. Return `nil`.
- Never suggest matching on the text of an error. Compare against `Ledger.Reason`.
- Never retry `Refused`. The reducer said no and the answer will not change.
- Never retry an `Unresolved` write under a **new** id. That is how a game pays twice.
- Never treat `Behind` as "this player has no data", and never write a fresh profile over it.
- Never treat `Spent` as success. Nothing moved, and for a transfer the money went back.
- Never claim MemoryStore is needed for correctness. Only `Reserve` needs it, and it says so.
- Never write a bulk destructive loop on a first pass. Print the list and the count instead.
- Never invent a method. The surface is closed, and `reference/store` and `reference/session` list
  all of it.

## What this is checked against

Ledger 5.0.0, checked against `src` and the documentation on 2026-09-04. Every claim in these files
can be checked in under a minute with `references/verify.md`. If a check fails, the source is right
and this file is stale, so say so.
