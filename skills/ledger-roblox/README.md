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

## Measured

Three arms on a planted 500 line game module: **A** nothing, **B** the full documentation, **C** the
documentation plus this skill. Twelve real defects planted, six of them deliberately outside the
detector list, plus four decoys that look wrong and are correct.

| | found | off list six | decoys wrongly flagged | invented API |
|---|---|---|---|---|
| A, nothing | not run on this subject | | | |
| B, documentation | 5 / 12 | 4 / 6 | 0 | one |
| C, this skill | **11 / 12** | **6 / 6** | 0 | none |

On an earlier subject, A scored 4 of 12 equivalent, flagged two decoys, and invented two API facts.

The result worth knowing: a reducer that accepts every op it does not handle, written as
`return Patch(State, {})` so it reads as a harmless clone. B missed it and its rewrite made it
explicit with a comment defending it. C worked it out from the rule that any returned table is an
accept. That rule is in the documentation B was holding.

The honest caveat: the same author wrote the detectors and planted the defects, so the on list wins
are partly marking their own homework. The off list six and the endorsement above are not.

## Keeping it true

Pinned to Ledger **5.x**, checked against 5.0.0 and the documentation on 2026-09-04. `SKILL.md` says
what to do when the game is on a different version.

`references/docs-bundle.md` is a verbatim copy of the site's own `llms-full.txt`. Refresh it on each
release:

```
curl -sS https://xoifaii.github.io/LedgerDocs/llms-full.txt > references/docs-bundle.md
```

It is generated rather than written, so it cannot drift into a second version of the rules. It can
only be older than the site, which is why the source outranks it and why `verify.md` says where every
number lives.

## Not for the library itself

Working on Ledger's own source is a different job with a different brief. `SKILL.md` checks for that
and hands off rather than applying any of this.
