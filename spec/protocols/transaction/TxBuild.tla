------------------------------- MODULE TxBuild -------------------------------
\* TxBuild is phase B3: mixed builds and migrations under the chosen
\* transaction design, for S15 ("an effect keeps its build's meaning")
\* and A3's BehindFloor. It is at the level of landings, as TxAbs is:
\* each action is one write that lands on one key, so stale reads, lost
\* answers, late landings and reruns are interleavings.
\*
\* The rules checked (record 4 steps 5 and 9, record 7, transaction 2.3):
\*   - the floor: a build that does not know every breaking migration the
\*     key has had answers behind and writes nothing (FixFloor);
\*   - a write by a build with more migrations runs the missing ones in
\*     its own Step, and a write that would run one is blocked by every
\*     mark (FixMigBlock);
\*   - a build carries the top level fields it does not declare across
\*     unchanged (FixCarry);
\*   - a leg off the decider stores its effect as data that any build
\*     applies: an end path write runs no build's code and passes the
\*     floor.
\*
\* The game's migrations: 1 is breaking and halves the money unit, so the
\* stored money doubles; 2 is additive and adds the field y, default 0. A
\* build b declares Mc[b] of them. Its unit is 2 once it knows migration
\* 1, else 1, and it writes every amount in its unit. Uses move money by
\* delta legs, as TxAbs; edits credit 1 or set y. The ghosts cg (money in
\* the unit of no migration) and cy (y as its writers meant it) are what
\* the effects meant; S15 is that the stored state always reads as them.
EXTENDS Integers, FiniteSets

CONSTANTS
    \* @type: Set(Str);
    K,              \* keys
    \* @type: Set(Str);
    Bs,             \* builds
    \* @type: Str -> Int;
    Mc,             \* Mc[b]: the migrations build b declares, 0 to 2
    \* @type: Set(Str);
    U,              \* uses
    \* @type: Str -> Str;
    Bu,             \* Bu[u]: the build of u's coordinator
    \* @type: Str -> (Str -> Int);
    Amt,            \* Amt[u][k]: u's leg on k, in the unit of no migration; 0 when u has no leg there
    \* @type: Str -> Str;
    D,              \* D[u]: the decider
    \* @type: Str -> Int;
    Start,          \* Start[k]: the money on k at the start, level 0
    \* @type: Int;
    MaxEd,          \* edits per key
    \* @type: Bool;
    FixFloor,
    \* @type: Bool;
    FixMigBlock,
    \* @type: Bool;
    FixCarry

VARIABLES
    \* @type: Str -> Int;
    g,      \* g[k]: the stored money
    \* @type: Str -> Int;
    y,      \* y[k]: the stored field y, -1 while the key has no such field
    \* @type: Str -> Int;
    lv,     \* lv[k]: the level, how many migrations k has had
    \* @type: Str -> Int;
    fl,     \* fl[k]: the floor, the index of the last breaking migration k has had
    \* @type: Str -> (Str -> { on: Bool, amt: Int });
    mk,     \* mk[k][u]: u's escrow mark on k, [on, amt] with amt as stored
    \* @type: Str -> Str;
    dec,    \* dec[u]: "none", "commit" or "abort", on D[u]
    \* @type: Str -> (Str -> Str);
    tent,   \* tent[u][k]: what u's Tent on k reported: "none", "mine", "behind"
    \* @type: Str -> (Str -> Bool);
    done,   \* done[u][k]: u's leg on k is resolved
    \* @type: Str -> Int;
    eds,    \* eds[k]: edits landed on k
    \* @type: Str -> Int;
    cg,     \* ghost: the money on k as its effects meant it, in the unit of no migration
    \* @type: Str -> Int;
    cy,     \* ghost: y as its writers meant it
    \* @type: Set({ u: Str, r: Str });
    said,   \* ghost: the answers given, [u, r]
    \* @type: Set(Str);
    ow      \* ghost: keys an older build wrote after a newer build migrated them

vars == <<g, y, lv, fl, mk, dec, tent, done, eds, cg, cy, said, ow>>

