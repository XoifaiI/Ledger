# Transactions

Changes across two to four keys that must all happen or none happen. No locks, no same server
requirement, nobody has to be online.

```luau
local Committed, Why = Store:Tx(`trade:{TradeId}`, {
	{ UserId = 123, Kind = "Delta", Fields = { Gold = 25,  Drop = "Sword" } },
	{ UserId = 456, Kind = "Delta", Fields = { Gold = -25, Gain = "Sword" } },
}):Wait()

if Committed then
	Gui:Confirm()
elseif Why == "Refused" then
	Gui:Error("that trade is no longer valid")
elseif Why == "Busy" then
	Gui:Retry("one of you is already trading")
else
	Gui:Pending("checking, this may have gone through")
end
```

The name comes first and is required. It is what makes the call safe to repeat. Derive it from
the thing being settled, never from the clock.

Each leg is an ordinary op kind your reducer already handles:

```luau
if Op.Kind == "Delta" then
	local Gold = State.Gold + (Op.Gold or 0)
	if Gold < 0 then
		return nil
	end
	local Items = table.clone(State.Items)
	if Op.Drop then
		if not Items[Op.Drop] then return nil end
		Items[Op.Drop] = nil
	end
	if Op.Gain then
		if Items[Op.Gain] then return nil end
		Items[Op.Gain] = true
	end
	return { Gold = Gold, Items = Items }
end
```

Ledger decides whether the whole set happens. Your reducer decides whether each leg is legal.

## Across two stores

```luau
PlayerData:Tx(`deposit:{DepositId}`, {
	{ UserId = Jack, Kind = "SpendGold", Fields = { Amount = 100 } },
	{ Store = Clans, Key = "sunreavers", Kind = "Deposit", Fields = { Amount = 100 } },
}):Wait()
```

`UserId` for a player store leg, `Key` for an entity store leg. The store you call `Tx` on
coordinates. A transaction may only touch a key once per store.

## What the answer means

`true` means the set committed, covering both "just now" and "on an earlier call and this one
moved nothing". `false` always arrives with one of four reasons:

| Reason | What happened | What to do |
| --- | --- | --- |
| `Refused` | a leg's reducer said no | permanent, tell the player |
| `Busy` | another transaction holds one of the keys, nothing applied | offer it again in a moment |
| `Spent` | this name cannot be used again | use a new one |
| `Unresolved` | the datastore never answered | it may still commit, re-read the keys |

`Refused` and `Busy` are the two you will actually see.

**Everything mechanical is retried internally.** A lost acknowledgement, a stale marker, a
transient write failure and a torn verdict never reach you, because `Tx` runs its own pass again
under the same name. That is why the name is required.

**Misuse throws.** A leg count outside two to four, a key that does not resolve, a missing
`Kind`, unstorable `Fields`, a `Store` Ledger did not build, the same key twice, a missing or
oversized `Id`. Bugs in the code, not outcomes of the protocol.

## The rules

One pending transaction per key. A second answers `Busy` having applied nothing, so retry under
the same name rather than waiting it out:

```luau
local Ok, Why = Store:Tx(Name, Legs):Wait()
if Why == "Busy" then
	task.wait(1)
	Ok = Store:Tx(Name, Legs):Wait()  -- same name, so this is the same transaction
end
```

Sessions keep working while a leg is pending. `Apply` is unaffected:

```luau
Session:Apply("SpendGold", { Amount = 10 })  -- true, even mid transaction
```

`Commit` and compaction both wait the leg out instead of answering while the ground might shift.
One round trip normally, about a minute behind a crashed coordinator:

```luau
Session:Commit("ClaimDaily"):Wait()  -- waits for the leg, then answers
```

Legs validate against prepare time state, so ops appended later fold after the leg:

```luau
Store:Tx(Name, Legs)                          -- leg prepared, 100 gold at this point
Store:Edit(Key, "SpendGold", { Amount = 100 }) -- folds after it, may now be refused
```

If the leg is still undecided when the edit answers, an edit the leg's outcome could overturn
answers `Unresolved` rather than guessing; one it cannot affect answers normally.

## Crashes

A crashed coordinator cannot wedge a key. Any server that runs into a pending leg resolves it
from the marker, and one still pending after 60 seconds is aborted.

A pending leg resolves when a session loads or flushes that key, when an `Edit` writes to it, or
when another transaction arrives. On a player key that is their next login. An entity key has no
session, so Ledger records any key it finds one on and retries every minute:

```luau
Ledger.Sweep()  -- force that pass now instead of waiting
```

You never need to call it, and it needs no list of your keys, because it only revisits keys
Ledger has already watched go pending.

## Retry safety

A name is safe to retry whatever the first attempt did. A committed set answers `true` again
without moving anything; an aborted one left nothing behind. Reusing a name for a *different*
set of keys is refused outright.

Each key records the names it has applied, kept for thirty days, surviving compaction. Past that
horizon a retry prepares the set again: value is conserved because both legs re-run together and
your reducer still validates each, but it is not the outcome you asked for. Same horizon a
transfer has.

## When not to use it

For one number between two keys use [`Transfer`](cross-server.md), which is cheaper and does not
hold keys. For one key, a single op is already atomic:

```luau
-- wrong, and this throws: a transaction may only touch a key once
Store:Tx("buy", {
	{ UserId = Player.UserId, Kind = "SpendGold", Fields = { Amount = 100 } },
	{ UserId = Player.UserId, Kind = "GrantSword" },
})

-- right
Session:Apply("BuySword", { Cost = 100 })
```
