---- MODULE TxBuild ----
EXTENDS Integers, FiniteSets

CONSTANTS
    K,
    Bs,
    Mc,
    U,
    Bu,
    Amt,
    D,
    Start,
    MaxEd,
    FixFloor,
    FixMigBlock,
    FixCarry

VARIABLES
    g,
    y,
    lv,
    fl,
    mk,
    dec,
    tent,
    done,
    eds,
    cg,
    cy,
    said,
    ow

vars == <<g, y, lv, fl, mk, dec, tent, done, eds, cg, cy, said, ow>>

Legs(u) == {k \in K : Amt[u][k] # 0}
Others(u) == Legs(u) \ {D[u]}
Kb(b) == IF Mc[b] >= 1 THEN 1 ELSE 0
Unit(b) == IF Mc[b] >= 1 THEN 2 ELSE 1
Scale(f) == IF f >= 1 THEN 2 ELSE 1
NoMk == [on |-> FALSE, amt |-> 0]

Passes(b, k) == fl[k] <= Kb(b) \/ ~FixFloor
MustMigrate(b, k) == lv[k] < Mc[b]
Blocked(b, k) == MustMigrate(b, k) /\ (\E u \in U : mk[k][u].on) /\ FixMigBlock

Mig(b, k) ==
    [g  |-> IF lv[k] < 1 /\ Mc[b] >= 1 THEN 2 * g[k] ELSE g[k],
     y  |-> IF lv[k] < 2 /\ Mc[b] >= 2 THEN 0 ELSE y[k],
     lv |-> IF lv[k] < Mc[b] THEN Mc[b] ELSE lv[k],
     fl |-> IF Mc[b] >= 1 /\ fl[k] < 1 THEN 1 ELSE fl[k]]

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

OpWrite(b, k, delta, yset) ==
    LET m == Mig(b, k) IN
    /\ g' = [g EXCEPT ![k] = m.g + delta * Unit(b)]
    /\ y' = [y EXCEPT ![k] = Carry(b, IF yset THEN 1 ELSE m.y)]
    /\ lv' = [lv EXCEPT ![k] = m.lv]
    /\ fl' = [fl EXCEPT ![k] = m.fl]

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

Abandon(u) ==
    /\ dec[u] = "none"
    /\ dec' = [dec EXCEPT ![u] = "abort"]
    /\ UNCHANGED <<g, y, lv, fl, mk, tent, done, eds, cg, cy, said, ow>>

GiveUp(u) ==
    /\ dec[u] = "none"
    /\ \E k \in Others(u) : tent[u][k] = "behind"
    /\ dec' = [dec EXCEPT ![u] = "abort"]
    /\ said' = said \cup {[u |-> u, r |-> "Behind"]}
    /\ UNCHANGED <<g, y, lv, fl, mk, tent, done, eds, cg, cy, ow>>

Resolve(u, k) ==
    /\ mk[k][u].on /\ dec[u] # "none"
    /\ g' = [g EXCEPT ![k] = IF dec[u] = "commit" THEN @ + mk[k][u].amt ELSE @]
    /\ cg' = [cg EXCEPT ![k] = IF dec[u] = "commit" THEN @ + Amt[u][k] ELSE @]
    /\ mk' = [mk EXCEPT ![k][u] = NoMk]
    /\ done' = [done EXCEPT ![u][k] = TRUE]
    /\ UNCHANGED <<y, lv, fl, dec, tent, eds, cy, said, ow>>

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

OwnMeaning == \A k \in K :
    /\ g[k] = cg[k] * Scale(fl[k])
    /\ \A u \in U : mk[k][u].on => mk[k][u].amt = Amt[u][k] * Scale(fl[k])

NoForeignField == \A k \in K : (y[k] # -1) = (lv[k] >= 2) /\ (y[k] # -1 => y[k] = cy[k])

FloorGrows == [][\A k \in K : fl'[k] >= fl[k] /\ lv'[k] >= lv[k]]_vars

BehindFloor == \A a \in said : a.r = "Behind" => dec[a.u] = "abort"
TrueCommitted == \A a \in said : a.r = "true" => dec[a.u] = "commit"

TypeOK ==
    /\ g \in [K -> Int] /\ y \in [K -> {-1, 0, 1}]
    /\ lv \in [K -> 0..2] /\ fl \in [K -> 0..1]
    /\ mk \in [K -> [U -> [on : BOOLEAN, amt : -2..2]]]
    /\ dec \in [U -> {"none", "commit", "abort"}]

NoOldWrite == ow = {}
NoMixedCommit == ~\E u \in U : dec[u] = "commit" /\ \E j, k \in Legs(u) : lv[j] # lv[k]

IndInv ==
    /\ TypeOK
    /\ tent \in [U -> [K -> {"none", "mine", "behind"}]]
    /\ done \in [U -> [K -> BOOLEAN]]
    /\ eds \in [K -> 0..MaxEd]
    /\ cg \in [K -> Int] /\ cy \in [K -> {0, 1}]
    /\ said \in SUBSET [u : U, r : {"Behind", "true"}]
    /\ ow \in SUBSET K
    /\ \A k \in K : (fl[k] = 1) = (lv[k] >= 1)
    /\ \A k \in K : y[k] = -1 => cy[k] = 0
    /\ OwnMeaning /\ NoForeignField /\ BehindFloor /\ TrueCommitted
====
