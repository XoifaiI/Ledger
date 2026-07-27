# Recovery

State is derived from a log, so Ledger can always show what happened and fold a record back to
what it looked like before.

## Version history

Roblox keeps 30 days of versions for every key:

```luau
local Rows = Store:History(UserId, 25):Wait()
-- { { Version = "...", At = 1760000000, Deleted = false }, ... } newest first

local Old = Store:PeekVersion(UserId, Rows[3].Version):Wait()
print(Old.Gold)
```

`PeekVersion` folds it through your reducer and migrations, so support tooling sees a profile,
not a raw envelope.

The repair path is compensation, not rollback. Compare, then `Edit` the difference back:

```luau
local Old = Store:PeekVersion(UserId, Version):Wait()
local Now = Store:Peek(UserId):Wait()

Store:Edit(UserId, "SupportGrant", { Amount = Old.Gold - Now.Gold })
```

Rapid writes coalesce into one stored version, so history has per write window granularity.

## Reset

```luau
Store:Reset(UserId)
```

The moderation tool. Appends a reset op rather than deleting, so the exploit and the correction
both stay in the log. Works on a player online anywhere. Transfer bookkeeping survives it on
purpose, so a reset mid transfer cannot lose a held amount or re-credit a delivery.

It answers `Refused` when the record was written by a server that knows more migrations than
this one, since folding it back to this `Default` would drop the newer shape.

## Erase

```luau
Store:Erase(UserId)
```

Right to erasure compliance, and the one path around the append only log. Not the moderation
tool: ban or kick the player everywhere first, because a live session elsewhere will push its
pending ops and write part of the record back.

## What crashes cost

| Event | Cost |
| --- | --- |
| soft shutdown | nothing, `CloseAll` flushes everyone |
| hard crash | at most 30 seconds of `Apply` traffic |
| anything through `Commit` | nothing, it was durable first |
| crashed transfer | self resolving, see [cross-server](cross-server.md) |
| crashed transaction | resolves in about a minute, see [transactions](transactions.md) |

A record written by a newer format refuses to load on an older server rather than being misread.

## Operator tools

```luau
Store:RecoverTransfers(Key):Wait()  -- finish a key's stranded transfers now
Store:ClearDelivered(Key):Wait()    -- drop every applied id, a last resort
```

`RecoverTransfers` is safe any time. It only finishes what a crash left open, and running it
twice does nothing the first run did not.

`ClearDelivered` is not safe. It wipes the set a key uses to refuse work it has already done,
which holds both the transfers delivered to it and the named transactions applied to it, so
clearing it re-arms a retry of either. Clearing one key of a multi key transaction leaves that
set inconsistent, which a later retry refuses outright rather than applying to part of it.

Reach for it when a key's applied set is genuinely wrong, not as routine cleanup. It prunes
itself at thirty days.
