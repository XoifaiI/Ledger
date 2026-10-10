-------------------------------- MODULE TxAbs --------------------------------
\* TxAbs is the transaction design at the level of landings,
\* for the proofs of design rule 13: S1, S4 and S5 by an inductive
\* invariant that Apalache checks and TLAPS proves.
\*
\* Each action is one write that lands on one key, atomically, as the
\* record's Step does on the version it read (D2, D14). What a server
\* knows of another key enters only as a fact that stays true once it
\* holds: a mark was placed, a decision stands on the decider, a name is
\* forgotten there. So a stale read, a lost answer, a late landing and a
\* rerun are all covered: each can only enable an action whose guard is
\* such a fact, and every such action is in Next. Tx.tla checks the same
\* design with Env's faults at the level of requests.
\*
\* A use u has legs, each a key and a signed amount, which sum to 0, and
\* one leg key is its decider D(u). Uses move money only (field delta
\* legs). Game op legs, rooms, erase and the orphan rule are Tx.tla's.
\*
\* Per key k: bal[k] the money, mk[k][u] the attempt of u's mark (0 none),
\* fate[k][u] the leg fate ("none", "took", "aborted", "R"), fa[k][u] the
\* attempt an aborted fate names, dec[k][u] u's decision on its decider,
\* gone[k] the names k forgot (the horizon: a forgotten name has no entry
\* and gets none again). Ghosts: placed[u][a] the leg keys where a mark of
\* (u, a) landed, noCom[u][a] a coordinator gave up (u, a) by its own
\* evidence and sends no Commit of it, gd[u] the decision, ca[u] the
\* attempt that committed, took[u][k] the effects of u's leg on k, fmax[u]
\* the highest attempt a fence of u ever landed at, which a coordinator
\* must have seen before it starts the next attempt (3.6).
EXTENDS Integers, FiniteSets, FiniteSetsExt

CONSTANTS
    \* @type: Set(Str);
    K,
    \* @type: Set(Str);
    U,
    \* @type: Int;
    MaxA,
    \* @type: Str -> (Str -> Int);
    Amt,        \* Amt[u][k]: the amount of u's leg on k, 0 when u has no leg there
    \* @type: Str -> Str;
    D,          \* D[u]: the decider
    \* @type: Str -> Int;
    Start,      \* Start[k]: the money on k at the start
    \* @type: Set(Str);
    Off         \* the guards a control turns off: {} is the design

VARIABLES
    \* @type: Str -> Int;
    bal,
    \* @type: Str -> (Str -> Int);
    mk,
    \* @type: Str -> (Str -> Str);
    fate,
    \* @type: Str -> (Str -> Int);
    fa,
    \* @type: Str -> (Str -> { st: Str, a: Int, fin: Bool });
    dec,
    \* @type: Str -> Set(Str);
    gone,
    \* @type: Str -> (Int -> Set(Str));
    placed,
    \* @type: Str -> (Int -> Bool);
    noCom,
    \* @type: Str -> Str;
    gd,
    \* @type: Str -> Int;
    ca,
    \* @type: Str -> (Str -> Int);
    took,
    \* @type: Str -> Int;
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

\* Money, summed over keys. One fold, so TLC, Apalache and TLAPS take it.

\* @type: (Set(Str), Str => Int) => Int;
Sum(S, f(_)) == FoldSet(LAMBDA x, acc : f(x) + acc, 0, S)

\* A use moves money only: its legs sum to 0.
ASSUME LegsBalance == \A u \in U : Sum(K, LAMBDA k : Amt[u][k]) = 0

\* Each money term is a constant operator of the state it reads (the ...V forms), so the term in the
\* next state is the same operator of the primed variables, which TLAPS needs through Sum's LAMBDA.

\* The escrow amount of u's leg on k that already took effect at the commit (S4's note).
\* @type: (Str -> Str, Str -> Int, Str -> (Str -> Int), Str, Str) => Int;
HeldV(g, c, m, k, u) == IF g[u] = "commit" /\ m[k][u] = c[u] /\ m[k][u] # 0 THEN Amt[u][k] ELSE 0
\* @type: (Str -> Int, Str -> Str, Str -> Int, Str -> (Str -> Int), Str) => Int;
BalV(b, g, c, m, k) == b[k] + Sum(U, LAMBDA u : HeldV(g, c, m, k, u))
\* @type: (Str -> Int, Str -> Str, Str -> Int, Str -> (Str -> Int)) => Int;
ConsV(b, g, c, m) == Sum(K, LAMBDA k : BalV(b, g, c, m, k))
Held(k, u) == HeldV(gd, ca, mk, k, u)
Bal(k) == BalV(bal, gd, ca, mk, k)
Total == Sum(K, LAMBDA k : Start[k])

\* The least the money on k can end at: bal less every debit set aside (section 3.2).
\* @type: (Str -> (Str -> Int), Str, Str) => Int;
NegV(m, k, u) == IF m[k][u] # 0 /\ Amt[u][k] < 0 THEN Amt[u][k] ELSE 0
\* @type: (Str -> Int, Str -> (Str -> Int), Str) => Int;
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

