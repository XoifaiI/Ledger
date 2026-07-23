# Recovery

Because state is derived from a log, Ledger can always show you what happened and fold a
record back to what it looked like before. That covers the usual cases: a bad reducer that
ran for a while, a player disputing a loss, or a support request that needs the real history.

## Version history

Roblox keeps 30 days of versions for every datastore key. Ledger exposes that as a
recovery surface:

```luau
local Rows = Store:History(UserId, 25):Wait()
-- { { Version = "...", At = 1760000000, Deleted = false }, ... } newest first

local OldState = Store:PeekVersion(UserId, Rows[3].Version):Wait()
```

`PeekVersion` reads the historical record and folds it through your reducer and
migrations into readable state, so support tooling sees a profile, not a raw envelope.
From there, the honest repair path is compensation: compare old and current, then `Edit`
the difference back. Note that rapid writes to one key coalesce into a single stored
version, so history has per-write-window granularity; live saves 30 seconds apart each
get their own version.

## Reset

```luau
Store:Reset(UserId)
```

Moderation tool. Resets an account to the `Default` by appending a reset op, never by
deleting, so the exploit and the correction both stay in the log as the audit trail. It works
on a player online anywhere; their session folds it on its next flush. The transfer
bookkeeping survives the reset on purpose, so a reset that lands mid-transfer cannot lose a
held amount or re-credit a delivery.

## Erase

```luau
Store:Erase(UserId)
```

Right-to-erasure compliance. Hard-deletes the record, the one path around the append-only
log. This is not the moderation tool: ban or kick the player everywhere first, because a
live session elsewhere will push its pending ops and partially resurrect the record.

## What crashes cost, and what they cannot touch

- A soft shutdown flushes everyone through `CloseAll`. Nothing lost.
- A hard crash loses at most the 30 second autosave window of `Apply` traffic. Anything
  through `Commit` was durable first.
- A crashed transfer finishes itself from the sender's held state on their next load, or via
  `RecoverTransfers(UserId)`: a recent hold re-drives to the receiver, an old one settles if
  the delivery landed or refunds the sender if it did not. Delivery ids are kept for thirty
  days, so a hold recovered later than that is settled rather than refunded, because the record
  may have pruned the id and a wrong refund would mint; it warns for compensation.
- A crashed transaction resolves within about a minute, aborted or completed by whichever
  server touches it next. See [transactions](transactions.md).
- A record written by a newer format refuses to load on older servers rather than being
  misread, both at the data version level ([migrations](migrations.md)) and at the record
  envelope level, so recovery never has to untangle a half-downgraded save.
