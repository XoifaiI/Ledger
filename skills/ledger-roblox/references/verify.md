# Checking a claim

Ledger ships its whole source, so almost anything can be settled in under a minute. Do that rather
than remembering, and do it before saying a number out loud.

**The documentation is not always right.** 
If a page and the source disagree, the source wins. Say which one was wrong rather than quietly
following one.

## Where each answer lives

Paths are inside the package, the same tree a `require` reaches.

| the question | the file |
|---|---|
| how long is any window, and why is it that long | `Core/Constants/Windows.luau` |
| every byte cap | `Core/Constants/Sizes.luau` |
| the ten reasons | `Core/Constants/Reasons.luau` |
| every public method and its exact signature | `Core/Api.luau` |
| what a record holds | `Core/Shapes.luau` |
| how a name is remembered and pruned | `Core/Applied.luau` |
| the rules an append runs, in order | `Record/Rules.luau` |
| when a key compacts, and what blocks it | `Record/Compact.luau` |
| migrations, the floor, and the underscore fields | `Record/Schema.luau` |
| the three transfer legs | `Layers/Escrow.luau` |
| the transaction protocol | `Protocol/Tx/` |
| what a session admits and why | `Session/Admit.luau` |
| the public writes and their argument checks | `Store/Api/Ops.luau` |
| the operator calls | `Store/Api/Admin.luau` |
| the real datastore limits Ledger models | `Core/Constants/Datastore.luau` |
| the MemoryStore limits | `Core/Constants/MemoryStore.luau` |

Every file opens with a header saying what it is and what is subtle about it. Read the header first.
There are 90 of them and the header is the only prose in the file.

`Core/Constants/Windows.luau` is worth knowing for another reason: each window carries an assert
saying how it must relate to the others, in a sentence. Those asserts are the best short explanation
of why the horizons are the sizes they are.

## Checking a number

```
grep -n "PRUNE\|REDRIVE\|TOMB\|BOOK" src/Core/Constants/Windows.luau
```

Read the value and the assert next to it. Do not convert it in your head and quote the result without
saying which constant it came from.

## When nothing here answers it

Most questions are not in this skill and are not in the documentation either, because they are about
this game's reducer meeting this library. Do not guess at those, and do not answer them from the
shape of the API. Work down this ladder and stop at the first rung that settles it.

1. **Read the source.** The table above says which file. Most questions die here.
2. **Run it on the mock.** Below. This is the rung that answers "what does it actually do".
3. **Ask the developer to run it.** When you cannot execute Luau yourself, hand them a snippet that
   prints the answer and ask for the output. Make it paste and run, with no edits needed.
4. **Say you do not know.** Name what you tried, what the answer depends on, and the one experiment
   that would settle it. A named unknown is useful. A confident guess about somebody's economy is
   not.

Never skip from 1 to 4. The mock ships with the library, so rung 2 is always available to somebody,
and an unrun experiment is not an unknown.

## Checking a behaviour

Run it. Ten lines against the mock, with the game's own reducer:

```luau
local Store = Ledger.New({
	Name = "Probe",
	Default = { Stock = 0 },
	Reducer = Reducer,
	Mock = { Players = 8, Throttled = false },
})

local Ok, Why = Store:Edit("thing", "Restock", { Amount = 500 }):Wait()
print(Ok, Why, Store:Peek("thing"):Wait().Stock)

Store:Destroy()
```

For something that might throw rather than answer, wrap the call in a `pcall` and print both, because
Ledger throws on misuse at the call site and answers a reason for everything else. That difference is
itself worth checking when it is not obvious which one a mistake will be.

### What to print

The state is the folded answer. The record is what is actually on the key, and most surprises live
there rather than in the state.

```luau
print(Store:Peek(Key):Wait())        -- what the player has
print(Store:Inspect(Key):Wait())     -- the snapshot, the ops, the seen ids, the version
print(Session.LogSize, Session.LogBytes)
print(Store:Holds(Key, "Stock"):Wait())
print(Store:History(Key, 5):Wait())
```

Ledger's own warnings are instrumentation too. They name the key and the amount, so capture them
rather than summarising them.

### Rules for a probe that proves something

- **Use the game's own `Default`, `Reducer` and `Migrations`.** A probe against a different reducer
  proves nothing about theirs.
- **Pick values where each answer reads differently.** Spend 500 then add 500 balances whether or not
  the op applied twice. Use 1, 10, 100 and 1000, never 100 and 100.
- **Check the probe actually did the thing.** A green run where the fault never fired, or the branch
  was never reached, is not evidence. Print the count.
- **`Store:Destroy()` at the end**, or the next probe cannot claim the same store name.
- **`Throttled = false`** while testing logic, and `Mock = { Players = 30 }` when the question is
  about the request budget.

### Time

A store takes no scheduler, so a probe cannot move the clock through the public surface. Anything
gated on a real window, a 15 minute hold, an 8 day tomb, a 30 day name, cannot be reached by waiting
in a script.

Two honest options. Shrink the question until it fits: ask what happens at the boundary rather than
across it, or drive the state directly with `Edit` to where the window would have put it. Or reach
past the public surface for a probe only, never for game code:

```luau
local Tree = game:GetService("ServerStorage").Ledger   -- the folder, not the required module
local Clock = require(Tree.Util.Clock)
local Virtual = require(Tree.Schedulers.Virtual)

local Turn = Virtual.New()
Clock.Use(Turn)                      -- before any store is built
-- build stores here, then Turn.Advance(seconds) and Turn.Run()
```

That is internal, it is not part of the five public entries, and it must be called before any store
exists. Say so when you use it, and never leave it in a game.

## Asking the developer to run it

When you cannot execute Luau, the snippet you hand over has to be paste and run. One Script in
`ServerScriptService`, no edits, and it prints the one thing in question:

```luau
local Ledger = require(game:GetService("ServerStorage").Ledger)

local Store = Ledger.New({
	Name = "Probe",
	Default = { Gold = 100 },
	Reducer = YourReducer,
	Mock = { Players = 8, Throttled = false },
})

local Ok, Why = Store:Edit(1, "SpendGold", { Amount = 30 }):Wait()
print("answer", Ok, Why)
print("record", Store:Inspect(1):Wait())

Store:Destroy()
```

Say what you expect to see and what each outcome would mean, before they run it. Then they can tell
you which happened in one line, and a disagreement with your expectation is the finding.

## Saying you do not know

Do it plainly and early. Name the rung you got to, what the answer turns on, and the experiment that
would settle it. "I read `Store/Api/Ops.luau` and it does not say, and I cannot run it here, so run
this and tell me what it prints" is a good answer. An invented number is not, and two of them in one
of these runs put a fabricated `Promise` return type into a review.

## Checking the surface

The set of methods is closed. To be sure a method exists before recommending it:

```
grep -oE "^\s+[A-Za-z]+: \(self: any" src/Core/Api.luau | grep -oE "[A-Za-z]+" | grep -v "self\|any" | sort -u
```

That prints every method on a store and on a session, and nothing else. Checked on 2026-09-04 it
prints 34 names. Anything not in there does not exist, however plausible it sounds.

## Checking what touches what

```
grep -rn "self:Watch\|:WatchHeld\|Sweep:Add" src
grep -rn "self.Tallies\|self.Leases\|self.Bookings" src
```

The first is every place a key is handed to the recovery sweep. The second is every place MemoryStore
is touched. `tiers.md` is built from those two greps and can be rebuilt from them.

## Saying what you did

State which of these you did. "Checked `Windows.luau`" and "ran it on the mock" are different levels
of evidence from "I believe", and the developer deserves to know which one they got.
