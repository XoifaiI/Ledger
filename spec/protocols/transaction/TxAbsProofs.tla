----------------------------- MODULE TxAbsProofs -----------------------------
\* TLAPS proofs of S4 (AllOrNone) and S5 (AtMostOnce) for TxAbs, for any
\* finite keys and uses, any amounts whose legs sum to 0, and any number
\* of attempts: Core, the part of IndInv with no sum in it, holds
\* initially and is kept by every action. Apalache checks the whole of
\* IndInv on two instances (ApaTxAbs); this proves the part S4 and S5 rest
\* on for every instance. Written by genproofs.py.
\*
\* Design is the assumption that no guard is off: the controls of
\* ApaTxAbs turn guards off, and the proof is of the design.
EXTENDS TxAbs, TLAPS

ASSUME Design == Off = {}

Core ==
    /\ TypeOK
    /\ AllOrNone
    /\ MarkPlaced
    /\ DecOnD
    /\ FateOnLegs
    /\ CommitStays
    /\ PinIsCommit
    /\ MarksFollow
    /\ FenceMax
    /\ GiveUpHolds
    /\ RStops
    /\ TookFate
    /\ DecShape
    /\ NoFenceNoMax
    /\ FateShape
    /\ MarkVsFate
    /\ GoneClean
    /\ AttemptsStarted
    /\ PlacedStays
    /\ RPlaced
    /\ PlacedLive

\* The keys a use names are keys.
LEMMA InK == \A u \in U : Legs(u) \subseteq K /\ Others(u) \subseteq K /\ D[u] \in K
BY AbsConstants DEF Legs, Others

LEMMA InitCore == Init => Core
BY Design, AbsConstants, InK DEF Init, Core, TypeOK, AllOrNone, MarkPlaced, DecOnD, FateOnLegs, CommitStays, PinIsCommit, MarksFollow, FenceMax, GiveUpHolds, RStops, TookFate, DecShape, NoFenceNoMax, FateShape, MarkVsFate, GoneClean, AttemptsStarted, PlacedStays, RPlaced, PlacedLive, Dead, Others, NoDec, A

\* A Tent never lands for a use that committed.
LEMMA TentUncommitted ==
    ASSUME Core, NEW u \in U, NEW a \in A, NEW k \in K, Tent(u, a, k)
    PROVE  gd[u] # "commit"
<1> SUFFICES ASSUME gd[u] = "commit" PROVE FALSE OBVIOUS
<1>1. k \in Others(u) /\ mk[k][u] < a /\ (a = 1 \/ fmax[u] >= a - 1) /\ u \notin gone[k]
      /\ (fate[k][u] = "none" \/ fate[k][u] = "aborted")
  BY Design DEF Tent
<1>2. mk[k][u] \in {0, ca[u]} /\ ((mk[k][u] = 0) = (took[u][k] = 1)) BY <1>1 DEF Core, MarksFollow
<1>3. CASE mk[k][u] = 0
  BY <1>1, <1>2, <1>3 DEF Core, TookFate
<1>4. CASE mk[k][u] = ca[u]
  <2>1. ca[u] \in A /\ fmax[u] < ca[u] BY DEF Core, CommitStays, FenceMax
  <2>2. fmax[u] \in Nat /\ a \in Nat BY DEF Core, TypeOK, A
  <2> QED BY <1>1, <1>4, <2>1, <2>2 DEF A
<1> QED BY <1>2, <1>3, <1>4

\* A Commit of (u, a) finds u uncommitted and a mark of a on every leg key but the decider.
LEMMA CommitFinds ==
    ASSUME Core, NEW u \in U, NEW a \in A, Commit(u, a)
    PROVE  /\ gd[u] # "commit"
           /\ \A k \in Others(u) : mk[k][u] = a
           /\ mk[D[u]][u] = 0
<1>1. gd[u] # "commit"
  BY Design DEF Core, Commit, CommitStays, TypeOK
<1>2. ~Dead(u, a)
  BY Design, AbsConstants DEF Core, Commit, Dead, FenceMax, NoFenceNoMax, TypeOK, A
<1> QED BY <1>1, <1>2, Design DEF Core, Commit, PlacedLive

\* A Resolve of commit that takes a leg ends a mark of the committed attempt; any other Resolve ends
\* a mark that no commit counts.
LEMMA ResolveEnds ==
    ASSUME Core, NEW u \in U, NEW a \in A, NEW out \in {"commit", "abort"}, NEW k \in K,
           Resolve(u, a, out, k)
    PROVE  /\ out = "commit" /\ mk[k][u] = a => gd[u] = "commit" /\ ca[u] = a
           /\ ~(out = "commit" /\ mk[k][u] = a) => ~(gd[u] = "commit" /\ mk[k][u] = ca[u])
<1>0. mk[k][u] # 0 /\ k \in Others(u) BY DEF Resolve
<1>1. CASE out = "commit"
  <2>1. CommitFact(u, a) BY <1>1 DEF Resolve
  <2>2. gd[u] = "commit" /\ ca[u] = a BY <2>1 DEF CommitFact, Core, PinIsCommit
  <2> QED BY <1>1, <2>2
<1>2. CASE out = "abort"
  <2> SUFFICES ASSUME gd[u] = "commit", mk[k][u] = ca[u] PROVE FALSE BY <1>2
  <2>1. AbortFact(u, a) /\ mk[k][u] <= a BY <1>2 DEF Resolve
  <2>2. /\ ca[u] \in A /\ fmax[u] < ca[u]
        /\ \/ dec[D[u]][u].st \in {"pin", "took"} /\ dec[D[u]][u].a = ca[u]
           \/ u \in gone[D[u]] /\ dec[D[u]][u].st = "none" /\ \A j \in Others(u) : mk[j][u] = 0
    BY DEF Core, CommitStays, FenceMax
  <2>3. CASE dec[D[u]][u].st = "fenced" /\ (dec[D[u]][u].fin \/ dec[D[u]][u].a >= a)
    BY <2>2, <2>3
  <2>4. CASE dec[D[u]][u].st = "R"
    BY <2>2, <2>4
  <2>5. CASE u \in gone[D[u]] /\ dec[D[u]][u].st = "none"
    BY <2>2, <2>5, <1>0
  <2>6. CASE \E j \in Others(u) : fate[j][u] = "R"
    BY <2>6 DEF Core, RStops
  <2>7. CASE noCom[u][a]
    <3>1. ca[u] # a BY <2>7 DEF Core, GiveUpHolds
    <3>2. a <= fmax[u] + 1 BY <2>7 DEF Core, AttemptsStarted
    <3>3. fmax[u] \in Nat /\ a \in Nat /\ ca[u] \in Nat BY DEF Core, TypeOK, A
    <3> QED BY <2>1, <2>2, <3>1, <3>2, <3>3
  <2> QED BY <2>1, <2>3, <2>4, <2>5, <2>6, <2>7 DEF AbortFact
<1> QED BY <1>1, <1>2

