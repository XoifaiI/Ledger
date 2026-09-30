# The map of Ledger

Ledger keeps player data as a ledger. Every write to a key goes through one transform, `Step`, and
every behaviour of a server is a state machine that asks for writes and reads and hears what came
back. The TLA+ models in `LedgerSim/spec/protocols` prove the design. This file says which part of
the code is which part of those models.

## Four kinds of file

The first line of every header names the file's kind, and a `Spec:` line names the section of
`Chosen.md` it implements, when there is one.

| kind | what it holds | what it may not do |
|---|---|---|
| **Logic** | data shapes and pure functions | keep state between calls, yield, touch a service, read the clock |
| **Machine** | one behaviour of a server: its states, and what each state does with what it hears | touch a datastore, wait, spawn, read the clock |
| **Object** | what the game holds, and the tables one server keeps | decide anything a model decides |
| **Plumbing** | what no model describes: encoders, the machine and its runner, adapters, utilities | |

## The folders

```
src/
  init.luau      the entry: Answer, New, Tx, CloseAll
  Record/        Logic. One key, the one transform that writes it, and the rules around it.
  Calls/         Machines. One file per behaviour of a server.
  Machine/       Plumbing. The machine, what it may ask, and the runner that answers.
  Store/         Objects, and the Logic that checks what a game asks.
  Core/          Answers, errors, the reducer fold, and every constant.
  Encode/        Bytes: the alphabet, varints, names, hashes, value sizes.
  Util/          Future, Observer, Lru, Bits.
  Adapters/      The only files that call DataStoreService or MemoryStoreService.
```

## Record: the pure core

A key holds `{ s = state, b = book, p = diff }`. `Step(current, request, clock, build)` gives back a
note, and the note holds the value to write, or nothing.

| file | what it is | spec |
|---|---|---|
| `Book` | the book: fixed fields, the rooms and their items, as text | record 2 |
| `Key` | what a key's value holds, read and written | record 2.1 |
| `Step` | the order of checks every write runs | record 4 |
| `Rules` | one function per check an op meets | record 4, step 4 |
| `Work` | a transaction's steps on one key: Tent, Commit, Fence, resolves, drops | transaction 3.2 to 3.5 |
| `Marks` | when an op may land beside marks | transaction 4.1 |
| `Rooms` | the room widths; age, fit and evict | record 2.4; record 4, steps 7 and 8 |
| `Queue` | the ops one server has for one key, and what each note says of each op | record 3.1 to 3.4 |
| `View` | a key as one build reads it | record 5.3, 7 |
| `Blockers` | what a decider's value or a fence's report says of a use | transaction 4.2 |
| `Touches` | when a server that sees an old item may end it | transaction 5.1 |
| `Shown` | what this server has shown of each key (an Object) | record 5.3 |
| `Guard`, `Migrate`, `Diff`, `Types` | the reducer's fence, migrations in memory, an exclusive mark's diff, the shared shapes | record 4, 7; transaction 2 |

A test for this folder runs `Step` on a plain table and reads the note. It needs nothing else.

## Calls: one machine per behaviour

Every machine has the same contract. It **asks** for one of five things, and **hears** one reply.

| ask | what the runner does | what the machine hears |
|---|---|---|
| `Send(ref, request)` | one `UpdateAsync` that runs `Step`, with retries | the note, whether a run wrote, the ops any run decided; or Failed |
| `Read(ref)` | one `GetAsync`, with retries | the value; or Failed |
| `Wait(seconds)` | waits | nothing |
| `Run(machine, context)` | runs another machine | its answer |
| `Count(index)` | adds 1 to a counter key | the count its own write made; or Failed |

The runner puts the time on every reply, so no machine reads a clock. A test builds a reply by hand
(`tests/Heard.luau`), steps the machine with it, and checks what it asks next. `tests/Replay.luau`
runs a machine end to end with the real `Step` on plain keys.

