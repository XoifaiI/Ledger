# Getting started

## Install

**Rojo**: clone the repo and add it to your project, or drop the `src` folder in as
`ServerStorage/Ledger` (the folder becomes the module, `init.luau` is its root).

**Wally**:

```toml
[server-dependencies]
Ledger = "xoifaii/ledger@2.0.1"
```

**Model file**: insert the `Ledger` module anywhere server-side. `ServerStorage` is the
natural home. Everything below assumes `ServerStorage.Ledger`.

Ledger is server-only. It never replicates and has no client half.

## The vocabulary

A handful of terms carry the whole library. The rest of this page uses them freely.

- **Op**: one immutable change, a table with a `Kind` and whatever fields that kind needs, like
  `{ Kind = "SpendGold", Amount = 25 }`. Everything that ever changes a record is an op.
- **Reducer**: your `(State, Op) -> State?` function. It takes the current state and an op and
  returns the next state, or `nil` to reject the op. This is where your game's rules live.
- **State**: the current data for a key, a plain table. It is never written directly. It is
  always computed.
- **Fold**: replaying every op through the reducer, starting from the `Default`, to compute the
  current state. State is the fold of the log.
- **Log**: the append-only list of ops a record stores. Ledger appends to it and folds it; it
  never overwrites.
- **Store**: what `Ledger.New` returns, one per datastore. You call its methods to load
  sessions and make cross-server changes.
- **Session**: the live, in-memory state for a loaded player, held on the server that loaded
  them. Where `Apply` and `Commit` happen.
- **Key**: what a record is filed under. A UserId on a player store, a plain string on an
  entity store.

## Build a store, before anyone joins

```luau
local Ledger = require(ServerStorage.Ledger)

local Default = {
	Gold = 100,
	Items = {},
}

local function Reducer(State, Op)
	if Op.Kind == "AddGold" then
		local Next = table.clone(State)
		Next.Gold += Op.Amount
		return Next
	elseif Op.Kind == "SpendGold" then
		if Op.Amount > State.Gold then
			return nil -- rejects the op
		end
		local Next = table.clone(State)
		Next.Gold -= Op.Amount
		return Next
	end
	return nil
end

local Store = Ledger.New({
	Name = "PlayerData",   -- the datastore name
	Default = Default,     -- a fresh player's starting data
	Reducer = Reducer,     -- decides whether each change is legal
})
```

`New` validates everything up front and hands back the store you call methods on. A missing
name or reducer, an unstorable value or a `_` prefixed key in the Default, a malformed
migration step, or a name longer than 47 characters all throw immediately, when you build
the store, instead of surfacing at the first player. Keep the returned store somewhere your
other server code can reach it.

Three optional fields join these. `Balance` names the numeric field that
[`Transfer`](cross-server.md) moves, `Migrations` handles [shape changes](migrations.md),
and `Keys = "String"` makes an [entity store](cross-server.md) keyed by strings instead of
player ids.

If those fields feel small, that is the point. The `Reducer` is where your game's rules
live, and [the model](the-model.md) explains how to write a good one.

## Wire the lifecycle

Ledger is passive. Your boot script owns when players load and leave:

```luau
local function OnPlayer(Player)
	Store:Load(Player)      -- folds the log into a live session, starts autosave
end

Players.PlayerAdded:Connect(OnPlayer)
for _, Player in Players:GetPlayers() do
	task.spawn(OnPlayer, Player) -- anyone who joined before this script ran
end

Players.PlayerRemoving:Connect(function(Player)
	Store:Unload(Player)    -- final save and release
end)

game:BindToClose(function()
	Ledger.CloseAll()       -- flush and release every store, called once
end)
```

`Load` and `Unload` are per-store. `Ledger.CloseAll` is a module function, not a store
method: it flushes every store you built, so you call it once no matter how many stores you
have.

A failed load kicks the player. That is deliberate: better to make them rejoin than to
serve stale or empty data over their real save.

## Make changes

```luau
local Session = Store:Expect(Player)

if Session:Apply("SpendGold", { Amount = 25 }) then
	-- accepted, State already reflects it
else
	-- the reducer said no (not enough gold)
end
```

`Apply` is a local function call, not a datastore trip. It runs your reducer against the
live state, mutates optimistically on yes, and queues the op for the next autosave. For
side effects that must never fire twice (badges, product grants), use `Commit` instead,
which is durable before it answers. [Sessions](sessions.md) covers the difference.

## Read state

```luau
local State = Store:Read(Player)             -- the current table, or nil if not loaded
local Session = Store:WaitForLoaded(Player)  -- yields until loaded, nil if they left

Session:Observe():Subscribe(function(State)
	-- fires on every change
end)
```

Treat what you read as read-only. Never mutate state you did not clone; Ledger deep-freezes
session state everywhere, so a mutation throws at the line that did it instead of quietly
corrupting the shared table.

## Migrating from 1.x

The 2.0 break is one call. `Ledger:Configure(Options)` became `Ledger.New(Options)`, which
returns a store instead of mutating a singleton, so the lifecycle and cross-server calls move
from the module to that store:

```luau
-- 1.x
Ledger:Configure({ Name = "PlayerData", Default = Default, Reducer = Reducer })
Ledger:Load(Player)
Ledger:Expect(Player):Apply("SpendGold", { Amount = 25 })
game:BindToClose(function() Ledger:CloseAll() end)

-- 2.0
local Store = Ledger.New({ Name = "PlayerData", Default = Default, Reducer = Reducer })
Store:Load(Player)
Store:Expect(Player):Apply("SpendGold", { Amount = 25 })
game:BindToClose(function() Ledger.CloseAll() end)
```

Everything else is the same. The options table, the reducer contract, the op log format and
the datastore keys are all unchanged, so existing saves load untouched. `CloseAll` is the one
call that stays on the module, since it closes every store at once. Names are now capped at 47
characters instead of 50, because the transaction store appends `_Tx`; if you had a name in
the 48 to 50 range, shorten it.

## Where to next

- [The model](the-model.md) for how ops and the fold actually work, and the reducer rules
- [Sessions](sessions.md) for the full per-player API
- [Cross-server](cross-server.md) for writing to players who are offline or elsewhere, and
  entity stores
