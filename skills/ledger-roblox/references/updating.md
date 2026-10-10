# Updating a game when Ledger releases

Use this when the game's Ledger is older than the newest release, or the developer asks to update. Ledger
makes **no compatibility promise across releases**: a release can change the stored format, a default,
the reason set, or which leg decides a trade. So an update is a small migration of its own, done
deliberately, and shipped with a full shutdown.

## 1. Find both versions

The installed one: the `xoifaii/ledger` line in `wally.toml`, or `@xoifail/ledger` in `package.json`
for roblox-ts. A `.rbxm` install has no version to read; ask. Then the new one.

Read the release notes (`releases` in the bundle, or the GitHub release) for **every** version in
between, not only the newest. A change two releases back still applies.

## 2. List what affects this game

The notes mark each change: `+` new, `~` works differently, `-` removed, `!` something to know before
upgrading. Search the game for every `~`, `-` and `!` item and list each hit by file and line. Ignore `+`
items unless the developer wants them. Show the list before changing anything.

What to look for under each:

- **`!` items** come first. They are the ones that can lose data or break a live server: a stored
  format change, a name rule, a setting that became required.
- **`~` items** change an answer or an argument. Every call site and every comparison against the
  answer.
- **`-` items** won't type-check once removed. The checker finds them; list them anyway.

## 3. Change the code

One change per release item, smallest first. For each, show the old and new code. The shapes they take:

- **A setting renamed or reshaped.** Before 7.0.0 shipped, balance kinds were declared in an `Ops` table
  with `Ledger.Credit` and `Ledger.Debit`; 7.0.0 replaced that with `Balances`, keyed by field:

  ```luau
  Ops = { AddGold = Ledger.Credit("Gold"), SpendGold = Ledger.Debit("Gold"), BuyItem = true },
  ```

  became

  ```luau
  Balances = { Gold = { Credit = "AddGold", Debit = "SpendGold" } },
  ```

  Plain kinds like `BuyItem` aren't listed anywhere any more; the `Ops` type covers them.
- **A call's arguments changed.** Every call site; `--!strict` finds them. 7.0.0 examples: `Reset` and
  `Erase` take only a `Ledger.Id()` name (a string `Id` throws), and `Store:Total` throws on a quantity's
  name (use `Store:Quantity(Name):Total()`).
- **An answer changed meaning.** Every comparison, and re-read `learn/answers`. 7.0.0 example: a server
  answers `Expired` for its own `Ledger.Id()` name once it's `CutWindow` old, so a name drawn at the start
  of a slow job now does nothing.
- **A declaration became stricter.** 7.0.0 example: a `Final` quantity must declare `Stock`, and
  `Ledger.New` throws without it.

## 4. Things that change under you without a code change

Check each of these against the notes even when nothing in the game's code looks affected.

- **Defaults.** A release may change `SaveInterval`, `IdleReadInterval`, `OrphanAge`, `CutWindow`, the
  name windows. Write out every setting the game relies on, in its config, so a new default can't change
  it silently.
- **The decider rule.** Which leg decides a `Tx` (today: the only game-op leg, else the first Credit leg,
  else the last) belongs to the release. Work already in flight keeps the rule recorded when it was
  first sent; new trades follow the new rule. Re-read every place legs are ordered for a hot key.
- **The reason set.** Compare the game's `Ledger.Reason.X` uses with the new `Ledger.Reason`. A reason
  the game handles that no longer exists is a branch that never runs.
- **Throughput and costs.** The `limits` page. A game near a budget can tip over.

## 5. Data

The notes say under `!` when a release writes a new stored format. When it does:

- Servers on the older release answer `Unresolved`, `Behind` or `Unreadable` on every key the newer one
  wrote. They can't read it, and they can't write it.
- So a **rollback** after a format change doesn't work: the old release can't read keys the new one
  touched. Plan as if there is no rollback.
- **Studio with API access on the live universe** running the new release writes live keys in the new
  format before the live servers have it. Test on the mock or in a separate universe.
- `Inspect(Key).Book.Format` says which format a key is in. Spot-check a few keys after the update.

Never assume old data reads under a new major version. A major version can be like 6 to 7: a new store
`Name` and an import (`migrate-v6.md`).

## 6. Check, then ship

1. Type-check under `--!strict` with no new errors.
2. Run the game on the mock with the new release.
3. For a release with a `!` about data, run it in a test universe against copied data shapes.
4. Publish **every place** of the game on the new release in one publish window, then **shut down all
   servers**. Two releases in one experience share keys, and an old server can't read what a new one
   wrote. A soft rollout ("migrate to latest") leaves old servers running for hours.
5. Watch the warnings for the first hour: `Unreadable`, `Behind`, unopened stores, a state past 2 MiB.
6. Update the pinned version in `wally.toml` or `package.json` so the next install gets the same one.
