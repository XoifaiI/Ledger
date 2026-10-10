---------------------------------- MODULE Comp ---------------------------------
\* Comp is the composed model of the design (goal 5, step 5): every
\* protocol that writes a game key, on one key k0, at the level of
\* landings, as TxAbs, TxBuild and TxCut are: each action is one write
\* that lands, so stale reads, lost answers, late landings, reruns and
\* helpers are interleavings. What happens inside a request under faults
\* is Rec.tla's and Tx.tla's; here the protocols meet.
\*
\* On k0, whose money fields are g and, once migration 2 ran, z:
\*   - transaction legs (transaction 3): a Tent places an escrow mark of
\*     its use's leg in its build's unit, gated by a cut's gate (cuts
\*     3.3), refused by the floor (record 4 step 5), blocked when it would
\*     run a migration beside a mark (step 9), refused when the low of g
\*     cannot cover a debit (4.1); the Commit on the decider d; a fence
\*     that aborts; the Resolve, an end path write, applies the stored
\*     amount as data;
\*   - one key edits (record 5.1): a credit or a debit of 1 on g, a debit
\*     judged under every way the escrow marks may end (transaction 4.1),
\*     and a credit on z by a build that declares it;
\*   - a session's hopeful ops (record 5.2, 6): a credit of 1 judged on a
\*     view whose cut count may be old; rule 7 turns it away (C) when its
\*     view's c is not the key's;
\*   - Resets (cuts 3.1): kept in K; forgotten below hk; behind when the
\*     cutter's build lacks the key's floor or level (rule 4, S9); another
\*     cut's gate; marks stand: place the gate; else cut: name each money
\*     field the cutter's build declares, put the state back to that
\*     build's default, set its level and floor, add 1 to c, keep the name
\*     in K (Kcut names, hk over the one dropped), clear the gate;
\*   - two builds (record 7): migration 1 is breaking and halves the money
\*     unit, migration 2 is additive and adds the money field z; a write
\*     runs the migrations its build has and the key lacks; a build that
\*     does not declare z carries it.
\*
\* The ghosts hold money in the unit of no migration: cg and cz what the
\* effects on g and z meant, lost what cuts destroyed, made what credits
\* made, and the named events.
EXTENDS Integers, FiniteSets

CONSTANTS
    U,            \* uses, each with one leg on k0 and one on the decider d
    Amt,          \* Amt[u]: u's leg on k0 in the unit of no migration; its leg on d is -Amt[u]
    Bs,           \* builds
    Mc,           \* Mc[b]: the migrations build b declares, 0 to 2
    Bu,           \* Bu[u]: the build of u's coordinator
    Cuts,         \* Reset names
    St,           \* St[n]: the stamp of cut n
    Kcut,         \* cut names K keeps
    Hops,         \* hopeful ops (credits of 1 from a session)
    Start0,       \* money on k0 at the start (g, level 0)
    StartD,       \* money on d at the start
    MaxEd,        \* one key edits on k0
    FixGate,      \* a Tent meets a cut's gate and lands nothing (cuts 3.3)
    FixCutMarks,  \* a cut lands only with no mark standing (cuts 3.1 rule 8)
    FixKeep,      \* a cut whose name is in K cuts nothing (rule 1)
    FixCutLevel,  \* a cut from a build behind the key's floor or level answers behind (rule 4, S9)
    FixViewCut,   \* a hopeful op of an older view's c is turned away (record 4 rule 7)
    FixFloor,     \* an op of a build behind the floor answers behind (record 4 step 5)
    FixMigBlock,  \* a write that would run a migration is blocked by every mark (step 9)
    FixOrderRule  \* a debit beside escrow marks is judged under every way they may end (tx 4.1)

