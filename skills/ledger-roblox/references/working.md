# Working on somebody's live data

Read this before any call that writes to a live game's DataStores. The rules are about **data**. Code
the developer asked you to change is ordinary work and needs none of this.

Remember what counts as live: a Studio session with API access on the live universe is a live server.
It loads real players, writes real keys, and runs the close when you stop it. Only a store running on
`Mock = Mock.New(...)`, or a separate test universe, is not live.

## The ladder

Say which rung a call is on before making it.

| Rung | What it is | What gets it back |
|---|---|---|
| A read | `Inspect`, `Pending`, `Losses`, `Peek`. Can end a dead server's trade work it meets | nothing to get back; it does what a touch would have done |
| A refused or unsent write | `Refused`, `Busy`, `Closed`, `NoRoom`, ... nothing happened | nothing to get back |
| An ordinary write | `Edit`, `Commit`, `Apply`, a `Tx`. One change, saved once | another op that undoes it, if the reducer has one |
| `Resettle` | ends unfinished trade work now: applies decided legs, aborts undecided ones, returns escrow | nothing; it's what the next touch would do anyway, sooner. A live sender loses one attempt and tries again |
| `Quantity:Close` | the sale ends; empty parts older than 62 minutes are removed | **nothing**. Never `Open` it again. A restock is a new quantity |
| `Reset` | the state replaced with `Default` or a given `State`; every non-zero balance field named in `Losses` for 7 days | a later `Reset` with the old `State`, read from Roblox's version history, while Roblox keeps it (30 days). Items are not named anywhere but the history |
| `Erase` | the key sealed, then removed; `Cut.Losses` names the balances, **in the first answer only** | Roblox's older versions, for 30 days. Ledger can't bring the key back: a key made again is a new incarnation |
| `Destroy`, `CloseAll` | every session on the store, or the server, saved and ended | the players rejoin; the store's name can't be reopened on that server |

**There is no restore call.** Ledger keeps no history; Roblox keeps replaced versions for 30 days, and
the newest version never expires. Getting a player back means reading an old version's state (see
`forensics.md`) and writing it with an op or a `Reset { State = ... }`. Either one replaces whatever
arrived in between, gold from a trade included, so compare before and after and say what will be lost.
Never write a raw value back with DataStore calls. A plain table reads `Unreadable`, and an old Ledger
record puts old bookkeeping back with it: names the key had remembered are forgotten, so resends apply
again, and escrow for trades in flight disappears.

So: **capture first and show it.** A destructive call with a saved capture before it is something a
person can undo. One without is a guess.

## Before a destructive call

1. The human named the key in their own words.
2. You captured it (`Inspect`, plus `Losses` and `Pending` when money is involved) and showed it.
3. You said which rung this is and what gets it back.
4. You have one confirmation, for that key. The next key needs its own.

If any of the four is missing, say what's missing and stop there. This is the only place in this skill
where stopping and waiting is the right answer.

## Blast radius

- No destructive call inside a loop on a first pass. Print the list and the count, and let the human
  name the count back.
- A key list from `Store:Keys()` or a scan is something to show, never something to act on. Its pages
  come in no order and can miss keys made while listing.
- A loop of reads is a budget question too: each server gets 60 + 40 per player reads a minute. A scan
  paces itself and queues `Busy` and `Unresolved` keys for a later round.
- `CloseAll` and `Destroy` are shutdown, not cleanup. They end every live session.
- A support tool's write records its own ticket id in the data, because somebody will click the button
  twice, next week, on another server.
- Never pay by hand for a move that answered `Unresolved` while its server may be alive. The writer will
  land it, and the player is paid twice.

## Prove it on the mock first

Any answer you're not certain of runs on the mock before it goes near a real key. Rules that make that
actually work:

- Build the probe with the game's own `Default`, `Reducer`, `Balances`, `Migrations` and `Quantities`. A
  probe against a different reducer proves nothing about theirs.
- Never probe against a real key, and never use a real UserId as a fixture.
- Run the probe in its own script or place. The mock is per server and must be given before Ledger's
  first request, so it can't sit beside the game's real stores in one server.
- Pick values where every outcome reads differently. Spend 30 from 100, not 100 from 100.
- Check the probe reached the branch in question. A green run where the case never fired is not
  evidence. Print the answers, all three values.
- Say what the probe showed, including when it showed you were wrong.

What the mock can't show: two builds side by side, a second live server, real outages, real throttling
under real contention, MemoryStore's real memory, and anything about this game's data at scale. A green
probe is evidence about logic, not about the platform.

## Not getting ahead of yourself

- Do what was asked and stop there. A problem you noticed next to it is a sentence in the recap, not an
  edit.
- No files nobody asked for: no wrapper module, no retry helper, no config, no CI, no test harness.
- Edit, don't rewrite. A rewrite only when most of the file is changing, and say so first.
- Keep the game's style: its naming, its comment habits, its module layout.
- One change, then a way to check it: the type checker under `--!strict`, then the mock.
- Never run a git command unless asked. Committing is the developer's.
- A command that was interrupted or refused may have half run. Look for what it left before trying
  again.
- **Never chain a destructive command with anything else.** Deletes and moves go on their own line, run
  on their own, and are checked before the next thing runs.
- **Copy before you move.** Copy, confirm the copy landed, then delete. A move can half fail and leave
  neither.
- **The ladder applies to your own shell too.** Deleting a folder is the destroy rung whatever tool does
  it: named, looked at, costed, confirmed.
- Never hide a defect. A workaround that makes a symptom quiet and leaves the cause is worse than the
  symptom; say so rather than shipping it.

## What actually enforces this

Nothing here is enforced. It is prompt text, and a model under pressure skips prompt text. Two things
do bind, and a developer who cares should set them up:

- **Permissions.** A deny list in the agent's settings stops the shell commands that do real damage,
  and a hook can gate the rest. Offer it; don't install it.
- **Making the safe path cheaper.** A ten-line mock probe is why the mock rule gets kept. Anything that
  makes the careful path slower than the reckless one will lose.

A suggested deny list, for a Claude Code project that wants one (`.claude/settings.json`):

```json
{
	"permissions": {
		"deny": [
			"Bash(git push:*)",
			"Bash(git reset:*)",
			"Bash(rm:*)",
			"Bash(mv:*)"
		]
	}
}
```
