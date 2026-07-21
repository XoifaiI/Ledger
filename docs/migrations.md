# Migrations

New default fields are free: the reconcile step fills any key present in your `Default`
that a stored profile is missing. A rename or a restructure needs a migration.

```luau
local Store = Ledger.New({
	Name = "PlayerData",
	Default = Default,
	Reducer = Reducer,
	Migrations = {
		-- v0 -> v1
		function(State)
			State.Inventory = State.Items
			State.Items = nil
			return State
		end,
		-- v1 -> v2, additive, safe for old servers to ignore
		{
			Compatible = true,
			Apply = function(State)
				State.Settings = {}
				return State
			end,
		},
	},
})
```

Migrations are an ordered array where the index is the format version. A stored record
remembers the version it was written at. On every load, the snapshot runs through just
the steps it has not seen, then ops fold as usual, and the next compaction writes the
migrated shape with its version so the steps stop replaying. Each step sees the previous
step's output, so a new migration is always written against the latest shape.

## The rules

**Append only, never edit or reorder.** A released step has already stamped versions into
stored records. Changing it desynchronizes every record it touched.

**A record from a newer version refuses to load on an old server**, and the player is
kicked exactly like a failed load. This is deliberate: during a rolling deploy an old
server must never fold a new-format save and compact it back down. Old servers
soft-shutdown on update as usual, so the window is minutes.

**`Compatible = true` softens that refusal** for steps old code can safely ignore, like a
new field with a default. The record remembers the newest incompatible version as its
floor; an old server that knows at least the floor loads a future record untouched,
running no steps against the already-new shape, and its compaction preserves the record's
version instead of downgrading it. A plain function step is incompatible by default:
renames and restructures should kick stale servers, additive steps opt in. The flag is a
promise that old reducers and old code work against the new shape, so only mark it when
that is actually true.

**Op kinds are contracts.** Ops written before a migration may fold after it, so when a
step changes a field an existing kind touches, the reducer must keep handling that kind
against the new shape. Compaction keeps logs short, so this tail is brief, but it is real.

**Steps must be pure and total.** Same input, same output, always return the table. A
step that throws fails the load loudly; better a kick than a half-migrated save.

**Deleting a field a migration added?** Reconcile refills anything present in `Default`,
so drop it from the Default too.
