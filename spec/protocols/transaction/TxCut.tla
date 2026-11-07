---- MODULE TxCut ----
EXTENDS Integers, FiniteSets

CONSTANTS
    U,
    Amt,
    Cuts,
    St,
    Kcut,
    Start0,
    StartD,
    MaxEd,
    FixGate,
    FixKeep,
    FixNameNow

VARIABLES
    g0,
    gD,
    mk,
    tent,
    dec,
    G,
    K,
    hk,
    c,
    L,
    eds,
    made,
    lost,
    took,
    late,
    tentG,
    gs

vars == <<g0, gD, mk, tent, dec, G, K, hk, c, L, eds, made, lost, took, late, tentG, gs>>

NoMk == [on |-> FALSE, amt |-> 0, c |-> 0]
NoGate == [n |-> "none", g |-> 0]
Marks == {u \in U : mk[u].on}
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

ASSUME /\ Kcut \in Nat \ {0}
       /\ \A n \in Cuts : St[n] \in Nat \ {0}
       /\ \A u \in U : Amt[u] \in Int \ {0}

Init ==
    /\ g0 = Start0 /\ gD = StartD
    /\ mk = [u \in U |-> NoMk]
    /\ tent = [u \in U |-> "none"]
    /\ dec = [u \in U |-> "none"]
    /\ G = NoGate /\ K = {} /\ hk = 0 /\ c = 0 /\ L = {}
    /\ eds = 0 /\ made = 0 /\ lost = 0
    /\ took = [n \in Cuts |-> 0]
    /\ late = FALSE /\ tentG = FALSE /\ gs = {}

Tent(u) ==
    /\ tent[u] = "none" /\ dec[u] = "none"
    /\ G.n = "none" \/ ~FixGate
    /\ mk' = [mk EXCEPT ![u] = [on |-> TRUE, amt |-> Amt[u], c |-> c]]
    /\ tent' = [tent EXCEPT ![u] = "mine"]
    /\ tentG' = (tentG \/ G.n # "none")
    /\ UNCHANGED <<g0, gD, dec, G, K, hk, c, L, eds, made, lost, took, late, gs>>

Commit(u) ==
    /\ tent[u] = "mine" /\ dec[u] = "none"
    /\ dec' = [dec EXCEPT ![u] = "commit"]
    /\ gD' = gD - Amt[u]
    /\ UNCHANGED <<g0, mk, tent, G, K, hk, c, L, eds, made, lost, took, late, tentG, gs>>

Fence(u) ==
    /\ dec[u] = "none"
    /\ dec' = [dec EXCEPT ![u] = "abort"]
    /\ UNCHANGED <<g0, gD, mk, tent, G, K, hk, c, L, eds, made, lost, took, late, tentG, gs>>

Resolve(u) ==
    /\ mk[u].on /\ dec[u] # "none"
    /\ g0' = IF dec[u] = "commit" THEN g0 + mk[u].amt ELSE g0
    /\ late' = (late \/ (dec[u] = "commit" /\ mk[u].c # c))
    /\ mk' = [mk EXCEPT ![u] = NoMk]
    /\ UNCHANGED <<gD, tent, dec, G, K, hk, c, L, eds, made, lost, took, tentG, gs>>

Credit ==
    /\ eds < MaxEd
    /\ g0' = g0 + 1 /\ made' = made + 1 /\ eds' = eds + 1
    /\ UNCHANGED <<gD, mk, tent, dec, G, K, hk, c, L, lost, took, late, tentG, gs>>

Cut(n) ==
    \/ /\ n \in K /\ FixKeep
       /\ UNCHANGED vars
    \/ /\ ~(n \in K /\ FixKeep)
       /\ St[n] <= hk
       /\ UNCHANGED vars
    \/ /\ ~(n \in K /\ FixKeep) /\ St[n] > hk
       /\ G.n \notin {"none", n}
       /\ UNCHANGED vars
    \/ /\ ~(n \in K /\ FixKeep) /\ St[n] > hk /\ G.n \in {"none", n}
       /\ Marks # {} /\ FixGate
       /\ G' = IF G.n = "none" THEN [n |-> n, g |-> g0] ELSE G
       /\ gs' = gs \cup {n}
       /\ UNCHANGED <<g0, gD, mk, tent, dec, K, hk, c, L, eds, made, lost, took, late, tentG>>
    \/ /\ ~(n \in K /\ FixKeep) /\ St[n] > hk /\ G.n \in {"none", n}
       /\ Marks = {} \/ ~FixGate
       /\ LET named == IF FixNameNow \/ G.n # n THEN g0 ELSE G.g
              K1 == K \cup {n}
              drop == IF Cardinality(K1) > Kcut THEN {Min({St[m] : m \in K1})} ELSE {}
          IN /\ L' = IF named # 0 THEN L \cup {[n |-> n, amt |-> named, c |-> c]} ELSE L
             /\ lost' = lost + g0
             /\ g0' = 0
             /\ c' = c + 1
             /\ K' = {m \in K1 : St[m] \notin drop}
             /\ hk' = IF drop # {} /\ Min(drop) > hk THEN Min(drop) ELSE hk
             /\ G' = NoGate
             /\ took' = [took EXCEPT ![n] = @ + 1]
       /\ UNCHANGED <<gD, mk, tent, dec, eds, made, late, tentG, gs>>

Expire ==
    /\ G.n # "none"
    /\ G' = NoGate
    /\ hk' = IF St[G.n] > hk THEN St[G.n] ELSE hk
    /\ UNCHANGED <<g0, gD, mk, tent, dec, K, c, L, eds, made, lost, took, late, tentG, gs>>

Next ==
    \/ \E u \in U : Tent(u) \/ Commit(u) \/ Fence(u) \/ Resolve(u)
    \/ Credit
    \/ \E n \in Cuts : Cut(n)
    \/ Expire

Spec == Init /\ [][Next]_vars

Held == LET S == {u \in U : mk[u].on /\ dec[u] = "commit"} IN
        IF S = {} THEN 0 ELSE LET f[T \in SUBSET S] == IF T = {} THEN 0
                                                     ELSE LET v == CHOOSE x \in T : TRUE IN mk[v].amt + f[T \ {v}]
                              IN f[S]
Named == LET f[T \in SUBSET L] == IF T = {} THEN 0 ELSE LET e == CHOOSE x \in T : TRUE IN e.amt + f[T \ {e}]
         IN f[L]

Conservation == g0 + gD + Held + lost = Start0 + StartD + made
NamedExact == Named = lost
NoLateLeg == ~late
CutOnce == \A n \in Cuts : took[n] <= 1
NoTentBesideGate == ~tentG

TypeOK ==
    /\ g0 \in Int /\ gD \in Int
    /\ G.n \in Cuts \cup {"none"}
    /\ K \subseteq Cuts /\ Cardinality(K) <= Kcut
    /\ c \in Nat

NoGatedCut == ~\E n \in gs : took[n] = 1
NoCutAfterCredit == ~(eds > 0 /\ c > 0 /\ lost > Start0)
NoEviction == hk = 0
====