LEMMA StutterCore == Core /\ UNCHANGED vars => Core'
BY DEF vars, Core, TypeOK, AllOrNone, MarkPlaced, DecOnD, FateOnLegs, CommitStays, PinIsCommit, MarksFollow, FenceMax, GiveUpHolds, RStops, TookFate, DecShape, NoFenceNoMax, FateShape, MarkVsFate, GoneClean, AttemptsStarted, PlacedStays, RPlaced, PlacedLive, Dead, Others, NoDec, A

LEMMA TentCore ==
    ASSUME Core, NEW u \in U, NEW a \in A, NEW k \in K, Tent(u, a, k)
    PROVE  Core'
<1> USE DEF Core
<1>0a. gd[u] # "commit"
  BY TentUncommitted
<1> USE <1>0a
<1>1. TypeOK'
  <2>1. bal' \in [K -> Int]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A
  <2>2. mk' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A
  <2>3. fate' \in [K -> [U -> {"none", "took", "aborted", "R"}]]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A
  <2>4. fa' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A
  <2>5. dec' \in [K -> [U -> [st : {"none", "pin", "took", "fenced", "R"}, a : 0..MaxA, fin : BOOLEAN]]]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A
  <2>6. gone' \in [K -> SUBSET U]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A
  <2>7. placed' \in [U -> [A -> SUBSET K]]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A
  <2>8. noCom' \in [U -> [A -> BOOLEAN]]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A
  <2>9. gd' \in [U -> {"none", "commit"}]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A
  <2>10. ca' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A
  <2>11. took' \in [U -> [K -> 0..2]]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A, AllOrNone
  <2>12. fmax' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF Tent, TypeOK, NoDec, A
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11, <2>12 DEF TypeOK
<1>2. AllOrNone'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, AllOrNone, TypeOK, Dead, Others, NoDec, A
<1>3. MarkPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, MarkPlaced, TypeOK, Dead, Others, NoDec, A
<1>4. DecOnD'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, DecOnD, TypeOK, Dead, Others, NoDec, A
<1>5. FateOnLegs'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, FateOnLegs, TypeOK, Dead, Others, NoDec, A
<1>6. CommitStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, CommitStays, TypeOK, Dead, Others, NoDec, A
<1>7. PinIsCommit'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, PinIsCommit, TypeOK, Dead, Others, NoDec, A
<1>8. MarksFollow'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, MarksFollow, TypeOK, Dead, Others, NoDec, A
<1>9. FenceMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, FenceMax, TypeOK, Dead, Others, NoDec, A
<1>10. GiveUpHolds'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, GiveUpHolds, TypeOK, Dead, Others, NoDec, A
<1>11. RStops'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, RStops, TypeOK, Dead, Others, NoDec, A
<1>12. TookFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, TookFate, TypeOK, Dead, Others, NoDec, A
<1>13. DecShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, DecShape, TypeOK, Dead, Others, NoDec, A
<1>14. NoFenceNoMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, NoFenceNoMax, TypeOK, Dead, Others, NoDec, A
<1>15. FateShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, FateShape, TypeOK, Dead, Others, NoDec, A
<1>16. MarkVsFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, MarkVsFate, TypeOK, Dead, Others, NoDec, A
<1>17. GoneClean'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, GoneClean, TypeOK, Dead, Others, NoDec, A
<1>18. AttemptsStarted'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, AttemptsStarted, TypeOK, Dead, Others, NoDec, A
<1>19. PlacedStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, PlacedStays, TypeOK, Dead, Others, NoDec, A
<1>20. RPlaced'
  <2> USE Design, AbsConstants, InK
  <2> SUFFICES ASSUME NEW uu \in U, NEW aa \in A, NEW kk \in K,
                      fate'[kk][uu] = "R", kk \in placed'[uu][aa]
               PROVE  fmax'[uu] >= aa
    BY DEF RPlaced
  <2>0. fmax' = fmax BY DEF Tent
  <2>1. CASE uu = u /\ kk = k
    <3>1. /\ placed' = placed /\ mk[k][u] < a /\ u \notin gone[k]
          /\ fate[k][u] = "none" \/ (fate[k][u] = "aborted" /\ fa[k][u] < a)
          /\ a = 1 \/ fmax[u] >= a - 1
      BY <2>1, Design DEF Tent
    <3>2. k \in placed[u][aa] BY <2>1, <3>1
    <3>3. \/ mk[k][u] >= aa
          \/ fate[k][u] \in {"took", "R"}
          \/ fate[k][u] = "aborted" /\ fa[k][u] >= aa
          \/ u \in gone[k]
      BY <3>2 DEF PlacedStays
    <3>0. mk[k][u] \in Nat /\ fa[k][u] \in Nat /\ fmax[u] \in Nat /\ a \in Nat /\ aa \in Nat /\ aa >= 1
      BY DEF TypeOK, A
    <3>4. aa < a
      <4>1. CASE mk[k][u] >= aa BY <3>0, <3>1, <4>1
      <4>2. CASE fate[k][u] \in {"took", "R"} BY <3>1, <4>2
      <4>3. CASE fate[k][u] = "aborted" /\ fa[k][u] >= aa BY <3>0, <3>1, <4>3
      <4>4. CASE u \in gone[k] BY <3>1, <4>4
      <4> QED BY <3>3, <4>1, <4>2, <4>3, <4>4
    <3> QED BY <2>1, <3>0, <3>1, <3>4, <2>0
  <2>2. CASE ~(uu = u /\ kk = k)
    <3>1. fate[kk][uu] = "R" /\ kk \in placed[uu][aa] BY <2>2 DEF Tent, TypeOK
    <3> QED BY <3>1, <2>0 DEF RPlaced
  <2> QED BY <2>1, <2>2
<1>21. PlacedLive'
  BY Design, AbsConstants, InK, SMTT(30) DEF Tent, PlacedLive, TypeOK, Dead, Others, NoDec, A
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9, <1>10, <1>11, <1>12, <1>13, <1>14, <1>15, <1>16, <1>17, <1>18, <1>19, <1>20, <1>21

LEMMA CommitCore ==
    ASSUME Core, NEW u \in U, NEW a \in A, Commit(u, a)
    PROVE  Core'
<1> USE DEF Core
<1>0a. gd[u] # "commit" /\ (\A kk \in Others(u) : mk[kk][u] = a) /\ mk[D[u]][u] = 0
  BY CommitFinds
