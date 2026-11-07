---- MODULE TxAbs ----
EXTENDS Integers, FiniteSets, FiniteSetsExt

CONSTANTS
    K,
    U,
    MaxA,
    Amt,
    D,
    Start,
    Off

VARIABLES
    bal,
    mk,
    fate,
    fa,
    dec,
    gone,
    placed,
    noCom,
    gd,
    ca,
    took,
    fmax

vars == <<bal, mk, fate, fa, dec, gone, placed, noCom, gd, ca, took, fmax>>

A == 1..MaxA
Legs(u) == {k \in K : Amt[u][k] # 0}
Others(u) == Legs(u) \ {D[u]}
NoDec == [st |-> "none", a |-> 0, fin |-> FALSE]

ASSUME AbsConstants ==
    /\ IsFiniteSet(K) /\ IsFiniteSet(U)
    /\ MaxA \in Nat \ {0}
    /\ Amt \in [U -> [K -> Int]]
    /\ D \in [U -> K]
    /\ Start \in [K -> Nat]
    /\ \A u \in U : D[u] \in Legs(u) /\ Cardinality(Legs(u)) >= 2
    /\ Off \subseteq {"attempt", "placed", "low", "drop", "fence", "giveup", "gone"}

Sum(S, f(_)) == FoldSet(LAMBDA x, acc : f(x) + acc, 0, S)

ASSUME LegsBalance == \A u \in U : Sum(K, LAMBDA k : Amt[u][k]) = 0

HeldV(g, c, m, k, u) == IF g[u] = "commit" /\ m[k][u] = c[u] /\ m[k][u] # 0 THEN Amt[u][k] ELSE 0
BalV(b, g, c, m, k) == b[k] + Sum(U, LAMBDA u : HeldV(g, c, m, k, u))
ConsV(b, g, c, m) == Sum(K, LAMBDA k : BalV(b, g, c, m, k))
Held(k, u) == HeldV(gd, ca, mk, k, u)
Bal(k) == BalV(bal, gd, ca, mk, k)
Total == Sum(K, LAMBDA k : Start[k])

NegV(m, k, u) == IF m[k][u] # 0 /\ Amt[u][k] < 0 THEN Amt[u][k] ELSE 0
LowV(b, m, k) == b[k] + Sum(U, LAMBDA u : NegV(m, k, u))
LowOn(k) == LowV(bal, mk, k)

Init ==
    /\ bal = Start
    /\ mk = [k \in K |-> [u \in U |-> 0]]
    /\ fate = [k \in K |-> [u \in U |-> "none"]]
    /\ fa = [k \in K |-> [u \in U |-> 0]]
    /\ dec = [k \in K |-> [u \in U |-> NoDec]]
    /\ gone = [k \in K |-> {}]
    /\ placed = [u \in U |-> [a \in A |-> {}]]
    /\ noCom = [u \in U |-> [a \in A |-> FALSE]]
    /\ gd = [u \in U |-> "none"]
    /\ ca = [u \in U |-> 0]
    /\ took = [u \in U |-> [k \in K |-> 0]]
    /\ fmax = [u \in U |-> 0]

Tent(u, a, k) ==
    /\ k \in Others(u)
    /\ a = 1 \/ fmax[u] >= a - 1 \/ "attempt" \in Off
    /\ mk[k][u] < a
    /\ dec[k][u].st = "none"
    /\ fate[k][u] = "none" \/ (fate[k][u] = "aborted" /\ fa[k][u] < a)
    /\ u \notin gone[k] \/ "gone" \in Off
    /\ LET low == LowOn(k) - (IF mk[k][u] # 0 /\ Amt[u][k] < 0 THEN Amt[u][k] ELSE 0) IN
       IF Amt[u][k] < 0 /\ low + Amt[u][k] < 0
       THEN /\ fate' = [fate EXCEPT ![k][u] = "R"]
            /\ fa' = [fa EXCEPT ![k][u] = 0]
            /\ mk' = [mk EXCEPT ![k][u] = 0]
            /\ UNCHANGED placed
       ELSE /\ mk' = [mk EXCEPT ![k][u] = a]
            /\ placed' = [placed EXCEPT ![u][a] = @ \cup {k}]
            /\ UNCHANGED <<fate, fa>>
    /\ UNCHANGED <<bal, dec, gone, noCom, gd, ca, took, fmax>>

Commit(u, a) ==
    LET d == D[u] IN
    /\ a \in A
    /\ Others(u) \subseteq placed[u][a] \/ "placed" \in Off
    /\ ~noCom[u][a]
    /\ \/ dec[d][u].st = "none"
       \/ dec[d][u].st = "fenced" /\ ((~dec[d][u].fin /\ dec[d][u].a < a) \/ "fence" \in Off)
    /\ u \notin gone[d]
    /\ fate[d][u] = "none" /\ mk[d][u] = 0
    /\ Amt[u][d] >= 0 \/ LowOn(d) + Amt[u][d] >= 0 \/ "low" \in Off
    /\ bal' = [bal EXCEPT ![d] = @ + Amt[u][d]]
    /\ dec' = [dec EXCEPT ![d][u] = [st |-> "pin", a |-> a, fin |-> FALSE]]
    /\ gd' = [gd EXCEPT ![u] = "commit"]
    /\ ca' = [ca EXCEPT ![u] = a]
    /\ took' = [took EXCEPT ![u][d] = @ + 1]
    /\ UNCHANGED <<mk, fate, fa, gone, placed, noCom, fmax>>

Fence(u, a, fin) ==
    LET d == D[u]
        e == dec[d][u] IN
    /\ a \in A
    /\ u \notin gone[d]
    /\ \/ e.st = "none"
       \/ e.st = "fenced" /\ (e.a < a \/ (fin /\ ~e.fin))
    /\ dec' = [dec EXCEPT ![d][u] = [st |-> "fenced", a |-> IF e.a > a THEN e.a ELSE a,
                                      fin |-> e.fin \/ fin]]
    /\ fmax' = [fmax EXCEPT ![u] = IF fmax[u] > a THEN fmax[u] ELSE a]
    /\ UNCHANGED <<bal, mk, fate, fa, gone, placed, noCom, gd, ca, took>>

