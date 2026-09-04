# When the ask will hurt them

Say the concern **once**, in a sentence or two, then do the work they asked for. If they say it again,
that is their call about their own game: do it and say what you did. Do not repeat the warning, do
not moralise, and do not refuse ordinary work because it touches something risky.

Every entry below has a case where it is the right thing to do. Read the context before answering.
The point is to catch the common mistake, not to have an opinion about every call.

## Throwing data away

**"Erase this player to reset them."** `Erase` buries the key for 8 days, turns away anything sent to
it, closes a live session on its next save, and can destroy money the key was part way through
sending. `Reset` is what puts a profile back to `Default`, and it keeps `_Received` and `_Held` so a
delivery cannot pay twice and money in flight is not stranded.
*Right when:* the ask is a deletion request. `Erase` is the button for that, and check the answer,
because `false` means the record is still there and the job is not done.

**"Wipe every key and start fresh."** That is a bulk destructive loop. Print the list and the count
first, get the count named back, and cap the pass.
*Right when:* it is a test store or a mock. Say which one it is before running it.

**"Just edit it in the datastore editor."** A plugin shows Ledger's record, not the player's data.
Replacing it with a plain state table reads as a brand new profile, editing `Snapshot` while `Ops`
has anything in it gets overwritten by the replay, and clearing `_Held` or `_Received` destroys money
or lets a delivery pay twice. `Edit`, `Reset` and `Inspect` do the same job through the log.
*Right when:* nothing. Read `guides/recovery#editing-storage-directly` with them.

## Retries and ids

**"Retry until it goes through."** On `Refused`, the reducer said no and the answer will not change,
so this is a loop and a wall of warnings. Read the state and tell the player why.
*Right when:* the reason is `Busy` or `Unresolved`, with a backoff, under the same id.

**"Retry it with a new id."** After `Unresolved` this is how a game pays twice. The id is the thing
that makes a retry land once. Read the key back, or ask `DidApply`, under the id that was used.
*Right when:* the reason is `Spent`, which means that name is finished and a new one is the only way
forward. Decide what the new one means first.

**"Generate the id at the call site."** A GUID made inside the call is a different transfer every
attempt, so a retry moves the money again. Make it when the trade or the order opens and keep it
where the retry can read it.
*Right when:* the transfer genuinely is a fresh one each time, which is the default for a trade with
no retry path.

**"Use the reservation name as the receipt."** A hold is a live handle, not a receipt. Once the key
compacts a repeat `Confirm` answers `Unresolved`, and a confirmed, released and expired hold all
leave the same absence. Put a `Once` on the grant and ask `DidApply`.
*Right when:* the thing being retried is the hold itself. Reserving again under a held name is safe
and holds nothing extra.

**"Answer PurchaseGranted, the Commit said true."** The first call did change something and every
replay after it does not, so the boolean cannot tell a replay from a refusal. `DidApply` answers the
question Roblox is asking.
*Right when:* never, on a receipt. Check `Unresolved` first, then `DidApply`.

## The reducer

**"Read `os.time()` in the reducer."** Two servers fold the same log at two different moments and
disagree. Put the time on the op. The same goes for `math.random`, an upvalue that moves and anything
outside the two arguments.
*Right when:* never. Studio names the field that moved, and the check does not run live.

**"`State.Gold += 1` in the reducer."** Live state is deep frozen, so it throws on the line that did
it. Clone the table being changed, and each nested table on the way down.
*Right when:* never, and the throw is the feature.

**"Return `State` for a kind we do not handle."** Ledger reads any table as accepted. That marks a
`Once` name as applied while nothing was granted, and commits a transaction leg on a key that did
nothing. Return `nil`.
*Right when:* never. This one is the Redux habit and it costs money rather than throwing.

**"Delete the branch, nothing writes that kind any more."** Any live key still carrying one of those
ops stops compacting for good, the log grows, and writes answer `Full`. Keep the branch, and keep it
correct through later migrations.
*Right when:* no stored key can still hold one, which in practice means never for a shipped kind.

**"Migrate by returning the new shape."** A migration that rebuilds the state drops everything it did
not mention, including Ledger's own fields. Ledger puts those back and names the step, but the game's
own fields are gone. Copy the state and change what the step is for.
*Right when:* the step really is meant to drop everything, which is a reset rather than a migration.

## Cost and shape

**"Commit on every click."** That is one datastore request per click and it will run the server out of
budget. `Apply` folds against live state, answers at once, and rides out on the autosave, so the op
rate is free.
*Right when:* the write is about to be acted on outside the game, so a purchase, a webhook, a grant.
Apply for gameplay, Commit for side effects.

**"Poll `Total` every second."** With `MaxAge` at zero that is twelve times the request units for the
same answer, on a key that is already the hottest thing in the experience.
*Right when:* a short event where a visibly live number is the feature, and they have counted the
units against `1000 + 120 per CCU` a minute.

**"Put the whole economy on one key."** A key takes one transaction at a time and every other one
answers `Busy`. Contention costs throughput, never correctness, but the throughput goes fast: 32
servers on one key measured about 8 attempts each.
*Right when:* the limit genuinely is a property of one thing, like one item's stock. Then it belongs
on one key and `Reserve` holds it.

**"Use `Tx` for the shop."** A transaction is the most expensive thing Ledger does. Selling stock is
one key, so it is a reservation and a confirm, measured at 201 requests against 800 for the
transaction version of the same 100 purchases.
*Right when:* two different changes must happen together and one of them cannot be undone. Trading a
sword for a shield is a real transaction.

**"Keep the whole history in the profile."** State caps at 2 MB and every compaction rewrites all of
it. Bound the array, or move it to its own key.
*Right when:* it is genuinely small and bounded. Say what bounds it.

**"Key it by username."** A rename orphans the data. Use the UserId.
*Right when:* the key is not a player, which is what string keyed stores are for.

## Answers and failure

**"Fire and forget the Edit."** The reason was the answer and it is gone. Wait the Future, or handle
the reason.
*Right when:* the write is genuinely advisory and its failure is visible some other way. Say which.

**"Wrap it in a pcall and carry on."** Misuse throws where the call was written, and that throw is a
bug in the call rather than a runtime condition. Fix the call.
*Right when:* the throw is expected and handled, like `UserOwnsGamePassAsync` failing. Never collapse
that one to `false`, which takes a pass away from somebody who paid for it.

**"Turn off the warnings."** They are the interface. A warning holding `Ledger bug:` is a request to
report it.
*Right when:* never. If they are noisy, that is a finding.

**"Fall back to a fresh profile when the load fails."** On `Behind` the record is fine and this server
is the problem, so writing a fresh profile over it destroys real data. `OnLoadFailed` is where that
decision belongs, and a `Behind` wants a teleport rather than a kick.
*Right when:* never for `Behind`. For other reasons, kicking is already what Ledger does.