<1> USE <1>0a
<1>1. TypeOK'
  <2>1. bal' \in [K -> Int]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A
  <2>2. mk' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A
  <2>3. fate' \in [K -> [U -> {"none", "took", "aborted", "R"}]]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A
  <2>4. fa' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A
  <2>5. dec' \in [K -> [U -> [st : {"none", "pin", "took", "fenced", "R"}, a : 0..MaxA, fin : BOOLEAN]]]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A
  <2>6. gone' \in [K -> SUBSET U]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A
  <2>7. placed' \in [U -> [A -> SUBSET K]]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A
  <2>8. noCom' \in [U -> [A -> BOOLEAN]]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A
  <2>9. gd' \in [U -> {"none", "commit"}]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A
  <2>10. ca' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A
  <2>11. took' \in [U -> [K -> 0..2]]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A, AllOrNone
  <2>12. fmax' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF Commit, TypeOK, NoDec, A
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11, <2>12 DEF TypeOK
<1>2. AllOrNone'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, AllOrNone, TypeOK, Dead, Others, NoDec, A
<1>3. MarkPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, MarkPlaced, TypeOK, Dead, Others, NoDec, A
<1>4. DecOnD'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, DecOnD, TypeOK, Dead, Others, NoDec, A
<1>5. FateOnLegs'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, FateOnLegs, TypeOK, Dead, Others, NoDec, A
<1>6. CommitStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, CommitStays, TypeOK, Dead, Others, NoDec, A
<1>7. PinIsCommit'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, PinIsCommit, TypeOK, Dead, Others, NoDec, A
<1>8. MarksFollow'
  BY Design, AbsConstants, InK, SMTT(120) DEF Commit, TypeOK, AllOrNone, MarkPlaced, DecOnD, FateOnLegs, CommitStays, PinIsCommit, MarksFollow, FenceMax, GiveUpHolds, RStops, TookFate, DecShape, NoFenceNoMax, FateShape, MarkVsFate, GoneClean, AttemptsStarted, PlacedStays, RPlaced, PlacedLive, Dead, Others, NoDec, A
<1>9. FenceMax'
  BY Design, AbsConstants, InK, SMTT(120) DEF Commit, TypeOK, AllOrNone, MarkPlaced, DecOnD, FateOnLegs, CommitStays, PinIsCommit, MarksFollow, FenceMax, GiveUpHolds, RStops, TookFate, DecShape, NoFenceNoMax, FateShape, MarkVsFate, GoneClean, AttemptsStarted, PlacedStays, RPlaced, PlacedLive, Dead, Others, NoDec, A
<1>10. GiveUpHolds'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, GiveUpHolds, TypeOK, Dead, Others, NoDec, A
<1>11. RStops'
  BY Design, AbsConstants, InK, SMTT(120) DEF Commit, TypeOK, AllOrNone, MarkPlaced, DecOnD, FateOnLegs, CommitStays, PinIsCommit, MarksFollow, FenceMax, GiveUpHolds, RStops, TookFate, DecShape, NoFenceNoMax, FateShape, MarkVsFate, GoneClean, AttemptsStarted, PlacedStays, RPlaced, PlacedLive, Dead, Others, NoDec, A
<1>12. TookFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, TookFate, TypeOK, Dead, Others, NoDec, A
<1>13. DecShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, DecShape, TypeOK, Dead, Others, NoDec, A
<1>14. NoFenceNoMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, NoFenceNoMax, TypeOK, Dead, Others, NoDec, A
<1>15. FateShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, FateShape, TypeOK, Dead, Others, NoDec, A
<1>16. MarkVsFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, MarkVsFate, TypeOK, Dead, Others, NoDec, A
<1>17. GoneClean'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, GoneClean, TypeOK, Dead, Others, NoDec, A
<1>18. AttemptsStarted'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, AttemptsStarted, TypeOK, Dead, Others, NoDec, A
<1>19. PlacedStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, PlacedStays, TypeOK, Dead, Others, NoDec, A
<1>20. RPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, RPlaced, TypeOK, Dead, Others, NoDec, A
<1>21. PlacedLive'
  BY Design, AbsConstants, InK, SMTT(30) DEF Commit, PlacedLive, TypeOK, Dead, Others, NoDec, A
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9, <1>10, <1>11, <1>12, <1>13, <1>14, <1>15, <1>16, <1>17, <1>18, <1>19, <1>20, <1>21

LEMMA GiveUpCore ==
    ASSUME Core, NEW u \in U, NEW a \in A, GiveUp(u, a)
    PROVE  Core'
<1> USE DEF Core
<1>1. TypeOK'
  <2>1. bal' \in [K -> Int]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A
  <2>2. mk' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A
  <2>3. fate' \in [K -> [U -> {"none", "took", "aborted", "R"}]]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A
  <2>4. fa' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A
  <2>5. dec' \in [K -> [U -> [st : {"none", "pin", "took", "fenced", "R"}, a : 0..MaxA, fin : BOOLEAN]]]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A
  <2>6. gone' \in [K -> SUBSET U]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A
  <2>7. placed' \in [U -> [A -> SUBSET K]]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A
  <2>8. noCom' \in [U -> [A -> BOOLEAN]]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A
  <2>9. gd' \in [U -> {"none", "commit"}]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A
  <2>10. ca' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A
  <2>11. took' \in [U -> [K -> 0..2]]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A, AllOrNone
  <2>12. fmax' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF GiveUp, TypeOK, NoDec, A
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11, <2>12 DEF TypeOK
<1>2. AllOrNone'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, AllOrNone, TypeOK, Dead, Others, NoDec, A
<1>3. MarkPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, MarkPlaced, TypeOK, Dead, Others, NoDec, A
<1>4. DecOnD'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, DecOnD, TypeOK, Dead, Others, NoDec, A
<1>5. FateOnLegs'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, FateOnLegs, TypeOK, Dead, Others, NoDec, A
<1>6. CommitStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, CommitStays, TypeOK, Dead, Others, NoDec, A
<1>7. PinIsCommit'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, PinIsCommit, TypeOK, Dead, Others, NoDec, A
<1>8. MarksFollow'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, MarksFollow, TypeOK, Dead, Others, NoDec, A
<1>9. FenceMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, FenceMax, TypeOK, Dead, Others, NoDec, A
<1>10. GiveUpHolds'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, GiveUpHolds, TypeOK, Dead, Others, NoDec, A
<1>11. RStops'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, RStops, TypeOK, Dead, Others, NoDec, A
<1>12. TookFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, TookFate, TypeOK, Dead, Others, NoDec, A
<1>13. DecShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, DecShape, TypeOK, Dead, Others, NoDec, A
<1>14. NoFenceNoMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, NoFenceNoMax, TypeOK, Dead, Others, NoDec, A
<1>15. FateShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, FateShape, TypeOK, Dead, Others, NoDec, A
<1>16. MarkVsFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, MarkVsFate, TypeOK, Dead, Others, NoDec, A
<1>17. GoneClean'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, GoneClean, TypeOK, Dead, Others, NoDec, A
<1>18. AttemptsStarted'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, AttemptsStarted, TypeOK, Dead, Others, NoDec, A
<1>19. PlacedStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, PlacedStays, TypeOK, Dead, Others, NoDec, A
<1>20. RPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, RPlaced, TypeOK, Dead, Others, NoDec, A
<1>21. PlacedLive'
  BY Design, AbsConstants, InK, SMTT(30) DEF GiveUp, PlacedLive, TypeOK, Dead, Others, NoDec, A
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9, <1>10, <1>11, <1>12, <1>13, <1>14, <1>15, <1>16, <1>17, <1>18, <1>19, <1>20, <1>21

