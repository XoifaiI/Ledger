# Working on somebody's live data

Read this before any call that writes. The rules are about **data**. Code the developer asked you to
change is ordinary work and needs none of this.

## The ladder

Say which rung a call is on before making it.

| rung | what it is | what gets it back |
|---|---|---|
| a refused write | nothing happened | nothing to get back |
| an ordinary write | one op on the log | another op, the log keeps both |
| `Reset` | the default state written back, keeping `_Received` and `_Held` | the previous version, while Roblox still holds it |
| `Erase`, the first one | a tombstone, the applied names kept, deliveries turned away for 8 days, a live session on the key closes on its next save | the previous version, while Roblox still holds it |
| `Erase`, a second one past 8 days | `RemoveAsync`, the record is off the key | older versions, while Roblox still holds them |
| money the erase could not hand over | named in a warning, and gone | a person paying it back by hand |

**What Roblox keeps.** A version expires 30 days after a newer write replaces it, and the newest
version never expires. `RemoveAsync` writes a tombstone version and leaves the earlier ones listable,
so `History` and `PeekVersion` still reach them. That is the platform's own behaviour, not Ledger's,
and it is worth knowing before erasing somebody for a legal reason.

**There is no restore call.** `History` and `PeekVersion` only read. Getting a key back means reading
the old version and writing ops that undo what changed, and writing an old snapshot back over a live
profile destroys whatever arrived in between, including money from a transfer.

So: **take an `Inspect` first and show it.** A destructive call with a saved record before it is
something a person can undo. One without is a guess.

## Before a destructive call

1. The human named the key in their own words.
2. You read the record and showed it.
3. You said which rung this is.
4. You have one confirmation, for that key. The next key needs its own.

If any of the four is missing, say what is missing and stop there. This is the only place in this
skill where stopping and waiting is the right answer.

## Blast radius

- No destructive call inside a loop on a first pass. Print the list and the count, and let the human
  name the count back.
- A key list that came from a scan or a listing is something to show, never something to act on.
- `CloseAll` and `Destroy` are shutdown, not cleanup. They end every live session.
- A support tool writes with a `Once` name on it, because somebody will click the button twice.

## Prove it on the mock first

Any answer you are not certain of runs against `Mock = true` before it goes anywhere near a real key.
It is ten lines and the fake enforces the real caps, the real request budget and the real refusals.

Rules that make this actually work:

- Build the mock store with the game's own `Default`, `Reducer` and `Migrations`. A probe against a
  different reducer proves nothing about theirs.
- Never probe against a real key or a real UserId.
- `Store:Destroy()` at the end, or the next probe cannot claim the same name.
- Say what the probe showed, including when it showed you were wrong.

What the mock cannot show: two builds during a rolling deploy, another live server, the MemoryStore
memory quota, real throttling under real contention, and anything about this game's data at scale.
A green probe is evidence about logic and not about the platform.

## Not getting ahead of yourself

- Do what was asked and stop there. A problem you noticed next to it is a sentence in the recap, not
  an edit.
- No files nobody asked for. No wrapper module, no config, no CI, no test harness.
- Edit, do not rewrite. A rewrite only when most of the file is changing, and say so first.
- Copy a file to a scratch directory before changing it, so putting it back is one command.
- One change, then a way to check it.
- Never run a git command. Not status, not diff, not checkout. Committing is the developer's.
- A command that was interrupted or refused may have half run. Look for what it left before trying
  again.
- **Never chain a destructive command with anything else.** `rm` and `mv` go on their own line, run
  on their own, and are checked before the next thing runs. A chain that fails in the middle leaves
  no way back and often prints nothing to say it failed.
- **Copy a directory before you move it.** `cp` then delete, never `mv`, and confirm the copy landed
  first. A move can half fail on a file something else has open, and then the source is gone and the
  destination is empty.
- **The tiers apply to your own shell, not only to Ledger calls.** Deleting a folder is the destroy
  tier whatever tool does it, so it needs the same four things: the human named it, you looked first,
  you said what it costs, and you have one confirmation.
- Never hide a defect. A workaround that makes the symptom quiet and leaves the cause is worse than
  the symptom, and say so rather than shipping it.

## What actually enforces this

Nothing here is enforced. It is prompt text and a model under pressure skips prompt text. Two things
do bind, and a developer who cares should set them up:

- **Permissions.** A deny list in `.claude/settings.json` stops the shell commands that do real
  damage, and a hook can gate the rest. Offer it, do not install it.
- **Making the safe path cheaper.** The ten line mock probe is the reason the mock rule gets kept.
  Anything that makes the careful path slower than the reckless one will lose.

A suggested deny list, for a project that wants one:

```json
{
	"permissions": {
		"deny": [
			"Bash(git:*)",
			"Bash(rm:*)",
			"Bash(mv:*)"
		]
	}
}
```