\* Tent(u, a) lands on leg key k (3.2): a mark of an older attempt is replaced; a fate of u stops it
\* but an aborted one of an older attempt; a forgotten name stops it; a debit not covered by the
\* least the key can end at writes R.
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

\* Commit(u, a) lands on the decider (3.3). The coordinator sends it only once every Tent of (u, a)
\* reported mine, so each leg key had its mark placed; it lands only if no decision of u stops it,
\* the name is not forgotten, and the decider's own leg is covered.
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

\* Fence(u, a, fin) lands on the decider (3.4): it writes a fence, or raises one of a lower attempt.
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

\* The facts a Resolve may rest on (3.4), each true on the decider or on a leg key now, and each one
\* that stays true: a commit of (u, a); a fence of u at a or later, or a final one; the decider forgot
\* u; an R on any leg key; or the coordinator's own evidence that it sends no Commit of (u, a).
CommitFact(u, a) == dec[D[u]][u].st \in {"pin", "took"} /\ dec[D[u]][u].a = a
AbortFact(u, a) ==
    \/ dec[D[u]][u].st = "fenced" /\ (dec[D[u]][u].fin \/ dec[D[u]][u].a >= a)
    \/ dec[D[u]][u].st = "R"
    \/ u \in gone[D[u]] /\ dec[D[u]][u].st = "none"
    \/ \E k \in Others(u) : fate[k][u] = "R"
    \/ noCom[u][a]

\* A coordinator that sent no Commit of (u, a) gives it up by its own evidence (3.4).
GiveUp(u, a) ==
    /\ a \in A
    /\ a = 1 \/ fmax[u] >= a - 1
    /\ ~noCom[u][a]
    /\ ~(gd[u] = "commit" /\ ca[u] = a) \/ "giveup" \in Off
    /\ noCom' = [noCom EXCEPT ![u][a] = TRUE]
    /\ UNCHANGED <<bal, mk, fate, fa, dec, gone, placed, gd, ca, took, fmax>>

\* Resolve(u, a, out) lands on leg key k (3.4).
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