CommitFact(u, a) == dec[D[u]][u].st \in {"pin", "took"} /\ dec[D[u]][u].a = a
AbortFact(u, a) ==
    \/ dec[D[u]][u].st = "fenced" /\ (dec[D[u]][u].fin \/ dec[D[u]][u].a >= a)
    \/ dec[D[u]][u].st = "R"
    \/ u \in gone[D[u]] /\ dec[D[u]][u].st = "none"
    \/ \E k \in Others(u) : fate[k][u] = "R"
    \/ noCom[u][a]

GiveUp(u, a) ==
    /\ a \in A
    /\ a = 1 \/ fmax[u] >= a - 1
    /\ ~noCom[u][a]
    /\ ~(gd[u] = "commit" /\ ca[u] = a) \/ "giveup" \in Off
    /\ noCom' = [noCom EXCEPT ![u][a] = TRUE]
    /\ UNCHANGED <<bal, mk, fate, fa, dec, gone, placed, gd, ca, took, fmax>>

Resolve(u, a, out, k) ==
    /\ k \in Others(u)
    /\ a \in A
    /\ IF out = "commit" THEN CommitFact(u, a) ELSE AbortFact(u, a)
    /\ mk[k][u] # 0
    /\ \/ /\ out = "commit" /\ mk[k][u] = a
          /\ bal' = [bal EXCEPT ![k] = @ + Amt[u][k]]
          /\ mk' = [mk EXCEPT ![k][u] = 0]
          /\ fate' = [fate EXCEPT ![k][u] = "took"]
          /\ took' = [took EXCEPT ![u][k] = @ + 1]
          /\ fa' = [fa EXCEPT ![k][u] = 0]
       \/ /\ \/ out = "abort" /\ mk[k][u] <= a
             \/ out = "commit" /\ mk[k][u] < a
          /\ mk' = [mk EXCEPT ![k][u] = 0]
          /\ fate' = [fate EXCEPT ![k][u] = "aborted"]
          /\ fa' = [fa EXCEPT ![k][u] = mk[k][u]]
          /\ UNCHANGED <<bal, took>>
    /\ UNCHANGED <<dec, gone, placed, noCom, gd, ca, fmax>>

