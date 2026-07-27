# Getting started

## Install

**Wally**

```toml
[server-dependencies]
Ledger = "xoifaii/ledger@3.0.0"
```

**Rojo**: drop the `src` folder into your project as `ServerStorage/Ledger`.

**Model file**: insert the module anywhere server side.

Ledger is server only. It never replicates and has no client half.

## The whole thing

```luau
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

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
			return nil
		end
		local Next = table.clone(State)
		Next.Gold -= Op.Amount
		return Next
	end
	return nil
end

local Store = Ledger.New({
	Name = "PlayerData",
	Default = Default,
	Reducer = Reducer,
})

local function OnPlayer(Player)
	Store:Load(Player)
end

Players.PlayerAdded:Connect(OnPlayer)
for _, Player in Players:GetPlayers() do
	task.spawn(OnPlayer, Player)
end

Players.PlayerRemoving:Connect(function(Player)
	Store:Unload(Player)
end)

game:BindToClose(function()
	Ledger.CloseAll()
end)
```

That is a complete, production shaped setup. There is no save call and no lock to wait out. A
failed load kicks the player on purpose: better a rejoin than serving empty data over a real
save.

## Changing data

```luau
local Session = Store:Expect(Player)

if Session:Apply("SpendGold", { Amount = 25 }) then
	-- accepted, Session:Get().Gold is already lower
else
	-- the reducer said no
end
```

`Apply` is a function call, not a datastore trip. It answers the same frame and is saved on the next
autosave.

For anything that must not fire twice, `Commit` is durable before it answers:

```luau
if Session:Commit("ClaimDaily", { Timestamp = os.time() }):Wait() then
	MarketplaceService:PromptPurchase(...)
end
```

[Sessions](sessions.md) covers the difference properly.

## Reading data

```luau
local State = Store:Read(Player)             -- nil if not loaded
local Session = Store:WaitForLoaded(Player)  -- yields, nil if they leave first

State.Gold = 999                             -- error, state is deep frozen
```

To watch it change:

```luau
Session:Observe():Subscribe(function(State)
	Gui.Gold.Text = State.Gold
end)
```

`Observe` fires on every later change, not on subscribe. Read `Session:Get()` first to paint
immediately.

## Coming from a normal datastore

| What you did before | What you do here |
| --- | --- |
| `GetAsync` for display | `Store:Peek(Key):Wait()` |
| read the loaded profile | `Store:Read(Player)` |
| write a field | `Session:Apply("SpendGold", { Amount = 25 })` |
| write, then grant a badge | `Session:Commit("BuyBadge"):Wait()` |
| write to an offline player | `Store:Edit(UserId, "AddGold", { Amount = 500 })` |
| session lock | nothing, the reducer arbitrates |
| your own autosave loop | built in, every 30 seconds |
| `:UpdateAsync` retry wrapper | built in |

You never write state. You name the change, and a function you write decides whether it is
legal:

```luau
local Data = Store:GetAsync(Key)     -- before
Data.Gold -= 25
Store:SetAsync(Key, Data)

Session:Apply("SpendGold", { Amount = 25 })  -- here
```

Two servers spending the same 100 gold both write. The reducer accepts the first and refuses the
second, everywhere, without a lock. That is the whole trick, and [the model](the-model.md)
covers the rules for writing one.

## Options

```luau
Ledger.New({
	Name = "PlayerData",   -- datastore name, 1 to 47 characters
	Default = Default,     -- a fresh record's state
	Reducer = Reducer,     -- (State, Op) -> State?

	Balance = "Gold",      -- optional, the numeric field Transfer moves
	Migrations = { ... },  -- optional, ordered shape changes
	Keys = "String",       -- optional, "Player" (default) or "String"
})
```

A missing reducer, an unstorable `Default`, a `_` prefixed key, a malformed migration, an
over long name: every one throws when you build the store, not at the first player.

## Coming from 1.x

`Ledger:Configure` became `Ledger.New`, which returns a store instead of mutating a singleton.
Stored data is untouched, so existing saves load as they are.

```luau
Ledger:Configure({ Name = "PlayerData", ... })  -- 1.x
Ledger:Load(Player)

local Store = Ledger.New({ Name = "PlayerData", ... })  -- now
Store:Load(Player)
```

## Next

- [The model](the-model.md), how to write a reducer
- [Sessions](sessions.md), Apply vs Commit
- [Cross-server](cross-server.md), offline players and entity stores
- [API reference](api.md), every method
