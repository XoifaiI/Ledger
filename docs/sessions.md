# Sessions

One live session per loaded player, on the server that loaded them. It folds on `Load`, applies
changes in memory, and saves every 30 seconds plus a final save on `Unload` and `CloseAll`.

Entity stores have no sessions. See [cross-server](cross-server.md).

## Apply vs Commit

The one distinction that matters day to day.

```luau
-- gameplay: instant, local, saved on the next autosave
if Session:Apply("SpendGold", { Amount = 25 }) then
	Shop:GiveItem(Player, "Potion")
end

-- side effects that must not fire twice: durable before it answers
if Session:Commit("BuyGamepassReward"):Wait() then
	BadgeService:AwardBadge(Player.UserId, BadgeId)
end
```

| | `Apply` | `Commit` |
| --- | --- | --- |
| cost | a function call | one datastore round trip |
| answers | same frame | when durable |
| returns | `boolean` | `Future<boolean>` |
| use for | combat, shops, anything ordinary | badges, product grants, one time things |

`Commit` answers whether **your** op was the accepted one. Two servers commit the same one time
grant, exactly one gets `true`.

## Observing

```luau
Session:Observe():Subscribe(function(State)
	Gui.Gold.Text = State.Gold
end)
```

It fires on every change **after** you subscribe, never on subscribe itself. Paint first:

```luau
local function Paint(State)
	Gui.Gold.Text = State.Gold
end

Paint(Session:Get())
Session:Observe():Subscribe(Paint)
```

Listeners run inline and must not yield. `task.spawn` if you need to.

Watching one field, since a session notifies on every accepted op:

```luau
Session:Observe()
	:Map(function(State) return State.Gold end)
	:Changed()
	:Subscribe(function(Gold)
		Gui.Gold.Text = Gold
	end)
```

`Changed` compares with `==`, so it only earns its keep after a `Map`. Pass your own comparator
for anything else.

## When Apply can be overturned

`Apply` answers from this server's state. The durable answer comes at the next flush, and a
**foreign** write landing in that window can disagree:

```
server A   Apply("BuySword", { Cost = 100 })   100 gold, accepted, returns true
server B   Edit(UserId, "SpendGold", 100)      lands first
A flushes  log reads [ SpendGold, BuySword ]
every fold SpendGold accepted -> 0 gold, BuySword refused
```

The stored data is correct and identical everywhere, but you already handed over a sword. Two
`Apply` calls in one session cannot race each other; this needs an `Edit`, a transfer delivery,
a transaction leg, or a `Reset`.

Two habits make it a non event. **One op, never two**, so a refusal takes the whole purchase
with it. And **derive effects from state**, so a corrected fold undoes them for you:

```luau
-- wrong: the buff outlives the op that paid for it, so you write revocation code
if Session:Apply("BuyBoost", { Cost = 100, Until = os.time() + 600 }) then
	Humanoid.WalkSpeed = 32
end

-- right: the buff is a view of state
Session:Observe():Subscribe(function(State)
	Humanoid.WalkSpeed = if (State.BoostUntil or 0) > os.time() then 32 else 16
end)
```

Worst case with both habits: a player walked fast, for free, until the next flush. For anything
that cannot be briefly free, use `Commit` and there is no window at all.

## What a false means

```luau
local Ok, Why = Session:Apply("SpendGold", { Amount = 25 })
if Ok then
	-- accepted
elseif Why == "Refused" then
	Gui:Error("not enough gold")
else
	Telemetry:Alert(Why)  -- everything else is your problem, not the player's
end
```

| Reason | Means | What to do |
| --- | --- | --- |
| `Refused` | your reducer said no | the normal answer, tell the player |
| `Closed` | the player left | drop it |
| `Backlog` | saves are not landing | **outage signal**, alert |
| `Full` | the profile is at the 2MB cap | a data design problem, alert |
| `Invalid` | a NaN or an Instance in `Fields` | a bug, alert |
| `Unresolved` | `Commit` only: durable, but the verdict is not settled | re-read; to re-issue use `CommitOp` with the same id |

`if Session:Apply(...) then` still works; the reason is there when you want it.

`Flush`, `Compact` and `Release` answer with a plain boolean. `Release` returning `false` is the
one that costs you: those ops die with this server. The datastore wrapper retries the write
itself, and `CloseAll` lowers it to two quick attempts so shutdown fits inside the time Roblox
gives it.

Two things worth knowing about `Commit`. A local refusal does not stop it, because a foreign
write may have landed in between, so the fold over the stored log decides. And a reducer that
throws or yields raises at the call site rather than returning a reason, before anything is
appended.

## Crashes

A soft shutdown loses nothing. A hard crash loses at most 30 seconds of `Apply` traffic, and
nothing that went through `Commit`. There is no lock, so a rejoin after a crash loads
immediately.

During an outage `Apply` starts returning `Backlog` rather than eating memory and pretending
progress is being saved.
