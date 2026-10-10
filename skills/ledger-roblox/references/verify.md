# Checking a claim

When the library source is on disk, almost anything can be settled in a minute. Do that rather than
remembering, and do it before saying a number out loud.

**The documentation is not always right.** Fixes have landed in the source after the docs described the
old behaviour. If a page and the source disagree, the source wins. Say which one was wrong rather than
quietly following one.

## Where the source is

| Install | Path |
|---|---|
| Wally | `Packages/_Index/xoifaii_ledger@<version>/ledger/` (the `Packages/Ledger` file only points there) |
| npm (roblox-ts) | `node_modules/@xoifail/ledger/` |
| Rojo, from the repo | `src/` |
| `.rbxm` model | none on disk; read it in Studio, or use the bundle |

Paths below are relative to that folder.

## Where each answer lives

| The question | The file |
|---|---|
| every public function on `Ledger` | `init.luau` (the `return` at the foot) |
| every method on a store, session, quantity and key pager, with exact types | `Types.luau` |
| the 15 reasons | `Constants/Reasons.luau` |
| name rooms, the state cap, the epoch, answer bounds, queue sizes, mark caps | `Constants/Record.luau` |
| every setting's default and allowed range | `Constants/Settable.luau` |
| settle age, touch bound, orphan age | `Constants/Transaction.luau` |
| copies, `Follow` ticks, totals' shards | `Constants/Extras.luau` |
| quantities: holds, walk tries | `Constants/Hot.luau` |
| `Reset`/`Erase` bounds, when `Close` removes parts | `Constants/Cuts.luau` |
| every throw's message, and what makes each call throw | `Api/Validate/Args.luau`, `Setup.luau`, `Cross.luau`, `Keys.luau`, `Legs.luau`, `Quantity.luau` |
| which `Info` fields each answer fills | `Api/Answers.luau` |
| which leg decides a `Tx` | `Tx/Call/Terms.luau` (`ChooseDecider`) |
| what Studio checks in the reducer, frozen inputs, undeclared fields | `Judging/Guards.luau`, `Shell/Setup.luau` |
| the `Mock` option and its errors | `Shell/Services.luau` |
| the close, `BeforeClose`, the 25 s deadline | `Shell/Runner.luau`, `Sessions/Closing.luau` |
| `Unreadable` and its warnings | `Reading/Unreadable.luau` |
| a refused Roblox request (403, 101 to 106) | `Shell/Refusals.luau` |
| when a read ends a dead server's trade work | `Tx/Work/Touch.luau` |
| store calls, session calls, quantity calls | `Api/Store.luau`, `Api/Sessions.luau`, `Api/Session.luau`, `Api/Quantity.luau` |

Every file opens with a header comment saying what it is and what's subtle about it. Read the header
first; it is the only prose in the file.

## Checking a number

```
grep -n "TimedRoom\|UntimedRoom\|StateCap\|OpBound\|MarkCap" Constants/Record.luau
grep -n "SaveInterval\|IdleReadInterval\|CutWindow\|OrphanAge\|HoldMax" -A3 Constants/Settable.luau
```

Read the value and the line beside it. Say which constant a number came from; don't convert it in your
head and quote the result as if you'd read it.

## Checking the surface

The set of methods is closed. To be sure one exists before recommending it:

```
grep -oE "^	[A-Z][A-Za-z]+: \(" Types.luau | grep -oE "[A-Z][A-Za-z]+" | sort -u
```

That prints every method on a store, a session, a quantity and a key pager, and nothing else. On 7.0.0
it prints 40 names. The module itself has `New`, `Now`, `Id`, `Tx`, `CloseAll`, `BeforeClose` and
`Reason`, and nothing more: there is no `Ledger.Version`, `Ledger.Credit`, `Ledger.Debit`, `Transfer`,
`Reserve` or `Once`. Anything not printed doesn't exist, however plausible it sounds.