VARIABLES
    g, z, lv, fl,   \* k0's stored money g (in the unit of its floor), z (-1: no such field), level, floor
    mk,             \* mk[u]: u's escrow mark on k0: [on, amt as stored, c when placed]
    tent, dec,      \* tent[u]: "none", "mine", "no"; dec[u] on d: "none", "commit", "abort"
    gD,             \* money on d (no migrations there)
    G, K, hk, c,    \* the cut's gate [n], the cut names kept, their horizon, the cut count
    hop,            \* hop[h]: [st: "none", "queued", "took", "turned"; vc: its view's c]
    eds,            \* one key edits landed
    cg, cz,         \* ghosts: g and z as their effects meant them, in the unit of no migration
    lost, made,     \* ghosts: money cuts destroyed; money credits made
    named,          \* ghost: the money cuts named
    took,           \* ghost: took[n], how often cut n took effect
    late, stale,    \* ghosts: a leg on a state after a cut its mark missed; a hopeful op the same
    tentG           \* ghost: a Tent landed beside a gate

vars == <<g, z, lv, fl, mk, tent, dec, gD, G, K, hk, c, hop, eds, cg, cz, lost, made, named, took,
          late, stale, tentG>>

NoMk == [on |-> FALSE, amt |-> 0, c |-> 0]
Marks == {u \in U : mk[u].on}
Kb(b) == IF Mc[b] >= 1 THEN 1 ELSE 0
Unit(b) == IF Mc[b] >= 1 THEN 2 ELSE 1
Scale(f) == IF f >= 1 THEN 2 ELSE 1
Min(S) == CHOOSE x \in S : \A y \in S : x <= y
RECURSIVE SumOf(_)
SumOf(S) == IF S = {} THEN 0 ELSE LET u == CHOOSE x \in S : TRUE IN Amt[u] + SumOf(S \ {u})
\* The low of g in the unit of no migration: every standing debit mark taken as landed (4.1).
Low == cg + SumOf({u \in Marks : Amt[u] < 0})

\* Record 4 step 5, and step 9.
Passes(b) == fl <= Kb(b) \/ ~FixFloor
Blocked(b) == lv < Mc[b] /\ Marks # {} /\ FixMigBlock

\* A write of build b: its missing migrations run first (1 doubles the stored money, 2 adds z at 0).
MigG(b) == IF lv < 1 /\ Mc[b] >= 1 THEN 2 * g ELSE g
MigZ(b) == IF lv < 2 /\ Mc[b] >= 2 THEN 0 ELSE z
MigLv(b) == IF lv < Mc[b] THEN Mc[b] ELSE lv
MigFl(b) == IF Mc[b] >= 1 /\ fl < 1 THEN 1 ELSE fl

Write(b, dg, dz) ==
    /\ g' = MigG(b) + dg * Unit(b)
    /\ z' = MigZ(b) + dz
    /\ lv' = MigLv(b) /\ fl' = MigFl(b)

Init ==
    /\ g = Start0 /\ z = -1 /\ lv = 0 /\ fl = 0
    /\ mk = [u \in U |-> NoMk]
    /\ tent = [u \in U |-> "none"] /\ dec = [u \in U |-> "none"]
    /\ gD = StartD
    /\ G = "none" /\ K = {} /\ hk = 0 /\ c = 0
    /\ hop = [h \in Hops |-> [st |-> "none", vc |-> 0]]
    /\ eds = 0
    /\ cg = Start0 /\ cz = 0 /\ lost = 0 /\ made = 0 /\ named = 0
    /\ took = [n \in Cuts |-> 0]
    /\ late = FALSE /\ stale = FALSE /\ tentG = FALSE

\* Tent of u on k0: gated, behind, blocked, refused (a debit its low cannot cover), or its mark.
Tent(u) ==
    LET b == Bu[u] IN
    /\ tent[u] = "none" /\ dec[u] = "none"
    /\ G = "none" \/ ~FixGate
    /\ ~Blocked(b)
    /\ IF ~Passes(b) \/ (Amt[u] < 0 /\ Low + Amt[u] < 0)
       THEN /\ tent' = [tent EXCEPT ![u] = "no"]
            /\ UNCHANGED <<g, z, lv, fl, mk, tentG>>
       ELSE /\ Write(b, 0, 0)
            /\ mk' = [mk EXCEPT ![u] = [on |-> TRUE, amt |-> Amt[u] * Unit(b), c |-> c]]
            /\ tent' = [tent EXCEPT ![u] = "mine"]
            /\ tentG' = (tentG \/ G # "none")
    /\ UNCHANGED <<dec, gD, G, K, hk, c, hop, eds, cg, cz, lost, made, named, took, late, stale>>

\* Commit on d once the Tent reported mine; a fence of d aborts (the coordinator, a cutter, a touch).
Commit(u) ==
    /\ tent[u] = "mine" /\ dec[u] = "none"
    /\ dec' = [dec EXCEPT ![u] = "commit"]
    /\ gD' = gD - Amt[u]
    /\ UNCHANGED <<g, z, lv, fl, mk, tent, G, K, hk, c, hop, eds, cg, cz, lost, made, named, took, late, stale, tentG>>
Fence(u) ==
    /\ dec[u] = "none"
    /\ dec' = [dec EXCEPT ![u] = "abort"]
    /\ UNCHANGED <<g, z, lv, fl, mk, tent, gD, G, K, hk, c, hop, eds, cg, cz, lost, made, named, took, late, stale, tentG>>

\* Resolve on k0, an end path write: the stored amount as data, with no build's code and no floor.
Resolve(u) ==
    /\ mk[u].on /\ dec[u] # "none"
    /\ g' = IF dec[u] = "commit" THEN g + mk[u].amt ELSE g
    /\ cg' = IF dec[u] = "commit" THEN cg + Amt[u] ELSE cg
    /\ late' = (late \/ (dec[u] = "commit" /\ mk[u].c # c))
    /\ mk' = [mk EXCEPT ![u] = NoMk]
    /\ UNCHANGED <<z, lv, fl, tent, dec, gD, G, K, hk, c, hop, eds, cz, lost, made, named, took, stale, tentG>>

\* One key edits by build b: a credit of 1 on g, a debit of 1 on g judged at the low (or, with the
\* order rule off, on g alone), or a credit of 1 on z by a build that declares it.
Edit(b, kind) ==
    /\ eds < MaxEd
    /\ Passes(b) /\ ~Blocked(b)
    /\ kind = "z" => Mc[b] >= 2
    /\ kind = "debit" => (IF FixOrderRule THEN Low - 1 >= 0 ELSE cg - 1 >= 0)
    /\ Write(b, CASE kind = "credit" -> 1 [] kind = "debit" -> -1 [] OTHER -> 0, IF kind = "z" THEN 1 ELSE 0)
    /\ cg' = cg + (CASE kind = "credit" -> 1 [] kind = "debit" -> -1 [] OTHER -> 0)
    /\ cz' = IF kind = "z" THEN cz + 1 ELSE cz
    /\ made' = made + (IF kind \in {"credit", "z"} THEN 1 ELSE 0) - (IF kind = "debit" THEN 1 ELSE 0)
    /\ eds' = eds + 1
    /\ UNCHANGED <<mk, tent, dec, gD, G, K, hk, c, hop, lost, named, took, late, stale, tentG>>

\* A session applies a hopeful credit on its view, whose cut count may be older than the key's.
Queue(h) ==
    /\ hop[h].st = "none"
    /\ \E v \in 0..c : hop' = [hop EXCEPT ![h] = [st |-> "queued", vc |-> v]]
    /\ UNCHANGED <<g, z, lv, fl, mk, tent, dec, gD, G, K, hk, c, eds, cg, cz, lost, made, named, took, late, stale, tentG>>

\* Its push lands (build "new", which knows every migration): rule 7 turns it away on another c.
Push(h) ==
    LET b == CHOOSE x \in Bs : \A y \in Bs : Mc[x] >= Mc[y] IN
    /\ hop[h].st = "queued"
    /\ ~Blocked(b)
    /\ IF hop[h].vc # c /\ FixViewCut
       THEN /\ hop' = [hop EXCEPT ![h].st = "turned"]
            /\ UNCHANGED <<g, z, lv, fl, cg, made, stale>>
       ELSE /\ Write(b, 1, 0)
            /\ hop' = [hop EXCEPT ![h].st = "took"]
            /\ cg' = cg + 1 /\ made' = made + 1
            /\ stale' = (stale \/ hop[h].vc # c)
    /\ UNCHANGED <<mk, tent, dec, gD, G, K, hk, c, eds, cz, lost, named, took, late, tentG>>

\* One landing of cut n's op from a server of build b (cuts 3.1).
Cut(n, b) ==
    LET keep == n \in K /\ FixKeep
        behind == (fl > Kb(b) \/ lv > Mc[b]) /\ FixCutLevel
        own == G = n
    IN
    /\ ~keep /\ (own \/ St[n] > hk) /\ ~behind /\ G \in {"none", n}
    /\ IF Marks # {} /\ FixCutMarks
       THEN /\ G' = n
            /\ UNCHANGED <<g, z, lv, fl, K, hk, c, cg, cz, lost, named, took>>
       ELSE LET K1 == K \cup {n}
                drop == IF Cardinality(K1) > Kcut THEN {Min({St[m] : m \in K1})} ELSE {}
                zv == IF z = -1 THEN 0 ELSE cz
            IN /\ named' = named + cg + (IF Mc[b] >= 2 THEN zv ELSE 0)
               /\ lost' = lost + cg + zv
               /\ g' = 0 /\ cg' = 0
               /\ z' = (IF Mc[b] >= 2 THEN 0 ELSE -1)
               /\ cz' = 0
               /\ lv' = Mc[b] /\ fl' = Kb(b)
               /\ c' = c + 1
               /\ K' = {m \in K1 : St[m] \notin drop}
               /\ hk' = IF drop # {} /\ Min(drop) > hk THEN Min(drop) ELSE hk
               /\ G' = "none"
               /\ took' = [took EXCEPT ![n] = @ + 1]
    /\ UNCHANGED <<mk, tent, dec, gD, hop, eds, made, late, stale, tentG>>

\* Record step 7: a gate W[cut] past its stamp is dropped, raising hk.
Expire ==
    /\ G # "none"
    /\ G' = "none" /\ hk' = IF St[G] > hk THEN St[G] ELSE hk
    /\ UNCHANGED <<g, z, lv, fl, mk, tent, dec, gD, K, c, hop, eds, cg, cz, lost, made, named, took, late, stale, tentG>>

Next ==
    \/ \E u \in U : Tent(u) \/ Commit(u) \/ Fence(u) \/ Resolve(u)
    \/ \E b \in Bs, kind \in {"credit", "debit", "z"} : Edit(b, kind)
    \/ \E h \in Hops : Queue(h) \/ Push(h)
    \/ \E n \in Cuts, b \in Bs : Cut(n, b)
    \/ Expire

Spec == Init /\ [][Next]_vars

\* The properties.

\* Committed legs not yet resolved on k0, in the unit of no migration.
Held == SumOf({u \in Marks : dec[u] = "commit"})
ZNow == IF z = -1 THEN 0 ELSE cz

\* S1 with S2's namings: the money on the keys, legs in flight and what cuts destroyed is the money at
\* the start and what credits made.
Conservation == cg + ZNow + gD + Held + lost = Start0 + StartD + made
\* S2 (and S9 through it): every cut names all the money it destroys.
NamedExact == named = lost
\* S15: the stored money reads at the key's floor as its effects meant; a pending leg too.
OwnMeaning == /\ g = cg * Scale(fl)
              /\ \A u \in Marks : mk[u].amt = Amt[u] * Scale(fl)
              /\ (z = -1) = (lv < 2) /\ (z # -1 => z = cz)
\* S8: no balance below 0.
NonNeg == cg >= 0 /\ gD >= 0
\* S10: no leg, and no hopeful op, takes effect on a state after a cut it was not judged under.
NoLateLeg == ~late
NoStaleView == ~stale
\* S5 for cuts.
CutOnce == \A n \in Cuts : took[n] <= 1
\* Cuts 3.3: no Tent lands beside a gate.
NoTentBesideGate == ~tentG

\* Probes: the meetings the model is for.
NoCutBesideMarks == ~\E n \in Cuts : took[n] >= 1 /\ \E u \in U : dec[u] = "commit"  \* a cut and a commit
NoCutAfterMigration == ~(c >= 1 /\ lv >= 1)                                          \* a cut at a newer level
NoTurned == ~\E h \in Hops : hop[h].st = "turned"                                    \* rule 7 turned one away
=============================================================================
