-------------------------------- MODULE TxCut --------------------------------
\* TxCut is a Reset (cuts 3.1, 3.3, 5; record 4) beside the transaction
\* design, at the level of landings as TxAbs and TxBuild are: each action
\* is one write that lands on one key, so stale reads, lost answers, late
\* landings, reruns and helpers are interleavings.
\*
\* One cut key k0 and one decider key d. Uses move money between them by
\* delta legs: an escrow mark on k0, the decider's leg applied at the
\* commit on d. Credits land on k0 beside a gate (cuts 3.3: every write
\* but a Tent lands beside it). Cuts are timed names with stamps; any
\* number of sends of each cut land, from its cutter or from a helper. The
\* cut op in Step, first rule that applies: kept in K (took); its stamp at
\* or below hk (forgotten); another cut's gate (gatedBy); marks stand
\* (place the gate if none, report marks); else cut: name the money the
\* key held in L, blank the state, raise c, keep the name in K, which
\* holds Kcut names and raises hk over the one it drops, and clear the
\* gate. The cutter fences each mark's decider (a non-final fence) and
\* resolves the mark by what the decider says. A gate W[cut] old is
\* dropped, raising hk (cuts 3.1, record step 7).
\*
\* Left out: builds and levels (TxBuild), the fold of L (money is named in
\* events only; the fold is exact by its own construction), exclusive
\* marks and post diffs (a stored diff applies like an escrow amount),
\* pinned records (a Reset keeps them; the decider is another key here),
\* and attempts (the fence of a cut is not final, so a fenced use retries
\* under a new attempt, which is a new use here).
EXTENDS Integers, FiniteSets

CONSTANTS
    U,          \* uses
    Amt,        \* Amt[u]: u's leg on k0; the decider's leg is -Amt[u]
    Cuts,       \* cut names
    St,         \* St[n]: the stamp of cut n
    Kcut,       \* names the cut room K keeps
    Start0,     \* money on k0 at the start
    StartD,     \* money on d at the start
    MaxEd,      \* credits of 1 that may land on k0
    FixGate,    \* a cut lands only with no mark standing, placing a gate when marks stand
    FixKeep,    \* a cut whose name is in K reports took and cuts nothing
    FixNameNow  \* the cut names the money the key holds in the cut's own write

VARIABLES
    g0,     \* money on k0
    gD,     \* money on d
    mk,     \* mk[u]: u's escrow mark on k0: [on, amt, c] with c the cut count when it was placed
    tent,   \* tent[u]: "none", "mine"
    dec,    \* dec[u]: u's decision on d: "none", "commit", "abort"
    G,      \* the gate: [n, g], n = "none" when no gate stands; g is the money read when it was placed
    K,      \* the cut room: names of cuts that took
    hk,     \* the cut horizon
    c,      \* the cut count
    L,      \* the loss room: [n, amt, c] events, c the cut count before the cut
    eds,    \* credits landed on k0
    made,   \* ghost: money made by credits
    lost,   \* ghost: money the cuts destroyed, read at the cut
    took,   \* ghost: took[n], how many times cut n took effect
    late,   \* ghost: a leg that took effect on a state after a cut its mark did not see
    tentG,  \* ghost: a Tent landed while a gate stood
    gs      \* ghost: the cuts that ever placed a gate

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

\* Tent (transaction 3.2, cuts 3.3): a Tent that meets a gate is gated and lands nothing; it backs
\* off and finishes the gate (a Cut below). With the gate off, a Tent lands beside it.
Tent(u) ==
    /\ tent[u] = "none" /\ dec[u] = "none"
    /\ G.n = "none" \/ ~FixGate
    /\ mk' = [mk EXCEPT ![u] = [on |-> TRUE, amt |-> Amt[u], c |-> c]]
    /\ tent' = [tent EXCEPT ![u] = "mine"]
    /\ tentG' = (tentG \/ G.n # "none")
    /\ UNCHANGED <<g0, gD, dec, G, K, hk, c, L, eds, made, lost, took, late, gs>>

\* Commit (3.3) on d: the decider's leg takes effect.
Commit(u) ==
    /\ tent[u] = "mine" /\ dec[u] = "none"
    /\ dec' = [dec EXCEPT ![u] = "commit"]
    /\ gD' = gD - Amt[u]
    /\ UNCHANGED <<g0, mk, tent, G, K, hk, c, L, eds, made, lost, took, late, tentG, gs>>

