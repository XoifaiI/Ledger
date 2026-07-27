# The model

Nothing stores your state table. What is stored is a snapshot plus the changes since:

```
State = fold(Snapshot, Ops)
```

An op is one change with a name:

```luau
{ Id = "a3f1...", Kind = "SpendGold", Amount = 25 }
```

Your reducer replays them in order, returning the next state or `nil` to refuse:

```luau
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
```

That runs at fold time, on whatever server folds the log, so an invalid change is not
prevented, it is unreachable. Two servers spend the same 100 gold, both ops land, every fold
everywhere accepts the first and refuses the second.

## Rules

**Return the whole state, cloned.**

```luau
return { Gold = State.Gold - Op.Amount }  -- wrong, drops every other field
State.Gold -= Op.Amount; return State     -- wrong, corrupts the shared snapshot

local Next = table.clone(State)           -- right
Next.Gold -= Op.Amount
return Next
```

Nested tables too:

```luau
local Next = table.clone(State)
Next.Items = table.clone(State.Items)
Next.Items[Op.Item] = true
return Next
```

State is deep frozen, so getting this wrong throws at the line that did it.

**Be pure.** No `os.time`, no `math.random`, nothing outside the two arguments. Capture at the
call site:

```luau
-- wrong
if os.time() - State.LastClaim < 86400 then return nil end

-- right
Session:Apply("ClaimDaily", { Timestamp = os.time() })
```

In Studio, Ledger catches this for you and names the field that moved.

**Never yield.** A throw or a yield refuses that op, so one bad op cannot break a record.
`Apply` is the exception and raises at the call site, because that is a bug in your state
machine.

**One op per meaningful change.** A change that must be all or nothing is one op:

```luau
-- wrong, the gold can refuse while the sword applies
Session:Apply("SpendGold", { Amount = 100 })
Session:Apply("GrantSword")

-- right
Session:Apply("BuySword", { Cost = 100 })
```

```luau
if Op.Kind == "BuySword" then
	if Op.Cost > State.Gold or State.Items.Sword then
		return nil
	end
	local Next = table.clone(State)
	Next.Gold -= Op.Cost
	Next.Items = table.clone(State.Items)
	Next.Items.Sword = true
	return Next
end
```

Across two keys, that is a [transaction](transactions.md).

**Record the effect, not the derivation.**

```luau
Session:Apply("QuestReward", { Gold = 250 })         -- replays identically forever
Session:Apply("QuestReward", { Quest = "SlimeHunt" }) -- changes meaning when you rebalance
```

## Reserved names

```luau
State._Held, State._Received  -- Ledger's transfer bookkeeping
Op.Kind = "__Anything"        -- refused, __ is Ledger's prefix
Op.Tx, Op.TxHome              -- refused, the transaction path owns these
Op.Id, Op.Kind                -- overwritten with a warning if you pass them
```

A `_` prefixed key in your `Default` is refused at build time.

## Typing a reducer

An op is `{ Id, Kind, ...whatever you passed }`, so the checker cannot know its fields. Read
them into a typed local at the top of the branch:

```luau
local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	if Op.Kind == "Buy" then
		local Item = Op.Item :: string
```
