# Migrations

New fields in your `Default` are free. Reconcile fills any key a stored profile is missing:

```luau
local Default = {
	Gold = 100,
	Items = {},
	Settings = {}, -- new, every existing profile picks it up on load
}
```

A rename or a restructure needs a migration:

```luau
local Store = Ledger.New({
	Name = "PlayerData",
	Default = Default,
	Reducer = Reducer,
	Migrations = {
		-- v0 to v1, a rename
		function(State)
			State.Inventory = State.Items
			State.Items = nil
			return State
		end,

		-- v1 to v2, additive, safe for old servers to ignore
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

The array index is the format version. A record remembers the version it was written at, runs
only the steps it has not seen, and the next compaction writes the migrated shape. Each step
sees the previous step's output, so a new migration is always written against the latest shape.

## The rules

**Append only. Never edit or reorder a released step.** It has already stamped versions into
stored records.

**A newer record refuses to load on an old server**, and the player is kicked like any failed
load. During a rolling deploy an old server must never fold a new format save and compact it
back down. Old servers soft shutdown on update, so the window is minutes.

**`Compatible = true` softens that** for steps old code can safely ignore. The record remembers
the newest incompatible version as its floor; an old server that knows at least the floor loads
a future record untouched and preserves its version instead of downgrading it. A plain function
step is incompatible by default, so renames kick stale servers and additive steps opt in. Only
set it when old reducers really do work against the new shape.

**Op kinds are contracts.** Ops written before a migration may fold after it, so keep handling
old kinds against the new shape:

```luau
-- the migration renamed Items to Inventory, but old AddItem ops are still in logs
if Op.Kind == "AddItem" then
	local Next = table.clone(State)
	Next.Inventory = table.clone(State.Inventory)
	Next.Inventory[Op.Item] = true
	return Next
end
```

Compaction keeps that tail brief, but it is real.

**Steps must be pure and total.** Same input, same output, always return the table. A step that
throws or yields fails the load loudly, which beats a half migrated save.

**Deleting a field?** Drop it from `Default` too, or Reconcile refills it on every load and the
removal never takes. `New` runs your chain over the `Default` once and names the field if you
forget.

A `Reset` carries the writer's version, so a server that does not know it refuses the reset
rather than folding a future shape down. It lands once that server updates.