Drop(u) ==
    LET d == D[u] IN
    /\ dec[d][u].st = "pin"
    /\ \/ \A k \in Others(u) : mk[k][u] = 0 /\ (fate[k][u] # "none" \/ u \in gone[k])
       \/ "drop" \in Off
    /\ dec' = [dec EXCEPT ![d][u].st = "took"]
    /\ UNCHANGED <<bal, mk, fate, fa, gone, placed, noCom, gd, ca, took, fmax>>

Forget(k, u) ==
    /\ mk[k][u] = 0
    /\ dec[k][u].st # "pin"
    /\ fate[k][u] # "none" \/ dec[k][u].st # "none"
    /\ gone' = [gone EXCEPT ![k] = @ \cup {u}]
    /\ fate' = [fate EXCEPT ![k][u] = "none"]
    /\ fa' = [fa EXCEPT ![k][u] = 0]
    /\ dec' = [dec EXCEPT ![k][u] = NoDec]
    /\ UNCHANGED <<bal, mk, placed, noCom, gd, ca, took, fmax>>

Next ==
    \/ \E u \in U, a \in A, k \in K : Tent(u, a, k)
    \/ \E u \in U, a \in A : Commit(u, a) \/ GiveUp(u, a)
    \/ \E u \in U, a \in A, fin \in BOOLEAN : Fence(u, a, fin)
    \/ \E u \in U, a \in A, k \in K, out \in {"commit", "abort"} : Resolve(u, a, out, k)
    \/ \E u \in U : Drop(u)
    \/ \E k \in K, u \in U : Forget(k, u)

Spec == Init /\ [][Next]_vars

Conservation == ConsV(bal, gd, ca, mk) = Total

AllOrNone ==
    \A u \in U :
        /\ \A k \in K : took[u][k] <= 1
        /\ gd[u] # "commit" => \A k \in K : took[u][k] = 0
        /\ gd[u] = "commit" =>
              \A k \in K : IF k \in Legs(u) THEN took[u][k] = 1 \/ mk[k][u] = ca[u] ELSE took[u][k] = 0

AtMostOnce == \A u \in U, k \in K : took[u][k] <= 1

NonNeg == \A k \in K : Bal(k) >= 0

TypeOK ==
    /\ bal \in [K -> Int]
    /\ mk \in [K -> [U -> 0..MaxA]]
    /\ fate \in [K -> [U -> {"none", "took", "aborted", "R"}]]
    /\ fa \in [K -> [U -> 0..MaxA]]
    /\ dec \in [K -> [U -> [st : {"none", "pin", "took", "fenced", "R"}, a : 0..MaxA, fin : BOOLEAN]]]
    /\ gone \in [K -> SUBSET U]
    /\ placed \in [U -> [A -> SUBSET K]]
    /\ noCom \in [U -> [A -> BOOLEAN]]
    /\ gd \in [U -> {"none", "commit"}]
    /\ ca \in [U -> 0..MaxA]
    /\ took \in [U -> [K -> 0..2]]
    /\ fmax \in [U -> 0..MaxA]

MarkPlaced == \A k \in K, u \in U :
    mk[k][u] # 0 => k \in Others(u) /\ mk[k][u] \in A /\ k \in placed[u][mk[k][u]] /\ u \notin gone[k]
DecOnD == \A k \in K, u \in U : dec[k][u].st # "none" => k = D[u]
FateOnLegs == \A k \in K, u \in U : fate[k][u] # "none" => k \in Others(u)
CommitStays == \A u \in U :
    gd[u] = "commit" =>
        /\ ca[u] \in A
        /\ \/ dec[D[u]][u].st \in {"pin", "took"} /\ dec[D[u]][u].a = ca[u]
           \/ u \in gone[D[u]] /\ dec[D[u]][u].st = "none" /\ \A k \in Others(u) : mk[k][u] = 0
PinIsCommit == \A u \in U :
    /\ dec[D[u]][u].st \in {"pin", "took"} => gd[u] = "commit" /\ ca[u] = dec[D[u]][u].a
    /\ dec[D[u]][u].st = "took" => \A k \in Others(u) : mk[k][u] = 0
MarksFollow == \A u \in U :
    gd[u] = "commit" => \A k \in Others(u) :
        /\ mk[k][u] \in {0, ca[u]}
        /\ (mk[k][u] = 0) = (took[u][k] = 1)
FenceMax == \A u \in U :
    /\ dec[D[u]][u].st = "fenced" => dec[D[u]][u].a = fmax[u] /\ fmax[u] \in A
    /\ gd[u] = "commit" => fmax[u] < ca[u]
    /\ \A k \in K : mk[k][u] <= fmax[u] + 1
    /\ \A a \in A : placed[u][a] # {} => a <= fmax[u] + 1
GiveUpHolds == \A u \in U, a \in A : noCom[u][a] => ~(gd[u] = "commit" /\ ca[u] = a)
RStops == \A u \in U : (\E k \in Others(u) : fate[k][u] = "R") => gd[u] # "commit"
TookFate == \A u \in U : \A k \in Others(u) : took[u][k] = 1 => fate[k][u] = "took" \/ u \in gone[k]

DecShape == \A k \in K, u \in U :
    /\ dec[k][u].st # "R"
    /\ dec[k][u].st = "none" => dec[k][u].a = 0 /\ ~dec[k][u].fin
    /\ dec[k][u].st \in {"pin", "took"} => ~dec[k][u].fin /\ dec[k][u].a \in A
NoFenceNoMax == \A u \in U :
    dec[D[u]][u].st = "none" /\ u \notin gone[D[u]] => fmax[u] = 0 /\ gd[u] = "none"
FateShape == \A k \in K, u \in U :
    /\ fate[k][u] = "took" => gd[u] = "commit" /\ took[u][k] = 1
    /\ fate[k][u] = "aborted" => fa[k][u] \in A
    /\ fate[k][u] # "aborted" => fa[k][u] = 0
MarkVsFate == \A k \in K, u \in U :
    mk[k][u] # 0 => fate[k][u] = "none" \/ (fate[k][u] = "aborted" /\ fa[k][u] < mk[k][u])

GoneClean == \A k \in K, u \in U :
    u \in gone[k] => fate[k][u] = "none" /\ mk[k][u] = 0 /\ dec[k][u] = NoDec
AttemptsStarted == \A u \in U :
    /\ \A a \in A : noCom[u][a] => a <= fmax[u] + 1
    /\ \A k \in K : fa[k][u] <= fmax[u] + 1
    /\ gd[u] = "commit" => Others(u) \subseteq placed[u][ca[u]]
PlacedStays == \A u \in U, a \in A : \A k \in placed[u][a] :
    \/ mk[k][u] >= a
    \/ fate[k][u] \in {"took", "R"}
    \/ fate[k][u] = "aborted" /\ fa[k][u] >= a
    \/ u \in gone[k]
RPlaced == \A u \in U, a \in A, k \in K :
    fate[k][u] = "R" /\ k \in placed[u][a] => fmax[u] >= a
Dead(u, a) ==
    \/ fmax[u] >= a
    \/ noCom[u][a]
    \/ dec[D[u]][u].st = "fenced" /\ dec[D[u]][u].fin
    \/ u \in gone[D[u]]
    \/ \E j \in Others(u) : j \notin placed[u][a] /\ (fate[j][u] = "R" \/ u \in gone[j])
PlacedLive == \A u \in U, a \in A : \A k \in placed[u][a] :
    mk[k][u] = a \/ gd[u] = "commit" \/ Dead(u, a)

LowOK == \A k \in K : LowOn(k) >= 0

IndInv ==
    /\ TypeOK
    /\ Conservation
    /\ AllOrNone
    /\ MarkPlaced /\ DecOnD /\ FateOnLegs /\ CommitStays /\ PinIsCommit /\ MarksFollow
    /\ FenceMax /\ GiveUpHolds /\ RStops /\ TookFate
    /\ DecShape /\ NoFenceNoMax /\ FateShape /\ MarkVsFate
    /\ GoneClean /\ AttemptsStarted /\ PlacedStays /\ RPlaced /\ PlacedLive
    /\ LowOK /\ NonNeg

====
