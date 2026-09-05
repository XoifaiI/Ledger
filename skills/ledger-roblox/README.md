# ledger-roblox

An agent skill for games built on [Ledger](https://github.com/XoifaiI/Ledger), the lock free
datastore library for Roblox where state is a fold over a log of ops.

```
npx skills add XoifaiI/Ledger
```

Works with Claude Code, Cursor, Copilot, Gemini and anything else that reads a `SKILL.md`.

## What it is for

It is not documentation. The documentation is at
https://xoifaii.github.io/LedgerDocs/docs and it covers the whole surface. This carries the things a
reference page cannot: which call to reach for, what a symptom means, which calls are safe to run on
a live player's key, and what a money losing bug looks like in a diff.

The one job it is built around: **finding the code that reviews clean, passes a test, and duplicates
or destroys money six weeks later.**

## What is in it

| file | what it holds |
|---|---|
| `SKILL.md` | the version and project checks, what each call touches, the stop points, the router |
| `references/review.md` | **seventeen detectors**, each with the shape in code, why it survives review, what it costs, when it fires, and what is not a match |
| `references/forensics.md` | a money bug on a real player: capture the evidence before touching the key |
| `references/triage.md` | symptom to cause to the call to make |
| `references/tiers.md` | which calls read, which write, which start background work, with the call path behind each |
| `references/working.md` | the irreversibility ladder, the mock rule, agent conduct |
| `references/verify.md` | how to settle a claim: read the source, run it, ask the developer, or say you do not know |
| `references/pushback.md` | asks that hurt, what to give instead, and when each is actually right |
| `references/escalate.md` | when it is Ledger's own bug and the evidence to send |
| `references/docs-bundle.md` | the whole documentation, generated, so a model with no web access still has the reference |

## Not for the library itself

Working on Ledger's own source is a different job with a different brief. `SKILL.md` checks for that
and hands off rather than applying any of this.