## When nothing here answers it

Most questions aren't in this skill or in the documentation, because they're about this game's reducer
meeting this library. Don't guess, and don't answer from the shape of the API. Work down this ladder and
stop at the first rung that settles it.

1. **Read the source.** The table above says which file. Most questions end here.
2. **Run it on the mock.** Below. This is the rung that answers "what does it actually do".
3. **Ask the developer to run it.** When you can't execute Luau, hand them a paste-and-run script that
   prints the answer, and ask for the output.
4. **Say you don't know.** Name what you tried, what the answer turns on, and the one experiment that
   would settle it.

Never skip from 1 to 4. An unrun experiment is not an unknown.

## Checking a behaviour

Run it. A few lines on the mock, with the game's own reducer:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ledger = require(ReplicatedStorage.Packages.Ledger)
local Mock = require(ReplicatedStorage.Packages.Mock)

local Store = Ledger.New({
	Name = "Probe",
	Keys = "String",
	Default = { Stock = 0 },
	Reducer = Reducer,
	MustExist = false,
	Erasable = false,
	Mock = Mock.New({ Players = 8, Throttled = false }),
})

print(Store:Edit("thing", { Kind = "Restock", Amount = 500 }))
print(Store:Peek("thing"))
```

For something that might throw rather than answer, wrap the call in `pcall` and print both, because
Ledger throws on misuse and answers a reason for everything else. Which of the two a mistake gives is
itself worth checking when it isn't obvious.

### What to print

All three values of every answer, never just the boolean. `Info` holds the state an op was judged on,
the key that decided a trade, and the `Outcome` of an `Unresolved` call.

```luau
print(Store:Peek(Key))
print(Store:Inspect(Key))
print(Store:Pending(Key))
print(Store:Losses(Key))
```

Ledger's warnings are instrumentation too. Capture them; don't summarise them.

### Rules for a probe that proves something

- **Use the game's own `Default`, `Reducer`, `Balances`, `Migrations` and `Quantities`.** A probe
  against a different reducer proves nothing about theirs.
- **Pick values where each outcome reads differently.** Spend 30 from 100, then add 7. Never 100 and
  100.
- **Check the probe reached the case.** A green run where the branch never fired is not evidence.
- **A probe runs in its own script or place.** The mock is per server, every store runs on it, and it
  must be given before Ledger's first request. A probe that shares a server with stores that already
  made a request throws.
- **`Throttled = false`** while testing logic. Leave it on, with `Players` set, when the question is
  about the request budget.

### What a probe can't reach

The mock has no scheduler: a probe runs in real time. A 180 s name window or a 10 s settle age can be
waited out in a probe; a 62-minute part removal, a 7-day loss record or a day's `OrphanAge` can't be.
Ask what happens at the boundary rather than across it, set the window to its least value where the
setting allows (`Windows` 136 s, `CutWindow` 318 s, `OrphanAge` 3,600 s), or say the probe can't reach
it.

A single server can't show two servers. Two stores with the same `Name` can't be opened on one server,
so "what does another server see" is a question for the source, or for a test universe with two
servers.

## Asking the developer to run it

When you can't execute Luau, the script you hand over must be paste-and-run: one Script in
`ServerScriptService` of an empty place, no edits needed, printing the one thing in question. Use the
mock, never their live stores.

Say what you expect to see and what each outcome would mean, **before** they run it. Then they can tell
you which happened in one line, and a disagreement with your expectation is the finding.

## Saying you don't know

Do it plainly and early. Name the rung you got to, what the answer turns on, and the experiment that
would settle it. "I read `Api/Validate/Args.luau` and it doesn't say, and I can't run Luau here, so run
this and tell me what it prints" is a good answer. An invented number is not.

## Saying what you did

State which of these you did. "Checked `Constants/Record.luau`" and "ran it on the mock" are different
levels of evidence from "I believe", and the developer deserves to know which one they got.