| file | behaviour | spec, and model action |
|---|---|---|
| `Save` | send one key's queue until it is empty; rest; run `Unblock` when a mark blocks it | record 3.2, 6; `Rec.tla` Send, Hear |
| `Peek` | Load and Peek: the shown table, a fresh read, reads beside marks | record 5.3; transaction 4.3 |
| `DidApply` | whether a name took effect | record 5.3 |
| `Tx` | a transaction's coordinator: Tents, Commit, the final fence, resolves, verification | transaction 3.1, 3.6, 3.7; `Tx.tla` Steps |
| `Unblock` | get past one mark: read its decider, fence it when due | transaction 4.2 |
| `Touch` | end one item another server left, and the orphan rule | transaction 5.1 |
| `Resettle` | end every item on a key now, and say whether it is clear | transaction 5.3 |
| `Number` | take a server number | record 3.1 |

`Save` and `Tx` run `Unblock` as a child machine, so the rule of 4.2 lives in one file.

### How a state reads

A state has up to four parts. `Enter` makes its asks. `Hear` turns what came back into one word; with
no `Hear` the word is the reply's own, and with several asks it is a named function that folds them,
in the priority order the spec gives. A table next to that order gives the word each reply says, as
`TENT_WORDS` and `TENTS` do in `Tx`. `On` is the table of rows, and `Else` is where every other word
goes. A state with no `Else` is final.

```luau
[STATE.Committing] = {
	Enter = Commit,
	On = {
		{ Said = Report.Committed, Go = Committed },
		{ Said = Report.Fenced, When = NotFinal, Go = NextAttempt },
		{ Said = Report.Fenced, Go = Aborted(Answer.Spent) },
		{ Said = Report.Blocked, When = Blocked, Go = Help(STATE.Committing) },
	},
	Else = STATE.Fencing,
},
```

The first row whose `Said` matches and whose `When` passes wins. `Go` is a state, or a named action
that answers or changes the context and gives back a state. `Machine.Define` refuses a state with rows
and no `Else`, and a `Go` to a state that is not there.

## Store: what the game holds

| file | kind | what it is |
|---|---|---|
| `Store` | Object | the object `Ledger.New` gives back. Each method checks its arguments and runs one call. |
| `Session` | Object | a loaded player: the view, and the ops queued on it. `Apply` judges on the view and sends nothing. |
| `Runtime` | Object | what one server keeps: its numbers, the shown table, one queue per key, the heartbeat. It runs `Save` on each queue. |
| `Build` | Logic | a config, checked and made into the build every write judges with |
| `Ops` | Logic | the op a durable call asks for, and its name and stamp |
| `Terms` | Logic | a transaction's legs, checked, with the decider and the fingerprint |

## One call, end to end

A transfer of 30 gold from key `a` to key `d`:

1. `Store.Tx` checks the legs with `Terms` and picks `d` to decide. It runs `Calls/Tx`.
2. `Tx` asks `Send(a, Tent)`. The runner runs `Step` on `a`, and `Record/Work.Tent` sets 30 aside in a mark.
3. `Tx` hears `Mine`, and asks `Send(d, Commit)`. `Record/Work.Commit` adds 30 to `d` and pins the use.
4. `Tx` hears `Committed`, answers `true`, and asks `Send(a, resolve)`. `Record/Work` takes the 30 off `a`.

Each step is one row of `Tx.tla`, and each check it meets is one function in `Record`.

## Rules every file keeps

- The header's first line names the kind. A `Spec:` line follows when the file implements a section.
- A Logic file is a table of functions. It has no metatable and no yield, and it gives the same
  answer for the same arguments.
- A Machine file gives back its machine and a `Context` function. Its states sit in one table at
  the foot of the file, and each decision is a named function above them.
- Only the Objects are classes with state, and only `Machine/Runner`, the Objects and `Adapters`
  wait or spawn. Only `Adapters` call a service.
