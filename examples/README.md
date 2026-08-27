# Examples

The Ledger-shaped part of common features, and nothing else. They assume the store was built,
the player is loaded, and every problem that is not Ledger's has already been solved. None of
them run as written.

They are type-checked against `src`, so they cannot quietly drift out of date.

| file | shows |
| --- | --- |
| [Shop](Shop.luau) | `Apply`, and why a purchase is one op |
| [Purchases](Purchases.luau) | `ProcessReceipt` with `Once`, and answering from `DidApply` |
| [Trading](Trading.luau) | `Tx` between two players, named so a retry is safe |
| [Economy](Economy.luau) | `Transfer` with a dedupe key, `Edit` and `Once` for offline players, `Peek` |
| [Clans](Clans.luau) | an entity store, and a transaction across two stores |
| [Effects](Effects.luau) | getting time into a pure reducer, and rendering gameplay from state |
| [Typed](Typed.luau) | naming your ops, so a write is checked and the reducer needs no casts |

## Start here

Most games need `Shop` and `Effects`. That is `New`, `Load`, `Apply`, `Commit`, `Read` and
`Observe`, and it is a complete game.

`Transfer`, `Tx` and entity stores are opt-in. If you never move value between two keys, you
never touch the escrow, the transaction marker, or any of their horizons. Nothing in
`Economy`, `Trading` or `Clans` is machinery you are carrying until you ask for it.

## Reading fields in a reducer

An op is `{ Id, Kind, ...whatever you passed }`, so on an untyped store the checker cannot know its
fields. Read them into a typed local at the top of the branch:

```luau
local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	if Op.Kind == "Buy" then
		local Item = Op.Item :: string
		...
```

That puts the annotation and the validation in one place, and everything below it is checked
normally. Every example here except `Typed` does this.

Name your ops instead and the cast goes away. `Op.Kind == "Buy"` narrows to that kind, so `Op.Item`
is a string on its own and reading a field off the wrong kind is an error where you read it. See
[Typed](Typed.luau).
