---- MODULE Comp ----
EXTENDS Integers, FiniteSets

CONSTANTS
    U,
    Amt,
    Bs,
    Mc,
    Bu,
    Cuts,
    St,
    Kcut,
    Hops,
    Start0,
    StartD,
    MaxEd,
    FixGate,
    FixCutMarks,
    FixKeep,
    FixCutLevel,
    FixViewCut,
    FixFloor,
    FixMigBlock,
    FixOrderRule

VARIABLES
    g, z, lv, fl,
    mk,
    tent, dec,
    gD,
    G, K, hk, c,
    hop,
    eds,
    cg, cz,
    lost, made,
    named,
    took,
    late, stale,
    tentG

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
Low == cg + SumOf({u \in Marks : Amt[u] < 0})

Passes(b) == fl <= Kb(b) \/ ~FixFloor
Blocked(b) == lv < Mc[b] /\ Marks # {} /\ FixMigBlock

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

Commit(u) ==
    /\ tent[u] = "mine" /\ dec[u] = "none"
    /\ dec' = [dec EXCEPT ![u] = "commit"]
    /\ gD' = gD - Amt[u]
    /\ UNCHANGED <<g, z, lv, fl, mk, tent, G, K, hk, c, hop, eds, cg, cz, lost, made, named, took, late, stale, tentG>>
Fence(u) ==
    /\ dec[u] = "none"
    /\ dec' = [dec EXCEPT ![u] = "abort"]
    /\ UNCHANGED <<g, z, lv, fl, mk, tent, gD, G, K, hk, c, hop, eds, cg, cz, lost, made, named, took, late, stale, tentG>>

Resolve(u) ==
    /\ mk[u].on /\ dec[u] # "none"
    /\ g' = IF dec[u] = "commit" THEN g + mk[u].amt ELSE g
    /\ cg' = IF dec[u] = "commit" THEN cg + Amt[u] ELSE cg
    /\ late' = (late \/ (dec[u] = "commit" /\ mk[u].c # c))
    /\ mk' = [mk EXCEPT ![u] = NoMk]
    /\ UNCHANGED <<z, lv, fl, tent, dec, gD, G, K, hk, c, hop, eds, cz, lost, made, named, took, stale, tentG>>

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

Queue(h) ==
    /\ hop[h].st = "none"
    /\ \E v \in 0..c : hop' = [hop EXCEPT ![h] = [st |-> "queued", vc |-> v]]
    /\ UNCHANGED <<g, z, lv, fl, mk, tent, dec, gD, G, K, hk, c, eds, cg, cz, lost, made, named, took, late, stale, tentG>>

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

Held == SumOf({u \in Marks : dec[u] = "commit"})
ZNow == IF z = -1 THEN 0 ELSE cz

Conservation == cg + ZNow + gD + Held + lost = Start0 + StartD + made
NamedExact == named = lost
OwnMeaning == /\ g = cg * Scale(fl)
              /\ \A u \in Marks : mk[u].amt = Amt[u] * Scale(fl)
              /\ (z = -1) = (lv < 2) /\ (z # -1 => z = cz)
NonNeg == cg >= 0 /\ gD >= 0
NoLateLeg == ~late
NoStaleView == ~stale
CutOnce == \A n \in Cuts : took[n] <= 1
NoTentBesideGate == ~tentG

NoCutBesideMarks == ~\E n \in Cuts : took[n] >= 1 /\ \E u \in U : dec[u] = "commit"
NoCutAfterMigration == ~(c >= 1 /\ lv >= 1)
NoTurned == ~\E h \in Hops : hop[h].st = "turned"
====