Legs(u) == {k \in K : Amt[u][k] # 0}
Others(u) == Legs(u) \ {D[u]}
Kb(b) == IF Mc[b] >= 1 THEN 1 ELSE 0
Unit(b) == IF Mc[b] >= 1 THEN 2 ELSE 1
Scale(f) == IF f >= 1 THEN 2 ELSE 1
NoMk == [on |-> FALSE, amt |-> 0]

\* Record 4 step 5: an op write passes the floor only if its build knows every breaking migration.
Passes(b, k) == fl[k] <= Kb(b) \/ ~FixFloor
\* Record 4 step 9: a write that would run a migration is blocked by every mark on its key.
MustMigrate(b, k) == lv[k] < Mc[b]
Blocked(b, k) == MustMigrate(b, k) /\ (\E u \in U : mk[k][u].on) /\ FixMigBlock

\* The key after the missing migrations of b: [g, y, lv, fl]. Marks are data and are not migrated.
Mig(b, k) ==
    [g  |-> IF lv[k] < 1 /\ Mc[b] >= 1 THEN 2 * g[k] ELSE g[k],
     y  |-> IF lv[k] < 2 /\ Mc[b] >= 2 THEN 0 ELSE y[k],
     lv |-> IF lv[k] < Mc[b] THEN Mc[b] ELSE lv[k],
     fl |-> IF Mc[b] >= 1 /\ fl[k] < 1 THEN 1 ELSE fl[k]]

\* What b's write leaves in y: a build that does not declare y carries it, or, with the carry off,
\* writes back its own view, which has no y.
Carry(b, yv) == IF Mc[b] < 2 /\ ~FixCarry THEN -1 ELSE yv

Init ==
    /\ g = Start
    /\ y = [k \in K |-> -1]
    /\ lv = [k \in K |-> 0]
    /\ fl = [k \in K |-> 0]
    /\ mk = [k \in K |-> [u \in U |-> NoMk]]
    /\ dec = [u \in U |-> "none"]
    /\ tent = [u \in U |-> [k \in K |-> "none"]]
    /\ done = [u \in U |-> [k \in K |-> FALSE]]
    /\ eds = [k \in K |-> 0]
    /\ cg = Start
    /\ cy = [k \in K |-> 0]
    /\ said = {}
    /\ ow = {}

\* An op write of build b on k, after the floor and the migrations: the new g is Mig's plus delta, in
\* b's unit. So every op write is one Step: floor, migrations, the op, the carry.
OpWrite(b, k, delta, yset) ==
    LET m == Mig(b, k) IN
    /\ g' = [g EXCEPT ![k] = m.g + delta * Unit(b)]
    /\ y' = [y EXCEPT ![k] = Carry(b, IF yset THEN 1 ELSE m.y)]
    /\ lv' = [lv EXCEPT ![k] = m.lv]
    /\ fl' = [fl EXCEPT ![k] = m.fl]

\* Tent (3.2) of u on a leg key: behind, or the escrow mark in the build's unit.
Tent(u, k) ==
    LET b == Bu[u] IN
    /\ k \in Others(u)
    /\ tent[u][k] = "none" /\ dec[u] = "none"
    /\ IF ~Passes(b, k)
       THEN /\ tent' = [tent EXCEPT ![u][k] = "behind"]
            /\ UNCHANGED <<g, y, lv, fl, mk, cg, cy>>
       ELSE /\ ~Blocked(b, k)
            /\ OpWrite(b, k, 0, FALSE)
            /\ mk' = [mk EXCEPT ![k][u] = [on |-> TRUE, amt |-> Amt[u][k] * Unit(b)]]
            /\ tent' = [tent EXCEPT ![u][k] = "mine"]
            /\ UNCHANGED <<cg, cy>>
    /\ UNCHANGED <<dec, done, eds, said, ow>>

\* Commit (3.3) on the decider once every Tent reported mine; behind on D is a fence (an end path
\* write passes the floor) and a presumed abort, answered Behind.
Commit(u) ==
    LET b == Bu[u]
        d == D[u] IN
    /\ dec[u] = "none"
    /\ \A k \in Others(u) : tent[u][k] = "mine"
    /\ IF ~Passes(b, d)
       THEN /\ dec' = [dec EXCEPT ![u] = "abort"]
            /\ said' = said \cup {[u |-> u, r |-> "Behind"]}
            /\ UNCHANGED <<g, y, lv, fl, cg, cy>>
       ELSE /\ ~Blocked(b, d)
            /\ OpWrite(b, d, Amt[u][d], FALSE)
            /\ dec' = [dec EXCEPT ![u] = "commit"]
            /\ cg' = [cg EXCEPT ![d] = @ + Amt[u][d]]
            /\ said' = said \cup {[u |-> u, r |-> "true"]}
            /\ UNCHANGED cy
    /\ UNCHANGED <<mk, tent, done, eds, ow>>

\* A coordinator that dies or gives up: a touch fences D, a presumed abort (5.1), with no answer.
Abandon(u) ==
    /\ dec[u] = "none"
    /\ dec' = [dec EXCEPT ![u] = "abort"]
    /\ UNCHANGED <<g, y, lv, fl, mk, tent, done, eds, cg, cy, said, ow>>

\* A coordinator that heard behind from a Tent fences D and answers Behind (6.1).
GiveUp(u) ==
    /\ dec[u] = "none"
    /\ \E k \in Others(u) : tent[u][k] = "behind"
    /\ dec' = [dec EXCEPT ![u] = "abort"]
    /\ said' = said \cup {[u |-> u, r |-> "Behind"]}
    /\ UNCHANGED <<g, y, lv, fl, mk, tent, done, eds, cg, cy, ow>>

\* Resolve (3.4), an end path write: it applies the stored amount as data, with no build's code, and
\* passes the floor.
Resolve(u, k) ==
    /\ mk[k][u].on /\ dec[u] # "none"
    /\ g' = [g EXCEPT ![k] = IF dec[u] = "commit" THEN @ + mk[k][u].amt ELSE @]
    /\ cg' = [cg EXCEPT ![k] = IF dec[u] = "commit" THEN @ + Amt[u][k] ELSE @]
    /\ mk' = [mk EXCEPT ![k][u] = NoMk]
    /\ done' = [done EXCEPT ![u][k] = TRUE]
    /\ UNCHANGED <<y, lv, fl, dec, tent, eds, cy, said, ow>>

\* A one key edit by build b: a credit of 1 (it commutes with every escrow mark, 4.1), or, for a build
\* that declares y, y set to 1. Behind writes nothing.
Edit(b, k, sety) ==
    /\ eds[k] < MaxEd
    /\ sety => Mc[b] >= 2
    /\ Passes(b, k)
    /\ ~Blocked(b, k)
    /\ OpWrite(b, k, IF sety THEN 0 ELSE 1, sety)
    /\ cg' = [cg EXCEPT ![k] = IF sety THEN @ ELSE @ + 1]
    /\ cy' = [cy EXCEPT ![k] = IF sety THEN 1 ELSE @]
    /\ eds' = [eds EXCEPT ![k] = @ + 1]
    /\ ow' = IF Mc[b] < lv[k] THEN ow \cup {k} ELSE ow
    /\ UNCHANGED <<mk, dec, tent, done, said>>

Next ==
    \/ \E u \in U, k \in K : Tent(u, k) \/ Resolve(u, k)
    \/ \E u \in U : Commit(u) \/ GiveUp(u) \/ Abandon(u)
    \/ \E b \in Bs, k \in K, sety \in BOOLEAN : Edit(b, k, sety)

Spec == Init /\ [][Next]_vars

\* S15 and A3.

\* OwnMeaning: the stored money reads, at the key's floor, as what every effect on it meant, and a
\* pending leg's stored amount will mean, when applied, what its build meant.
OwnMeaning == \A k \in K :
    /\ g[k] = cg[k] * Scale(fl[k])
    /\ \A u \in U : mk[k][u].on => mk[k][u].amt = Amt[u][k] * Scale(fl[k])

\* NoForeignField: y exists exactly once migration 2 ran, and holds what its writers set; no build
\* that does not declare it ever changed it.
NoForeignField == \A k \in K : (y[k] # -1) = (lv[k] >= 2) /\ (y[k] # -1 => y[k] = cy[k])

\* The floor and the level only grow.
FloorGrows == [][\A k \in K : fl'[k] >= fl[k] /\ lv'[k] >= lv[k]]_vars

\* BehindFloor (A3): a use answered Behind is aborted, so none of its legs takes effect; true only
\* for a commit.
BehindFloor == \A a \in said : a.r = "Behind" => dec[a.u] = "abort"
TrueCommitted == \A a \in said : a.r = "true" => dec[a.u] = "commit"

TypeOK ==
    /\ g \in [K -> Int] /\ y \in [K -> {-1, 0, 1}]
    /\ lv \in [K -> 0..2] /\ fl \in [K -> 0..1]
    /\ mk \in [K -> [U -> [on : BOOLEAN, amt : -2..2]]]    \* a leg of at most 1 in a unit of at most 2
    /\ dec \in [U -> {"none", "commit", "abort"}]

\* Probes: behaviours the checks must reach, or a pass could come from a model that never mixes builds.
\* An older build writes a key a newer build migrated (old servers keep saving after an additive one).
NoOldWrite == ow = {}
\* A use commits across keys at two levels.
NoMixedCommit == ~\E u \in U : dec[u] = "commit" /\ \E j, k \in Legs(u) : lv[j] # lv[k]

\* The inductive invariant, for Apalache (ApaTxBuild): S15 in every state
\* of an instance, not only in the reachable ones TLC visits.

IndInv ==
    /\ TypeOK
    /\ tent \in [U -> [K -> {"none", "mine", "behind"}]]
    /\ done \in [U -> [K -> BOOLEAN]]
    /\ eds \in [K -> 0..MaxEd]
    /\ cg \in [K -> Int] /\ cy \in [K -> {0, 1}]
    /\ said \in SUBSET [u : U, r : {"Behind", "true"}]
    /\ ow \in SUBSET K
    \* The floor is 1 exactly when the breaking migration ran.
    /\ \A k \in K : (fl[k] = 1) = (lv[k] >= 1)
    \* Nobody set y before the migration that adds it.
    /\ \A k \in K : y[k] = -1 => cy[k] = 0
    /\ OwnMeaning /\ NoForeignField /\ BehindFloor /\ TrueCommitted
=============================================================================
