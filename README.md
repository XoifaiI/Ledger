# Ledger 7

The rewrite of Ledger on the verified design in `E:\src\LedgerSim\spec\protocols` (each protocol's
`Chosen.md`, with the findings and fixes in its `README.md`, and the TLA+ specs beside them).

## Shape

- **Core** is pure: no services, no clock reads, no yields. `Step` is the one transform every write
  runs, the rules in record 4's order with each protocol's op kinds plugged in. Each call on a server
  is a state machine (`Core/Machine`) whose transitions return effects and never perform them.
- **Driver** runs a machine: it performs its effects and hands their results back as events.
- **Adapters** are what the driver talks to: Roblox's DataStore and MemoryStore, a mock, and a trace
  recorder for checking runs against the TLA+ specs.

## Names

The code uses the standard term where one exists, not the design's shorthand:

| design | here |
|---|---|
| Tent (tentative write) | Prepare |
| Mark | Lock |
| Decider | Primary |
| Resolve | Finalize |
| Pinned record | Decision |
| Horizon `h` | Watermark |
| Writer entry (`lo`) | Producer sequence |
| Hopeful op | Optimistic op |
| Gate | Barrier |
| Seal | Tombstone |
| Touch | Repair |
| Walk | Failover |

`Commit` and `Fence` keep their names.

## Commands

```bash
zune test tests/Run.luau               # every suite, through Zune's describe, test and expect
zune setup vscode                      # once: writes Zune's type definitions to ~/.zune/typedefs
rojo sourcemap test.project.json -o sourcemap.json
luau-lsp analyze --flag:LuauSolverV2=true --base-luaurc=.luaurc --sourcemap=sourcemap.json \
  --definitions="$HOME/AppData/Roaming/Code/User/globalStorage/johnnymorganz.luau-lsp/globalTypes.PluginSecurity.d.luau" \
  --definitions="$HOME/.zune/typedefs/global/zune.d.luau" \
  src tests
stylua --check src tests bench
./luau.exe -O2 --codegen bench/Bench.luau          # a whole book and a whole call; bench/Parts.luau per primitive
./luau-compile.exe codegenverbose -O2 src/Encode/Writer.luau   # the native IR, with each argument's type
```

Hot modules take a plain table and local functions, not a `setmetatable<>` class. Native code types
a class argument as userdata and looks up every field the slow way: 32 ns a call against 11 ns.

Zune's Luau (0.700) does not parse explicit instantiation `<<...>>`, so code it runs uses annotated
locals instead. A suite takes `Describe`, `Test`, `Expect` and `Similar` from `tests/Testing`, since
the new solver cannot call Zune's own `expect` type. `toThrow` matches the whole message, and
`Similar` compares a table by what it holds, which Zune's `toEqual` does not. The checker passes on the pinned luau-lsp 1.68.1 and on the editor's 1.70.1.
