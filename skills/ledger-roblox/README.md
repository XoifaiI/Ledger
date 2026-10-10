# ledger-roblox

An agent skill for Roblox games built on [Ledger](https://github.com/XoifaiI/Ledger) 7.

```
npx skills add XoifaiI/Ledger
```

Works with Claude Code, Cursor, Copilot, Gemini and anything else that reads a `SKILL.md`.

## What it's for

It isn't the documentation; a full copy of that is in `references/docs-bundle.md`. The skill carries
what a reference page can't: which call to reach for, what a symptom means, which calls are safe on a
live player's key, what a gold-losing bug looks like in a diff, how an AI tends to get Ledger wrong, and
how to move a game from Ledger 6 or onto a new release.

## What's in it

| File | What it holds |
|---|---|
| `SKILL.md` | The project and version checks, what each call touches, the stop points, the mock, the router, how an AI gets Ledger wrong, and the never list |
| `references/review.md` | 28 detectors for code that passes review and loses or duplicates gold later, each with what is not a match |
| `references/triage.md` | Ledger's warnings, a diagnostic block, and symptom to cause to the call that settles it |
| `references/forensics.md` | A real player's gold went wrong: capture the evidence before anything changes it |
| `references/tiers.md` | What each call touches and costs, with the source path behind each row |
| `references/working.md` | The ladder from reads to destroying calls, what gets each rung back, and the rules for live data |
| `references/verify.md` | Which source file answers which question, the surface check, and how to prove a claim on the mock |
| `references/pushback.md` | Asks that will hurt, what to give instead, and when the ask is right |
| `references/escalate.md` | When it's Ledger's own bug, and what to send |
| `references/migrate-v6.md` | Moving a game from Ledger 6 to 7, with the data import and its edge cases |
| `references/updating.md` | Updating a game's code and data when Ledger releases a new version |
| `references/docs-bundle.md` | The whole documentation, so an agent with no web access still has it |

## Where it comes from

The detectors and symptom trees come from a developer who built a full game on Ledger 7 over a
simulated year, from the bugs found in that code, and from measurements of the library itself. Every
claim names the page or source file that settles it.

## Updating the bundle

`references/docs-bundle.md` is the docs site's `llms-full.txt`, copied as is. After a docs change, build
the site and copy it again.

## Not for the library itself

Working on Ledger's own source is a different job. `SKILL.md` checks for that and stops.