\* A fence on d (the cutter's, a touch's, or the coordinator giving up): a presumed abort.
Fence(u) ==
    /\ dec[u] = "none"
    /\ dec' = [dec EXCEPT ![u] = "abort"]
    /\ UNCHANGED <<g0, gD, mk, tent, G, K, hk, c, L, eds, made, lost, took, late, tentG, gs>>

\* Resolve (3.4) on k0, carried by the cut's next send or by the coordinator: a commit applies the
\* escrow amount, as data.
Resolve(u) ==
    /\ mk[u].on /\ dec[u] # "none"
    /\ g0' = IF dec[u] = "commit" THEN g0 + mk[u].amt ELSE g0
    /\ late' = (late \/ (dec[u] = "commit" /\ mk[u].c # c))
    /\ mk' = [mk EXCEPT ![u] = NoMk]
    /\ UNCHANGED <<gD, tent, dec, G, K, hk, c, L, eds, made, lost, took, tentG, gs>>

\* A credit of 1 on k0, a one key op; it lands beside a gate (cuts 6).
Credit ==
    /\ eds < MaxEd
    /\ g0' = g0 + 1 /\ made' = made + 1 /\ eds' = eds + 1
    /\ UNCHANGED <<gD, mk, tent, dec, G, K, hk, c, L, lost, took, late, tentG, gs>>

\* One landing of cut n's op (cuts 3.1), from its cutter or a helper.
Cut(n) ==
    \/ /\ n \in K /\ FixKeep                                      \* rule 1: kept, took
       /\ UNCHANGED vars
    \/ /\ ~(n \in K /\ FixKeep)
       /\ St[n] <= hk                                             \* rule 3: forgotten
       /\ UNCHANGED vars
    \/ /\ ~(n \in K /\ FixKeep) /\ St[n] > hk
       /\ G.n \notin {"none", n}                                  \* rule 7: gatedBy
       /\ UNCHANGED vars
    \/ /\ ~(n \in K /\ FixKeep) /\ St[n] > hk /\ G.n \in {"none", n}
       /\ Marks # {} /\ FixGate                                   \* rule 8: marks
       /\ G' = IF G.n = "none" THEN [n |-> n, g |-> g0] ELSE G
       /\ gs' = gs \cup {n}
       /\ UNCHANGED <<g0, gD, mk, tent, dec, K, hk, c, L, eds, made, lost, took, late, tentG>>
    \/ /\ ~(n \in K /\ FixKeep) /\ St[n] > hk /\ G.n \in {"none", n}
       /\ Marks = {} \/ ~FixGate                                  \* rule 9: cut
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

\* Record step 7: a gate W[cut] past its stamp is dropped, and hk rises to its stamp, so the cut never
\* happens.
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

\* The properties.

\* Committed legs not yet resolved on k0.
Held == LET S == {u \in U : mk[u].on /\ dec[u] = "commit"} IN
        IF S = {} THEN 0 ELSE LET f[T \in SUBSET S] == IF T = {} THEN 0
                                                     ELSE LET v == CHOOSE x \in T : TRUE IN mk[v].amt + f[T \ {v}]
                              IN f[S]
Named == LET f[T \in SUBSET L] == IF T = {} THEN 0 ELSE LET e == CHOOSE x \in T : TRUE IN e.amt + f[T \ {e}]
         IN f[L]

\* S1 with S2's namings: money on the keys, committed legs in flight and money the cuts destroyed
\* is the money at the start and what credits made.
Conservation == g0 + gD + Held + lost = Start0 + StartD + made
\* S2: every cut names exactly the money it destroyed.
NamedExact == Named = lost
\* S10: no leg takes effect on a state after a cut its mark was not judged under.
NoLateLeg == ~late
\* S5 for a cut: each cut name takes effect at most once.
CutOnce == \A n \in Cuts : took[n] <= 1
\* The gate: no Tent lands while it stands.
NoTentBesideGate == ~tentG

TypeOK ==
    /\ g0 \in Int /\ gD \in Int
    /\ G.n \in Cuts \cup {"none"}
    /\ K \subseteq Cuts /\ Cardinality(K) <= Kcut
    /\ c \in Nat

\* Probes: a cut takes effect after a gate made it wait, and a credit is named by a cut.
NoGatedCut == ~\E n \in gs : took[n] = 1
NoCutAfterCredit == ~(eds > 0 /\ c > 0 /\ lost > Start0)
\* A cut that took after an older cut dropped from K, so hk rose (the second cut evicts the first).
NoEviction == hk = 0
=============================================================================
