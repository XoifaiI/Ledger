# Ledger's TLA+ models

These are the TLA+ models behind [Ledger](https://github.com/XoifaiI/Ledger), a data library for Roblox
games. They check that saves, trades, limited-item sales, totals and deletes keep their promises (no gold
made or lost, nothing applied twice, a trade all or nothing) under everything Roblox's DataStore and
MemoryStore are allowed to do: lost answers, writes that land after an error, stale reads, retried
transforms, outages, crashes and clock skew.

## Layout

| Folder | What's in it |
| --- | --- |
| `env/` | `Env.tla`, the model of the platform every other model builds on, and `controls/`: small models that each turn one platform fault on, to show which faults the designs have to survive |
| `bounds/` | Lower bounds: what no design can do on this platform, each with a witness model |
| `protocols/record/` | One key and its writers: once-only ops, names, horizons, sessions, reads |
| `protocols/transaction/` | Trades across keys (`Tx.tla`), with resets, erases, mixed builds and migrations |
| `protocols/hotkeys/` | Limited items split across parts (`Hot.tla`) |
| `protocols/extras/` | Totals (`Tot.tla`) and copies (`Copy.tla`) |
| `protocols/composed/` | Every protocol that writes a key, together on one key (`Comp.tla`) |

Each folder has its own copy of `Env.tla`, so every folder runs on its own. The copies are identical.

Files named `...Abs.tla` model a protocol at the level of landed writes, for proofs. `...Proofs.tla` and
`TxAbsSums.tla` are TLAPS proofs. `Apa...tla` and `MC...tla` give constants for Apalache and TLC.

## What each config checks

Every folder has an `EXPECT` file with one line per config:

```
<cfg> <Module> expect=<outcome> [timeout=<seconds>] [tool=tlc|apalache|tlapm] [args=<flags>] [why=<text>]
```

`expect` is `pass`, `violate:<Property>`, `temporal`, `deadlock`, `error`, or for a proof `proved`. The
`why` says what the run shows. The timeouts are for a 32-core machine with 8 workers.

Many configs are meant to fail:

- **`Ctl...`** turns one rule of the design off and must break a property. It shows the rule is needed
  and that the check can fail at all.
- **`Probe...`** must fail with `ScriptUnfinished`. It shows the matching passing run really reached the
  end of its scenario, rather than passing because it stopped early.
- **`Find...`** reproduces a problem found in an earlier version of the design.

## Running

TLC, from the folder that holds the model:

```
java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers 8 -config Smoke.cfg Tx
```

The controls in `env/controls/` extend `Env` from the folder above, so give TLC that folder as a library:

```
java -DTLA-Library=.. -cp tla2tools.jar tlc2.TLC -config LeaseSure.cfg Lease
```

Add `-simulate -depth <n>` where a line's `args` asks for random walks.

The models were checked with TLC from tlaplus commit `54e73ad` (the standard `tla2tools.jar` release works), Apalache for the `tool=apalache`
lines, and TLAPS for the proofs. `protocols/transaction/` carries copies of `Folds`, `Functions` and
`FiniteSetsExt` from the [TLA+ Community Modules](https://github.com/tlaplus/CommunityModules) (MIT
license), unchanged. The proofs also need `TLAPS`, `FiniteSetTheorems`, `NaturalsInduction` and
`WellFoundedInduction` from the TLAPS library, and `FoldsTheorems`, `FunctionTheorems` and
`FiniteSetsExtTheorems` from the Community Modules.

## Reading the comments

The comments cite Ledger's design notes by section: the record, transaction, hot keys, cuts and
extras designs, the property list (ids like S5, A3, C3), the platform facts (ids like D10) and the
design rules. Those notes aren't published with the models. The models and their comments stand on
their own: each property is defined in the model that checks it.