LEMMA FenceCore ==
    ASSUME Core, NEW u \in U, NEW a \in A, NEW fin \in BOOLEAN, Fence(u, a, fin)
    PROVE  Core'
<1> USE DEF Core
<1>1. TypeOK'
  <2>1. bal' \in [K -> Int]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A
  <2>2. mk' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A
  <2>3. fate' \in [K -> [U -> {"none", "took", "aborted", "R"}]]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A
  <2>4. fa' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A
  <2>5. dec' \in [K -> [U -> [st : {"none", "pin", "took", "fenced", "R"}, a : 0..MaxA, fin : BOOLEAN]]]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A
  <2>6. gone' \in [K -> SUBSET U]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A
  <2>7. placed' \in [U -> [A -> SUBSET K]]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A
  <2>8. noCom' \in [U -> [A -> BOOLEAN]]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A
  <2>9. gd' \in [U -> {"none", "commit"}]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A
  <2>10. ca' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A
  <2>11. took' \in [U -> [K -> 0..2]]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A, AllOrNone
  <2>12. fmax' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF Fence, TypeOK, NoDec, A
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11, <2>12 DEF TypeOK
<1>2. AllOrNone'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, AllOrNone, TypeOK, Dead, Others, NoDec, A
<1>3. MarkPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, MarkPlaced, TypeOK, Dead, Others, NoDec, A
<1>4. DecOnD'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, DecOnD, TypeOK, Dead, Others, NoDec, A
<1>5. FateOnLegs'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, FateOnLegs, TypeOK, Dead, Others, NoDec, A
<1>6. CommitStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, CommitStays, TypeOK, Dead, Others, NoDec, A
<1>7. PinIsCommit'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, PinIsCommit, TypeOK, Dead, Others, NoDec, A
<1>8. MarksFollow'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, MarksFollow, TypeOK, Dead, Others, NoDec, A
<1>9. FenceMax'
  <2> USE Design, AbsConstants, InK
  <2> SUFFICES ASSUME NEW uu \in U
               PROVE  /\ dec'[D[uu]][uu].st = "fenced" => dec'[D[uu]][uu].a = fmax'[uu] /\ fmax'[uu] \in A
                      /\ gd'[uu] = "commit" => fmax'[uu] < ca'[uu]
                      /\ \A kk \in K : mk'[kk][uu] <= fmax'[uu] + 1
                      /\ \A aa \in A : placed'[uu][aa] # {} => aa <= fmax'[uu] + 1
    BY DEF FenceMax
  <2>1. gd[u] # "commit" BY DEF Fence, CommitStays
  <2>2. dec[D[u]][u].st = "fenced" => dec[D[u]][u].a = fmax[u] BY DEF FenceMax
  <2>3. dec[D[u]][u].st = "none" => dec[D[u]][u].a = 0 /\ fmax[u] = 0 BY DEF Fence, DecShape, NoFenceNoMax
  <2>4. dec'[D[u]][u].st = "fenced" /\ dec'[D[u]][u].a = fmax'[u] /\ fmax'[u] \in A
    BY <2>2, <2>3 DEF Fence, TypeOK, A
  <2>5. \A x \in U : x # u => dec'[D[x]][x] = dec[D[x]][x] /\ fmax'[x] = fmax[x] BY DEF Fence, TypeOK
  <2>6. fmax'[uu] >= fmax[uu] /\ fmax'[uu] \in Nat BY DEF Fence, TypeOK, A
  <2>7. /\ gd'[uu] = gd[uu] /\ ca'[uu] = ca[uu]
        /\ \A kk \in K : mk'[kk][uu] = mk[kk][uu]
        /\ \A aa \in A : placed'[uu][aa] = placed[uu][aa]
    BY DEF Fence
  <2>8. /\ gd[uu] = "commit" => fmax[uu] < ca[uu]
        /\ \A kk \in K : mk[kk][uu] <= fmax[uu] + 1
        /\ \A aa \in A : placed[uu][aa] # {} => aa <= fmax[uu] + 1
    BY DEF FenceMax
  <2>11. /\ \A kk \in K : mk[kk][uu] \in Nat
         /\ ca[uu] \in Nat /\ fmax[uu] \in Nat
    BY DEF TypeOK
  <2>12. gd'[uu] = "commit" => fmax'[uu] < ca'[uu]
    <3>1. CASE uu = u BY <2>1, <2>7, <3>1
    <3>2. CASE uu # u BY <2>5, <2>7, <2>8, <3>2
    <3> QED BY <3>1, <3>2
  <2>13. \A kk \in K : mk'[kk][uu] <= fmax'[uu] + 1
    <3> TAKE kk \in K
    <3>1. mk'[kk][uu] = mk[kk][uu] /\ mk[kk][uu] <= fmax[uu] + 1 /\ mk[kk][uu] \in Nat BY <2>7, <2>8, <2>11
    <3> QED BY <3>1, <2>6, <2>11
  <2>14. \A aa \in A : placed'[uu][aa] # {} => aa <= fmax'[uu] + 1
    <3> TAKE aa \in A
    <3>1. placed'[uu][aa] = placed[uu][aa] /\ (placed[uu][aa] # {} => aa <= fmax[uu] + 1) BY <2>7, <2>8
    <3>2. aa \in Nat BY DEF A
    <3> QED BY <3>1, <3>2, <2>6, <2>11
  <2>9. CASE uu = u BY <2>4, <2>9, <2>12, <2>13, <2>14
  <2>10. CASE uu # u
    <3>1. dec'[D[uu]][uu].st = "fenced" => dec'[D[uu]][uu].a = fmax'[uu] /\ fmax'[uu] \in A
      <4>1. dec'[D[uu]][uu] = dec[D[uu]][uu] /\ fmax'[uu] = fmax[uu] BY <2>5, <2>10
      <4>2. dec[D[uu]][uu].st = "fenced" => dec[D[uu]][uu].a = fmax[uu] /\ fmax[uu] \in A BY DEF FenceMax
      <4> QED BY <4>1, <4>2
    <3> QED BY <3>1, <2>12, <2>13, <2>14
  <2> QED BY <2>9, <2>10
