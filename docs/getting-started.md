# Getting started

## Install

**Rojo**: clone the repo and add it to your project, or drop the `src` folder in as
`ServerStorage/Ledger` (the folder becomes the module, `init.luau` is its root).

**Wally**:

```toml
[server-dependencies]
Ledger = "xoifaii/ledger@1.1.0"
```

**Model file**: insert the `Ledger` module anywhere server-side. `ServerStorage` is the
natural home. Everything below assumes `ServerStorage.Ledger`.

Ledger is server-only. It never replicates and has no client half.

## Configure once, before anyone joins

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

Ledger:Configure({
	Name = "PlayerData",   -- the datastore name
	Default = Default,     -- a fresh player's starting data
	Reducer = Reducer,     -- decides whether each change is legal
})
```

`Configure` validates everything up front. A missing name or reducer, an unstorable value
or a `_` prefixed key in the Default, or a malformed migration step all throw immediately,
at boot, instead of surfacing at the first player.

Two optional fields join these later: `Balance` names the numeric field that
[`Transfer`](cross-server.md) moves, and `Migrations` handles
[shape changes](migrations.md).

If those three fields feel small, that is the point. The `Reducer` is where your game's
rules live, and [the model](the-model.md) explains how to write a good one.

## Wire the lifecycle

Ledger is passive. Your boot script owns when players load and leave:

```luau
local function OnPlayer(Player)
	Ledger:Load(Player)     -- folds the log into a live session, starts autosave
end

Players.PlayerAdded:Connect(OnPlayer)
for _, Player in Players:GetPlayers() do
	task.spawn(OnPlayer, Player) -- anyone who joined before this script ran
end

Players.PlayerRemoving:Connect(function(Player)
	Ledger:Unload(Player)   -- final save and release
end)

game:BindToClose(function()
	Ledger:CloseAll()       -- flush and release everyone
end)
```

A failed load kicks the player. That is deliberate: better to make them rejoin than to
serve stale or empty data over their real save.

## Make changes

```luau
local Session = Ledger:Expect(Player)

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
local State = Ledger:Read(Player)          -- the current table, or nil if not loaded
local Session = Ledger:WaitForLoaded(Player) -- yields until loaded, nil if they left

Session:Observe():Subscribe(function(State)
	-- fires on every change
end)
```

Treat what you read as read-only. Never mutate state you did not clone; in Studio, Ledger
deep-freezes session state so a mutation throws in development where it is loud instead of
corrupting shared state in production where it is silent.

## Where to next

- [The model](the-model.md) for how ops and the fold actually work, and the reducer rules
- [Sessions](sessions.md) for the full per-player API
- [Cross-server](cross-server.md) for writing to players who are offline or elsewhere