\* A drop (3.5): the pinned record leaves once every other leg key of u is resolved: it holds no
\* mark of u and a fate of u or has forgotten it.
Drop(u) ==
    LET d == D[u] IN
    /\ dec[d][u].st = "pin"
    /\ \/ \A k \in Others(u) : mk[k][u] = 0 /\ (fate[k][u] # "none" \/ u \in gone[k])
       \/ "drop" \in Off
    /\ dec' = [dec EXCEPT ![d][u].st = "took"]
    /\ UNCHANGED <<bal, mk, fate, fa, gone, placed, noCom, gd, ca, took, fmax>>

\* A key forgets u (record steps 7 and 8): its timed entries of u go, and the name is at or below the
\* horizon. A mark and a pinned record are never in the timed room.
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

\* The properties.

\* S1: money on keys, with committed legs not yet resolved, is what it was at the start.
Conservation == ConsV(bal, gd, ca, mk) = Total

\* S4
AllOrNone ==
    \A u \in U :
        /\ \A k \in K : took[u][k] <= 1
        /\ gd[u] # "commit" => \A k \in K : took[u][k] = 0
        /\ gd[u] = "commit" =>
              \A k \in K : IF k \in Legs(u) THEN took[u][k] = 1 \/ mk[k][u] = ca[u] ELSE took[u][k] = 0

\* S5: every name here carries a first send time, so each takes effect at most once on each key.
AtMostOnce == \A u \in U, k \in K : took[u][k] <= 1

\* The game's rule: no key's money, counting committed legs, goes below 0.
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

\* The inductive invariant (the proof plan, rows S1, S4, S5).
\* Each lemma is named for the fact the plan asks of S4: marks follow the
\* decision, the decision stays while a mark reads it, a commit follows
\* every placed mark. The rest pin down attempts and fences.

\* A mark stands only on a leg key other than the decider, at an attempt that was placed there.
MarkPlaced == \A k \in K, u \in U :
    mk[k][u] # 0 => k \in Others(u) /\ mk[k][u] \in A /\ k \in placed[u][mk[k][u]] /\ u \notin gone[k]
\* A decision entry lives only on the use's decider; a fate only on its other leg keys.
DecOnD == \A k \in K, u \in U : dec[k][u].st # "none" => k = D[u]
FateOnLegs == \A k \in K, u \in U : fate[k][u] # "none" => k \in Others(u)
\* The decision stays while a mark reads it (DecisionStays): a commit is pinned or taken on D, or D
\* forgot u only once every mark of u is gone.
CommitStays == \A u \in U :
    gd[u] = "commit" =>
        /\ ca[u] \in A
        /\ \/ dec[D[u]][u].st \in {"pin", "took"} /\ dec[D[u]][u].a = ca[u]
           \/ u \in gone[D[u]] /\ dec[D[u]][u].st = "none" /\ \A k \in Others(u) : mk[k][u] = 0
\* A pinned or taken record is a commit; a taken one has no mark left.
PinIsCommit == \A u \in U :
    /\ dec[D[u]][u].st \in {"pin", "took"} => gd[u] = "commit" /\ ca[u] = dec[D[u]][u].a
    /\ dec[D[u]][u].st = "took" => \A k \in Others(u) : mk[k][u] = 0
\* Marks follow the decision (MarksFollowDecision): after a commit, a mark stands only at the attempt
\* that committed, and a leg key without one took the leg.
MarksFollow == \A u \in U :
    gd[u] = "commit" => \A k \in Others(u) :
        /\ mk[k][u] \in {0, ca[u]}
        /\ (mk[k][u] = 0) = (took[u][k] = 1)
\* Fences: the decider's fence is the highest attempt fenced, no commit follows a fence of its
\* attempt, and an attempt runs only after the one before it was fenced.
FenceMax == \A u \in U :
    /\ dec[D[u]][u].st = "fenced" => dec[D[u]][u].a = fmax[u] /\ fmax[u] \in A
    /\ gd[u] = "commit" => fmax[u] < ca[u]
    /\ \A k \in K : mk[k][u] <= fmax[u] + 1
    /\ \A a \in A : placed[u][a] # {} => a <= fmax[u] + 1
\* A use given up by its coordinator never commits at that attempt.
GiveUpHolds == \A u \in U, a \in A : noCom[u][a] => ~(gd[u] = "commit" /\ ca[u] = a)
\* An R on a leg key stops every commit of the use.
RStops == \A u \in U : (\E k \in Others(u) : fate[k][u] = "R") => gd[u] # "commit"
\* A leg key that took the leg holds the fate took, or forgot the name.
TookFate == \A u \in U : \A k \in Others(u) : took[u][k] = 1 => fate[k][u] = "took" \/ u \in gone[k]

\* The shapes TxAbs writes: no decision entry is R, and each entry's fields match its kind.
DecShape == \A k \in K, u \in U :
    /\ dec[k][u].st # "R"
    /\ dec[k][u].st = "none" => dec[k][u].a = 0 /\ ~dec[k][u].fin
    /\ dec[k][u].st \in {"pin", "took"} => ~dec[k][u].fin /\ dec[k][u].a \in A
\* A decider with no entry for u, that has not forgotten u, has seen no fence and no commit of it.
NoFenceNoMax == \A u \in U :
    dec[D[u]][u].st = "none" /\ u \notin gone[D[u]] => fmax[u] = 0 /\ gd[u] = "none"
\* A leg fate took is a leg that took at a commit; an aborted fate names its attempt.
FateShape == \A k \in K, u \in U :
    /\ fate[k][u] = "took" => gd[u] = "commit" /\ took[u][k] = 1
    /\ fate[k][u] = "aborted" => fa[k][u] \in A
    /\ fate[k][u] # "aborted" => fa[k][u] = 0
\* A mark stands beside no fate, or beside an aborted fate of an older attempt.
MarkVsFate == \A k \in K, u \in U :
    mk[k][u] # 0 => fate[k][u] = "none" \/ (fate[k][u] = "aborted" /\ fa[k][u] < mk[k][u])

\* A forgotten name has nothing left on the key.
GoneClean == \A k \in K, u \in U :
    u \in gone[k] => fate[k][u] = "none" /\ mk[k][u] = 0 /\ dec[k][u] = NoDec
\* Nothing names an attempt that has not started: each attempt after the first starts only once the
\* one before it was fenced, and a commit's attempt had every leg key's mark placed.
AttemptsStarted == \A u \in U :
    /\ \A a \in A : noCom[u][a] => a <= fmax[u] + 1
    /\ \A k \in K : fa[k][u] <= fmax[u] + 1
    /\ gd[u] = "commit" => Others(u) \subseteq placed[u][ca[u]]
\* A mark placed at attempt a stays at a or a later attempt until a fate of a or later replaces it,
\* and the fate stays until the key forgets the name.
PlacedStays == \A u \in U, a \in A : \A k \in placed[u][a] :
    \/ mk[k][u] >= a
    \/ fate[k][u] \in {"took", "R"}
    \/ fate[k][u] = "aborted" /\ fa[k][u] >= a
    \/ u \in gone[k]
\* An R on a key that held a mark of attempt a came from a later attempt, so a was fenced.
RPlaced == \A u \in U, a \in A, k \in K :
    fate[k][u] = "R" /\ k \in placed[u][a] => fmax[u] >= a
\* The facts that stop every later Commit(u, a) for good.
Dead(u, a) ==
    \/ fmax[u] >= a
    \/ noCom[u][a]
    \/ dec[D[u]][u].st = "fenced" /\ dec[D[u]][u].fin
    \/ u \in gone[D[u]]
    \/ \E j \in Others(u) : j \notin placed[u][a] /\ (fate[j][u] = "R" \/ u \in gone[j])
\* A commit follows every placed mark (CommitAfterAll): a mark of attempt a leaves its key before a
\* decision only once attempt a can never commit, so a commit finds every mark of its attempt standing.
PlacedLive == \A u \in U, a \in A : \A k \in placed[u][a] :
    mk[k][u] = a \/ gd[u] = "commit" \/ Dead(u, a)

\* Every debit set aside is covered: the least each key can end at is not below 0 (3.2).
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

=============================================================================