<1>10. GiveUpHolds'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, GiveUpHolds, TypeOK, Dead, Others, NoDec, A
<1>11. RStops'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, RStops, TypeOK, Dead, Others, NoDec, A
<1>12. TookFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, TookFate, TypeOK, Dead, Others, NoDec, A
<1>13. DecShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, DecShape, TypeOK, Dead, Others, NoDec, A
<1>14. NoFenceNoMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, NoFenceNoMax, TypeOK, Dead, Others, NoDec, A
<1>15. FateShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, FateShape, TypeOK, Dead, Others, NoDec, A
<1>16. MarkVsFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, MarkVsFate, TypeOK, Dead, Others, NoDec, A
<1>17. GoneClean'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, GoneClean, TypeOK, Dead, Others, NoDec, A
<1>18. AttemptsStarted'
  <2> USE Design, AbsConstants, InK
  <2> SUFFICES ASSUME NEW x \in U
               PROVE  /\ \A b \in A : noCom'[x][b] => b <= fmax'[x] + 1
                      /\ \A j \in K : fa'[j][x] <= fmax'[x] + 1
                      /\ gd'[x] = "commit" => Others(x) \subseteq placed'[x][ca'[x]]
    BY DEF AttemptsStarted
  <2>1. fmax'[x] >= fmax[x] /\ fmax[x] \in Nat /\ fmax'[x] \in Nat BY SMTT(60) DEF Fence, TypeOK, A
  <2>2. UNCHANGED <<noCom, fa, gd, ca, placed>> BY DEF Fence
  <2>3. /\ \A b \in A : noCom[x][b] => b <= fmax[x] + 1
        /\ \A j \in K : fa[j][x] <= fmax[x] + 1
        /\ gd[x] = "commit" => Others(x) \subseteq placed[x][ca[x]]
    BY DEF AttemptsStarted
  <2>4. \A b \in A : noCom'[x][b] => b <= fmax'[x] + 1
    <3> TAKE b \in A
    <3>1. b \in Nat BY DEF A
    <3> QED BY <2>1, <2>2, <2>3, <3>1
  <2>5. \A j \in K : fa'[j][x] <= fmax'[x] + 1
    <3> TAKE j \in K
    <3>1. fa[j][x] \in Nat BY DEF TypeOK
    <3> QED BY <2>1, <2>2, <2>3, <3>1
  <2> QED BY <2>2, <2>3, <2>4, <2>5
<1>19. PlacedStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, PlacedStays, TypeOK, Dead, Others, NoDec, A
<1>20. RPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, RPlaced, TypeOK, Dead, Others, NoDec, A
<1>21. PlacedLive'
  BY Design, AbsConstants, InK, SMTT(30) DEF Fence, PlacedLive, TypeOK, Dead, Others, NoDec, A
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9, <1>10, <1>11, <1>12, <1>13, <1>14, <1>15, <1>16, <1>17, <1>18, <1>19, <1>20, <1>21

LEMMA ResolveTakeCore ==
    ASSUME Core, NEW u \in U, NEW a \in A, NEW out \in {"commit", "abort"}, NEW k \in K, Resolve(u, a, out, k), out = "commit", mk[k][u] = a
    PROVE  Core'
<1> USE DEF Core
<1>0a. gd[u] = "commit" /\ ca[u] = a
  BY ResolveEnds
<1>0b. /\ k \in Others(u) /\ CommitFact(u, a)
      /\ bal' = [bal EXCEPT ![k] = @ + Amt[u][k]]
      /\ mk' = [mk EXCEPT ![k][u] = 0]
      /\ fate' = [fate EXCEPT ![k][u] = "took"]
      /\ took' = [took EXCEPT ![u][k] = @ + 1]
      /\ fa' = [fa EXCEPT ![k][u] = 0]
      /\ UNCHANGED <<dec, gone, placed, noCom, gd, ca, fmax>>
  BY DEF Resolve
<1>0c. took[u][k] = 0
  <2>1. mk[k][u] = ca[u] /\ ca[u] # 0 BY <1>0a DEF A
<2>2. (mk[k][u] = 0) = (took[u][k] = 1) BY <1>0a, <1>0b DEF MarksFollow
<2>3. took[u][k] \in 0..2 /\ took[u][k] <= 1 BY <1>0b, InK DEF TypeOK, AllOrNone
<2> QED BY <2>1, <2>2, <2>3
<1>0d. took' = [took EXCEPT ![u][k] = 1]
  BY <1>0b, <1>0c
<1>0e. took'[u][k] = 1 /\ \A x \in U, j \in K : (x # u \/ j # k) => took'[x][j] = took[x][j]
  BY <1>0d, InK DEF TypeOK
<1> USE <1>0a, <1>0b, <1>0c, <1>0d, <1>0e
<1>1. TypeOK'
  <2>1. bal' \in [K -> Int]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>2. mk' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>3. fate' \in [K -> [U -> {"none", "took", "aborted", "R"}]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>4. fa' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>5. dec' \in [K -> [U -> [st : {"none", "pin", "took", "fenced", "R"}, a : 0..MaxA, fin : BOOLEAN]]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>6. gone' \in [K -> SUBSET U]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>7. placed' \in [U -> [A -> SUBSET K]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>8. noCom' \in [U -> [A -> BOOLEAN]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>9. gd' \in [U -> {"none", "commit"}]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>10. ca' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>11. took' \in [U -> [K -> 0..2]]
    BY <1>0d, InK DEF TypeOK
  <2>12. fmax' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11, <2>12 DEF TypeOK
<1>2. AllOrNone'
  <2> USE Design, AbsConstants, InK
  <2>0. k \in Legs(u) /\ k # D[u] BY DEF Others
  <2> SUFFICES ASSUME NEW uu \in U
               PROVE  /\ \A kk \in K : took'[uu][kk] <= 1
                      /\ gd'[uu] # "commit" => \A kk \in K : took'[uu][kk] = 0
                      /\ gd'[uu] = "commit" =>
                            \A kk \in K : IF kk \in Legs(uu) THEN took'[uu][kk] = 1 \/ mk'[kk][uu] = ca'[uu]
                                          ELSE took'[uu][kk] = 0
    BY DEF AllOrNone
  <2>1. \A kk \in K : (uu # u \/ kk # k) => mk'[kk][uu] = mk[kk][uu] BY DEF TypeOK
  <2> QED BY <2>0, <2>1, SMTT(60) DEF AllOrNone, TypeOK
<1>3. MarkPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, MarkPlaced, TypeOK, Dead, Others, NoDec, A
<1>4. DecOnD'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, DecOnD, TypeOK, Dead, Others, NoDec, A
<1>5. FateOnLegs'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, FateOnLegs, TypeOK, Dead, Others, NoDec, A
<1>6. CommitStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, CommitStays, TypeOK, Dead, Others, NoDec, A
<1>7. PinIsCommit'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, PinIsCommit, TypeOK, Dead, Others, NoDec, A
<1>8. MarksFollow'
  <2> USE Design, AbsConstants, InK
  <2>0. k \in Legs(u) /\ k # D[u] BY DEF Others
  <2> SUFFICES ASSUME NEW uu \in U, gd'[uu] = "commit", NEW kk \in Others(uu)
               PROVE  /\ mk'[kk][uu] \in {0, ca'[uu]}
                      /\ (mk'[kk][uu] = 0) = (took'[uu][kk] = 1)
    BY DEF MarksFollow
  <2>1. kk \in K BY InK
  <2>2. (uu # u \/ kk # k) => mk'[kk][uu] = mk[kk][uu] BY <2>1 DEF TypeOK
  <2> QED BY <2>1, <2>2, SMTT(60) DEF MarksFollow, TypeOK
<1>9. FenceMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, FenceMax, TypeOK, Dead, Others, NoDec, A
<1>10. GiveUpHolds'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, GiveUpHolds, TypeOK, Dead, Others, NoDec, A
<1>11. RStops'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, RStops, TypeOK, Dead, Others, NoDec, A
<1>12. TookFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, TookFate, TypeOK, Dead, Others, NoDec, A
<1>13. DecShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, DecShape, TypeOK, Dead, Others, NoDec, A
<1>14. NoFenceNoMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, NoFenceNoMax, TypeOK, Dead, Others, NoDec, A
<1>15. FateShape'
  <2> USE Design, AbsConstants, InK
  <2>0. k \in Legs(u) /\ k # D[u] BY DEF Others
  <2> SUFFICES ASSUME NEW kk \in K, NEW uu \in U
               PROVE  /\ fate'[kk][uu] = "took" => gd'[uu] = "commit" /\ took'[uu][kk] = 1
                      /\ fate'[kk][uu] = "aborted" => fa'[kk][uu] \in A
                      /\ fate'[kk][uu] # "aborted" => fa'[kk][uu] = 0
    BY DEF FateShape
  <2>1. (uu # u \/ kk # k) => fate'[kk][uu] = fate[kk][uu] /\ fa'[kk][uu] = fa[kk][uu] BY DEF TypeOK
  <2> QED BY <2>1, SMTT(60) DEF FateShape, TypeOK
<1>16. MarkVsFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, MarkVsFate, TypeOK, Dead, Others, NoDec, A
<1>17. GoneClean'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, GoneClean, TypeOK, Dead, Others, NoDec, A
<1>18. AttemptsStarted'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, AttemptsStarted, TypeOK, Dead, Others, NoDec, A
<1>19. PlacedStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, PlacedStays, TypeOK, Dead, Others, NoDec, A
<1>20. RPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, RPlaced, TypeOK, Dead, Others, NoDec, A
<1>21. PlacedLive'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, PlacedLive, TypeOK, Dead, Others, NoDec, A
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9, <1>10, <1>11, <1>12, <1>13, <1>14, <1>15, <1>16, <1>17, <1>18, <1>19, <1>20, <1>21

LEMMA ResolveEndCore ==
    ASSUME Core, NEW u \in U, NEW a \in A, NEW out \in {"commit", "abort"}, NEW k \in K, Resolve(u, a, out, k), ~(out = "commit" /\ mk[k][u] = a)
    PROVE  Core'
<1> USE DEF Core
<1>0a. ~(gd[u] = "commit" /\ mk[k][u] = ca[u])
  BY ResolveEnds
<1>0b. /\ k \in Others(u) /\ mk[k][u] # 0
      /\ \/ out = "abort" /\ AbortFact(u, a) /\ mk[k][u] <= a
         \/ out = "commit" /\ CommitFact(u, a) /\ mk[k][u] < a
      /\ mk' = [mk EXCEPT ![k][u] = 0]
      /\ fate' = [fate EXCEPT ![k][u] = "aborted"]
      /\ fa' = [fa EXCEPT ![k][u] = mk[k][u]]
      /\ UNCHANGED <<bal, took, dec, gone, placed, noCom, gd, ca, fmax>>
  BY DEF Resolve
<1> USE <1>0a, <1>0b
<1>1. TypeOK'
  <2>1. bal' \in [K -> Int]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>2. mk' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>3. fate' \in [K -> [U -> {"none", "took", "aborted", "R"}]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>4. fa' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>5. dec' \in [K -> [U -> [st : {"none", "pin", "took", "fenced", "R"}, a : 0..MaxA, fin : BOOLEAN]]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>6. gone' \in [K -> SUBSET U]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>7. placed' \in [U -> [A -> SUBSET K]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>8. noCom' \in [U -> [A -> BOOLEAN]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>9. gd' \in [U -> {"none", "commit"}]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>10. ca' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2>11. took' \in [U -> [K -> 0..2]]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A, AllOrNone
  <2>12. fmax' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF CommitFact, AbortFact, TypeOK, NoDec, A
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11, <2>12 DEF TypeOK
<1>2. AllOrNone'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, AllOrNone, TypeOK, Dead, Others, NoDec, A
<1>3. MarkPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, MarkPlaced, TypeOK, Dead, Others, NoDec, A
<1>4. DecOnD'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, DecOnD, TypeOK, Dead, Others, NoDec, A
<1>5. FateOnLegs'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, FateOnLegs, TypeOK, Dead, Others, NoDec, A
<1>6. CommitStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, CommitStays, TypeOK, Dead, Others, NoDec, A
<1>7. PinIsCommit'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, PinIsCommit, TypeOK, Dead, Others, NoDec, A
<1>8. MarksFollow'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, MarksFollow, TypeOK, Dead, Others, NoDec, A
<1>9. FenceMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, FenceMax, TypeOK, Dead, Others, NoDec, A
<1>10. GiveUpHolds'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, GiveUpHolds, TypeOK, Dead, Others, NoDec, A
<1>11. RStops'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, RStops, TypeOK, Dead, Others, NoDec, A
<1>12. TookFate'
  BY Design, AbsConstants, InK, SMTT(120) DEF CommitFact, AbortFact, TypeOK, AllOrNone, MarkPlaced, DecOnD, FateOnLegs, CommitStays, PinIsCommit, MarksFollow, FenceMax, GiveUpHolds, RStops, TookFate, DecShape, NoFenceNoMax, FateShape, MarkVsFate, GoneClean, AttemptsStarted, PlacedStays, RPlaced, PlacedLive, Dead, Others, NoDec, A
<1>13. DecShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, DecShape, TypeOK, Dead, Others, NoDec, A
<1>14. NoFenceNoMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, NoFenceNoMax, TypeOK, Dead, Others, NoDec, A
<1>15. FateShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, FateShape, TypeOK, Dead, Others, NoDec, A
<1>16. MarkVsFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, MarkVsFate, TypeOK, Dead, Others, NoDec, A
<1>17. GoneClean'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, GoneClean, TypeOK, Dead, Others, NoDec, A
<1>18. AttemptsStarted'
  <2> USE Design, AbsConstants, InK
  <2>1. mk[k][u] <= fmax[u] + 1 BY DEF FenceMax
  <2>2. \A x \in U, j \in K : (x # u \/ j # k) => fa'[j][x] = fa[j][x] BY DEF TypeOK
  <2> QED BY <2>1, <2>2, SMTT(60) DEF AttemptsStarted, TypeOK
<1>19. PlacedStays'
  BY Design, AbsConstants, InK, SMTT(120) DEF CommitFact, AbortFact, TypeOK, AllOrNone, MarkPlaced, DecOnD, FateOnLegs, CommitStays, PinIsCommit, MarksFollow, FenceMax, GiveUpHolds, RStops, TookFate, DecShape, NoFenceNoMax, FateShape, MarkVsFate, GoneClean, AttemptsStarted, PlacedStays, RPlaced, PlacedLive, Dead, Others, NoDec, A
<1>20. RPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF CommitFact, AbortFact, RPlaced, TypeOK, Dead, Others, NoDec, A
<1>21. PlacedLive'
  <2> USE Design, AbsConstants, InK
  <2> SUFFICES ASSUME NEW uu \in U, NEW aa \in A, NEW kk \in placed'[uu][aa]
               PROVE  mk'[kk][uu] = aa \/ gd'[uu] = "commit" \/ Dead(uu, aa)'
    BY DEF PlacedLive
  <2>0. kk \in K BY DEF TypeOK
  <2>1. \A x \in U, j \in K : (x # u \/ j # k) => fate'[j][x] = fate[j][x] BY DEF TypeOK
  <2>2. fate[k][u] # "R" BY DEF MarkVsFate
  <2>3. \A x \in U, b \in A : Dead(x, b) => Dead(x, b)'
    <3> TAKE x \in U, b \in A
    <3> HAVE Dead(x, b)
    <3>1. CASE \/ fmax[x] >= b
               \/ noCom[x][b]
               \/ dec[D[x]][x].st = "fenced" /\ dec[D[x]][x].fin
               \/ x \in gone[D[x]]
      BY <3>1 DEF Dead
    <3>2. CASE \E j \in Others(x) : j \notin placed[x][b] /\ (fate[j][x] = "R" \/ x \in gone[j])
      <4> PICK j \in Others(x) : j \notin placed[x][b] /\ (fate[j][x] = "R" \/ x \in gone[j]) BY <3>2
      <4>1. j \in K BY InK
      <4>2. fate[j][x] = "R" => fate'[j][x] = "R" BY <2>1, <2>2, <4>1
      <4>3. j \notin placed'[x][b] /\ (fate'[j][x] = "R" \/ x \in gone'[j]) BY <4>2
      <4> QED BY <4>3 DEF Dead
    <3>0. \/ fmax[x] >= b
          \/ noCom[x][b]
          \/ dec[D[x]][x].st = "fenced" /\ dec[D[x]][x].fin
          \/ x \in gone[D[x]]
          \/ \E j \in Others(x) : j \notin placed[x][b] /\ (fate[j][x] = "R" \/ x \in gone[j])
      BY DEF Dead
    <3> QED BY <3>0, <3>1, <3>2
  <2>4. kk \in placed[uu][aa] OBVIOUS
  <2>5. mk[kk][uu] = aa \/ gd[uu] = "commit" \/ Dead(uu, aa) BY <2>4 DEF PlacedLive
  <2>6. CASE ~(uu = u /\ kk = k)
    <3>1. mk'[kk][uu] = mk[kk][uu] BY <2>0, <2>6 DEF TypeOK
    <3> QED BY <2>3, <2>5, <3>1
  <2>7. CASE uu = u /\ kk = k /\ aa # mk[k][u]
    BY <2>3, <2>5, <2>7
  <2>8. CASE uu = u /\ kk = k /\ aa = mk[k][u]
    <3>1. CASE out = "commit"
      BY <3>1, <2>8 DEF CommitFact, PinIsCommit
    <3>2. CASE out = "abort"
      <4>0. AbortFact(u, a) /\ aa <= a /\ fmax[u] \in Nat /\ a \in Nat /\ aa \in Nat BY <3>2, <2>8 DEF TypeOK, A
      <4>1. Dead(u, aa)
        <5>1. CASE dec[D[u]][u].st = "fenced" /\ (dec[D[u]][u].fin \/ dec[D[u]][u].a >= a)
          BY <4>0, <5>1, SMTT(60) DEF Dead, FenceMax
        <5>2. CASE dec[D[u]][u].st = "R" BY <5>2 DEF DecShape
        <5>3. CASE u \in gone[D[u]] /\ dec[D[u]][u].st = "none" BY <5>3 DEF Dead
        <5>4. CASE \E j \in Others(u) : fate[j][u] = "R"
          <6> PICK j \in Others(u) : fate[j][u] = "R" BY <5>4
          <6>1. j \in K BY InK
          <6>2. CASE j \in placed[u][aa] BY <6>1, <6>2, <4>0 DEF RPlaced, Dead
          <6>3. CASE j \notin placed[u][aa] BY <6>3 DEF Dead
          <6> QED BY <6>2, <6>3
        <5>5. CASE noCom[u][a]
          <6>1. CASE a = aa BY <5>5, <6>1 DEF Dead
          <6>2. CASE a # aa BY <4>0, <5>5, <6>2, SMTT(60) DEF Dead, AttemptsStarted
          <6> QED BY <6>1, <6>2
        <5> QED BY <4>0, <5>1, <5>2, <5>3, <5>4, <5>5 DEF AbortFact
      <4> QED BY <2>3, <2>8, <4>1
    <3> QED BY <3>1, <3>2
  <2> QED BY <2>6, <2>7, <2>8
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9, <1>10, <1>11, <1>12, <1>13, <1>14, <1>15, <1>16, <1>17, <1>18, <1>19, <1>20, <1>21

LEMMA DropCore ==
    ASSUME Core, NEW u \in U, Drop(u)
    PROVE  Core'
<1> USE DEF Core
<1>1. TypeOK'
  <2>1. bal' \in [K -> Int]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A
  <2>2. mk' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A
  <2>3. fate' \in [K -> [U -> {"none", "took", "aborted", "R"}]]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A
  <2>4. fa' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A
  <2>5. dec' \in [K -> [U -> [st : {"none", "pin", "took", "fenced", "R"}, a : 0..MaxA, fin : BOOLEAN]]]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A
  <2>6. gone' \in [K -> SUBSET U]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A
  <2>7. placed' \in [U -> [A -> SUBSET K]]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A
  <2>8. noCom' \in [U -> [A -> BOOLEAN]]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A
  <2>9. gd' \in [U -> {"none", "commit"}]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A
  <2>10. ca' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A
  <2>11. took' \in [U -> [K -> 0..2]]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A, AllOrNone
  <2>12. fmax' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF Drop, TypeOK, NoDec, A
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11, <2>12 DEF TypeOK
<1>2. AllOrNone'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, AllOrNone, TypeOK, Dead, Others, NoDec, A
<1>3. MarkPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, MarkPlaced, TypeOK, Dead, Others, NoDec, A
<1>4. DecOnD'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, DecOnD, TypeOK, Dead, Others, NoDec, A
<1>5. FateOnLegs'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, FateOnLegs, TypeOK, Dead, Others, NoDec, A
<1>6. CommitStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, CommitStays, TypeOK, Dead, Others, NoDec, A
<1>7. PinIsCommit'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, PinIsCommit, TypeOK, Dead, Others, NoDec, A
<1>8. MarksFollow'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, MarksFollow, TypeOK, Dead, Others, NoDec, A
<1>9. FenceMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, FenceMax, TypeOK, Dead, Others, NoDec, A
<1>10. GiveUpHolds'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, GiveUpHolds, TypeOK, Dead, Others, NoDec, A
<1>11. RStops'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, RStops, TypeOK, Dead, Others, NoDec, A
<1>12. TookFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, TookFate, TypeOK, Dead, Others, NoDec, A
<1>13. DecShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, DecShape, TypeOK, Dead, Others, NoDec, A
<1>14. NoFenceNoMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, NoFenceNoMax, TypeOK, Dead, Others, NoDec, A
<1>15. FateShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, FateShape, TypeOK, Dead, Others, NoDec, A
<1>16. MarkVsFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, MarkVsFate, TypeOK, Dead, Others, NoDec, A
<1>17. GoneClean'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, GoneClean, TypeOK, Dead, Others, NoDec, A
<1>18. AttemptsStarted'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, AttemptsStarted, TypeOK, Dead, Others, NoDec, A
<1>19. PlacedStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, PlacedStays, TypeOK, Dead, Others, NoDec, A
<1>20. RPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, RPlaced, TypeOK, Dead, Others, NoDec, A
<1>21. PlacedLive'
  BY Design, AbsConstants, InK, SMTT(30) DEF Drop, PlacedLive, TypeOK, Dead, Others, NoDec, A
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9, <1>10, <1>11, <1>12, <1>13, <1>14, <1>15, <1>16, <1>17, <1>18, <1>19, <1>20, <1>21

LEMMA ForgetCore ==
    ASSUME Core, NEW k \in K, NEW u \in U, Forget(k, u)
    PROVE  Core'
<1> USE DEF Core
<1>1. TypeOK'
  <2>1. bal' \in [K -> Int]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A
  <2>2. mk' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A
  <2>3. fate' \in [K -> [U -> {"none", "took", "aborted", "R"}]]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A
  <2>4. fa' \in [K -> [U -> 0..MaxA]]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A
  <2>5. dec' \in [K -> [U -> [st : {"none", "pin", "took", "fenced", "R"}, a : 0..MaxA, fin : BOOLEAN]]]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A
  <2>6. gone' \in [K -> SUBSET U]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A
  <2>7. placed' \in [U -> [A -> SUBSET K]]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A
  <2>8. noCom' \in [U -> [A -> BOOLEAN]]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A
  <2>9. gd' \in [U -> {"none", "commit"}]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A
  <2>10. ca' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A
  <2>11. took' \in [U -> [K -> 0..2]]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A, AllOrNone
  <2>12. fmax' \in [U -> 0..MaxA]
    BY InK, AbsConstants, SMTT(90) DEF Forget, TypeOK, NoDec, A
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11, <2>12 DEF TypeOK
<1>2. AllOrNone'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, AllOrNone, TypeOK, Dead, Others, NoDec, A
<1>3. MarkPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, MarkPlaced, TypeOK, Dead, Others, NoDec, A
<1>4. DecOnD'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, DecOnD, TypeOK, Dead, Others, NoDec, A
<1>5. FateOnLegs'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, FateOnLegs, TypeOK, Dead, Others, NoDec, A
<1>6. CommitStays'
  BY Design, AbsConstants, InK, SMTT(120) DEF Forget, TypeOK, AllOrNone, MarkPlaced, DecOnD, FateOnLegs, CommitStays, PinIsCommit, MarksFollow, FenceMax, GiveUpHolds, RStops, TookFate, DecShape, NoFenceNoMax, FateShape, MarkVsFate, GoneClean, AttemptsStarted, PlacedStays, RPlaced, PlacedLive, Dead, Others, NoDec, A
<1>7. PinIsCommit'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, PinIsCommit, TypeOK, Dead, Others, NoDec, A
<1>8. MarksFollow'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, MarksFollow, TypeOK, Dead, Others, NoDec, A
<1>9. FenceMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, FenceMax, TypeOK, Dead, Others, NoDec, A
<1>10. GiveUpHolds'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, GiveUpHolds, TypeOK, Dead, Others, NoDec, A
<1>11. RStops'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, RStops, TypeOK, Dead, Others, NoDec, A
<1>12. TookFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, TookFate, TypeOK, Dead, Others, NoDec, A
<1>13. DecShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, DecShape, TypeOK, Dead, Others, NoDec, A
<1>14. NoFenceNoMax'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, NoFenceNoMax, TypeOK, Dead, Others, NoDec, A
<1>15. FateShape'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, FateShape, TypeOK, Dead, Others, NoDec, A
<1>16. MarkVsFate'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, MarkVsFate, TypeOK, Dead, Others, NoDec, A
<1>17. GoneClean'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, GoneClean, TypeOK, Dead, Others, NoDec, A
<1>18. AttemptsStarted'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, AttemptsStarted, TypeOK, Dead, Others, NoDec, A
<1>19. PlacedStays'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, PlacedStays, TypeOK, Dead, Others, NoDec, A
<1>20. RPlaced'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, RPlaced, TypeOK, Dead, Others, NoDec, A
<1>21. PlacedLive'
  BY Design, AbsConstants, InK, SMTT(30) DEF Forget, PlacedLive, TypeOK, Dead, Others, NoDec, A
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9, <1>10, <1>11, <1>12, <1>13, <1>14, <1>15, <1>16, <1>17, <1>18, <1>19, <1>20, <1>21

THEOREM CoreInductive == Core /\ [Next]_vars => Core'
<1> SUFFICES ASSUME Core, [Next]_vars PROVE Core'
  OBVIOUS
<1>1. CASE UNCHANGED vars BY <1>1, StutterCore
<1>2. CASE \E u \in U, a \in A, k \in K : Tent(u, a, k) BY <1>2, TentCore
<1>3. CASE \E u \in U, a \in A : Commit(u, a) BY <1>3, CommitCore
<1>4. CASE \E u \in U, a \in A : GiveUp(u, a) BY <1>4, GiveUpCore
<1>5. CASE \E u \in U, a \in A, fin \in BOOLEAN : Fence(u, a, fin) BY <1>5, FenceCore
<1>6. CASE \E u \in U, a \in A, k \in K, out \in {"commit", "abort"} : Resolve(u, a, out, k)
  <2> PICK u \in U, a \in A, k \in K, out \in {"commit", "abort"} : Resolve(u, a, out, k) BY <1>6
  <2>1. CASE out = "commit" /\ mk[k][u] = a BY <2>1, ResolveTakeCore
  <2>2. CASE ~(out = "commit" /\ mk[k][u] = a) BY <2>2, ResolveEndCore
  <2> QED BY <2>1, <2>2
<1>7. CASE \E u \in U : Drop(u) BY <1>7, DropCore
<1>8. CASE \E k \in K, u \in U : Forget(k, u) BY <1>8, ForgetCore
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8 DEF Next

THEOREM CoreHolds == Spec => []Core
BY InitCore, CoreInductive, PTL DEF Spec

\* S4: all or none.
THEOREM S4 == Spec => []AllOrNone
BY CoreHolds, PTL DEF Core

\* S5: at most once on each key.
THEOREM S5 == Spec => []AtMostOnce
<1>1. Core => AtMostOnce BY DEF Core, AllOrNone, AtMostOnce
<1> QED BY CoreHolds, <1>1, PTL
=============================================================================
