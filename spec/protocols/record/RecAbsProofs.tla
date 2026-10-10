----------------------------- MODULE RecAbsProofs -----------------------------
\* TLAPS proof of S5 (AtMostOnce) for RecAbs, for any writers, any number
\* of ops per writer, any names and any stamps: IndInv, record 9's writer
\* invariant I1 and horizon invariant I2 with the facts they rest on,
\* holds initially and is kept by every action. Apalache checks the same
\* IndInv on two instances (ApaRecAbs). Design is the assumption that the
\* two rules the controls turn off are on.
EXTENDS RecAbs, TLAPS

ASSUME Design == FixRaise = TRUE /\ FixEntry = TRUE
ASSUME Consts == N \in Nat /\ MaxSt \in Nat

LEMMA MaxFacts == \A x, y \in 0..MaxSt : Max(x, y) \in 0..MaxSt /\ Max(x, y) >= x /\ Max(x, y) >= y
BY Consts DEF Max

THEOREM InitInv == Init => IndInv
BY Consts DEF Init, IndInv, TypeOK, AtMostOnce, I1, Kept, Settled, Prefix, I2, Held, Ops, Stamps, NoE

\* The heart of S5: an op a run takes had not taken before.
LEMMA LandInv ==
    ASSUME IndInv, NEW w \in W, NEW a \in 0..N, NEW i \in 1..N, Land(w, a, i)
    PROVE  IndInv'
<1> USE Consts DEF Ops, Stamps
<1> DEFINE e == E[w]
<1>1. /\ a <= ack[w] /\ a < i /\ i <= N
      /\ i = a + 1 \/ (e.on /\ i - 1 <= e.lo)
      /\ J(w, e, i) = "took"
      /\ E' = [E EXCEPT ![w] = [on |-> TRUE, lo |-> i, t |-> Max(IF e.on THEN e.t ELSE 0, st[w][i])]]
      /\ tk' = [tk EXCEPT ![w][i] = tk[w][i] + 1]
      /\ tst' = [tst EXCEPT ![w][i] = st[w][i]]
      /\ UNCHANGED <<T, h, ack, st, nst, ntk>>
  BY DEF Land
<1>2. TypeOK /\ AtMostOnce /\ I1 /\ Kept /\ Settled /\ Prefix /\ I2 /\ Held
  BY DEF IndInv
<1>3. /\ e \in [on : BOOLEAN, lo : 0..N, t : 0..MaxSt]
      /\ st[w][i] \in 0..MaxSt /\ h \in 0..MaxSt /\ ack[w] \in 0..N
      /\ tk[w][i] \in 0..1
  BY <1>2 DEF TypeOK
<1>4. ~(e.on /\ i <= e.lo) /\ ~(~e.on /\ st[w][i] <= h)
  BY <1>1 DEF J
\* With an entry, every op of w that took is at or below its lo, which is below i.
<1>5. e.on => \A j \in Ops : tk[w][j] >= 1 => j <= e.lo /\ e.lo < i
  BY <1>2, <1>4, <1>3 DEF I1
<1>6. ~e.on => \A j \in Ops : j > i => tk[w][j] = 0
  <2> SUFFICES ASSUME ~e.on, NEW j \in Ops, j > i, tk[w][j] >= 1 PROVE FALSE
    BY <1>2 DEF TypeOK
  <2>1. tk[w][i] >= 1 \/ i <= ack[w]
    BY <1>2 DEF Prefix
  <2>2. CASE tk[w][i] >= 1
    BY <2>2, <1>2, <1>4 DEF I1, Kept
  <2>3. CASE i <= ack[w]
    BY <2>3, <1>2, <1>4, <1>3 DEF Settled, I1, Kept
  <2> QED BY <2>1, <2>2, <2>3
<1>7. tk[w][i] = 0
  <2> SUFFICES ASSUME tk[w][i] >= 1 PROVE FALSE
    BY <1>3
  <2>1. CASE e.on
    BY <2>1, <1>2, <1>4 DEF I1
  <2>2. CASE ~e.on
    BY <2>2, <1>2, <1>4, <1>3 DEF I1, Kept
  <2> QED BY <2>1, <2>2
<1>8. Max(IF e.on THEN e.t ELSE 0, st[w][i]) \in 0..MaxSt
      /\ Max(IF e.on THEN e.t ELSE 0, st[w][i]) >= st[w][i]
      /\ (e.on => Max(IF e.on THEN e.t ELSE 0, st[w][i]) >= e.t)
  BY <1>3, MaxFacts
<1>9. TypeOK'
  BY <1>1, <1>2, <1>3, <1>7, <1>8 DEF TypeOK
<1>10. AtMostOnce'
  BY <1>1, <1>2, <1>7 DEF AtMostOnce, TypeOK
<1>11. I1'
  <2> SUFFICES ASSUME NEW v \in W, NEW j \in Ops, tk'[v][j] >= 1
               PROVE  IF E'[v].on THEN j <= E'[v].lo /\ tst'[v][j] <= E'[v].t ELSE tst'[v][j] <= h'
    BY DEF I1
  <2>1. CASE v # w
    BY <2>1, <1>1, <1>2 DEF I1, TypeOK
  <2>2. CASE v = w /\ j = i
    BY <2>2, <1>1, <1>2, <1>8 DEF TypeOK
  <2>3. CASE v = w /\ j # i
    <3>1. tk[w][j] >= 1
      BY <2>3, <1>1, <1>2 DEF TypeOK
    <3>2. j < i
      <4>1. CASE e.on
        <5>1. j <= e.lo /\ e.lo < i
          BY <4>1, <3>1, <1>5
        <5> QED BY <5>1, <1>3
      <4>2. CASE ~e.on
        <5>1. ~(j > i)
          BY <4>2, <3>1, <1>6
        <5> QED BY <5>1, <2>3
      <4> QED BY <4>1, <4>2
    <3>3. tst[w][j] <= Max(IF e.on THEN e.t ELSE 0, st[w][i])
      <4>1. CASE e.on
        <5>1. tst[w][j] <= e.t
          BY <4>1, <3>1, <1>2 DEF I1
        <5>2. e.t \in 0..MaxSt /\ st[w][i] \in 0..MaxSt /\ tst[w][j] \in 0..MaxSt
          BY <1>3, <1>2 DEF TypeOK
        <5> QED BY <4>1, <5>1, <5>2, <1>8
      <4>2. CASE ~e.on
        BY <4>2, <3>1, <1>2, <1>4, <1>8, <1>3 DEF I1, TypeOK
      <4> QED BY <4>1, <4>2
    <3> QED BY <2>3, <3>2, <3>3, <1>1, <1>2 DEF TypeOK
  <2> QED BY <2>1, <2>2, <2>3
<1>12. Kept'
  BY <1>1, <1>2 DEF Kept, TypeOK
<1>13. Settled'
  BY <1>1, <1>2 DEF Settled, TypeOK
<1>14. Prefix'
  <2> SUFFICES ASSUME NEW v \in W, NEW j \in Ops, tk'[v][j] >= 1 \/ (E'[v].on /\ j <= E'[v].lo),
                      NEW k \in Ops, k <= j
               PROVE  tk'[v][k] >= 1 \/ k <= ack'[v]
    BY DEF Prefix
  <2>1. CASE v # w
    BY <2>1, <1>1, <1>2 DEF Prefix, TypeOK
  <2>2. CASE v = w /\ k = i
    BY <2>2, <1>1, <1>2 DEF TypeOK
  <2>3. CASE v = w /\ k # i /\ k < i
    <3>1. CASE i = a + 1
      <4>1. k <= ack[w]
        BY <3>1, <2>3, <1>1, <1>3
      <4>2. ack'[w] = ack[w]
        BY <1>1
      <4> QED BY <4>1, <4>2, <2>3
    <3>2. CASE e.on /\ i - 1 <= e.lo
      <4>1. tk[w][k] >= 1 \/ k <= ack[w]
        BY <3>2, <2>3, <1>2 DEF Prefix, TypeOK
      <4> QED BY <4>1, <2>3, <1>1, <1>2 DEF TypeOK
    <3> QED BY <3>1, <3>2, <1>1
  <2>4. CASE v = w /\ k > i
    \* then j > i, and j is an op that took before this step: impossible (<1>5, <1>6).
    <3>1. j > i
      BY <2>4
    <3>2. tk[w][j] >= 1
      BY <3>1, <2>4, <1>1, <1>2 DEF TypeOK
    <3> QED BY <3>1, <3>2, <1>5, <1>6, <1>4, <1>3 DEF TypeOK
  <2> QED BY <2>1, <2>2, <2>3, <2>4
<1>15. I2' /\ Held'
  BY <1>1, <1>2 DEF I2, Held
<1> QED BY <1>9, <1>10, <1>11, <1>12, <1>13, <1>14, <1>15 DEF IndInv

LEMMA AckInv ==
    ASSUME IndInv, NEW w \in W, Ack(w)
    PROVE  IndInv'
BY Consts DEF IndInv, Ack, TypeOK, AtMostOnce, I1, Kept, Settled, Prefix, I2, Held, Ops, Stamps

LEMMA NameInv ==
    ASSUME IndInv, NEW n \in Names, Name(n)
    PROVE  IndInv'
BY Consts DEF IndInv, Name, TypeOK, AtMostOnce, I1, Kept, Settled, Prefix, I2, Held, Ops, Stamps

LEMMA DropEInv ==
    ASSUME IndInv, NEW w \in W, DropE(w)
    PROVE  IndInv'
<1> USE Consts DEF Ops, Stamps
<1>1. E[w].t \in 0..MaxSt /\ h \in 0..MaxSt
  BY DEF IndInv, TypeOK
<1>2. h' = Max(h, E[w].t)
  BY Design DEF DropE
<1>3. h' \in 0..MaxSt /\ h' >= h /\ h' >= E[w].t
  BY <1>1, <1>2, MaxFacts
<1> QED BY <1>3 DEF IndInv, DropE, TypeOK, AtMostOnce, I1, Kept, Settled, Prefix, I2, Held, NoE

LEMMA DropNInv ==
    ASSUME IndInv, NEW n \in Names, DropN(n)
    PROVE  IndInv'
<1> USE Consts DEF Ops, Stamps
<1>1. nst[n] \in 0..MaxSt /\ h \in 0..MaxSt
  BY DEF IndInv, TypeOK
<1>2. h' = Max(h, nst[n])
  BY Design DEF DropN
<1>3. h' \in 0..MaxSt /\ h' >= h /\ h' >= nst[n]
  BY <1>1, <1>2, MaxFacts
<1> QED BY <1>3 DEF IndInv, DropN, TypeOK, AtMostOnce, I1, Kept, Settled, Prefix, I2, Held

LEMMA RestampInv ==
    ASSUME IndInv, NEW w \in W, NEW i \in Ops, NEW s \in Stamps, Restamp(w, i, s)
    PROVE  IndInv'
BY Consts DEF IndInv, Restamp, TypeOK, AtMostOnce, I1, Kept, Settled, Prefix, I2, Held, Ops, Stamps

LEMMA FlawOff == \A w \in W, lo \in 0..N : ~Flaw(w, lo)
BY Design DEF Flaw

THEOREM NextInv == IndInv /\ [Next]_vars => IndInv'
<1> SUFFICES ASSUME IndInv, [Next]_vars PROVE IndInv'
  OBVIOUS
<1>1. CASE UNCHANGED vars
  BY <1>1 DEF vars, IndInv, TypeOK, AtMostOnce, I1, Kept, Settled, Prefix, I2, Held
<1>2. CASE Next
  BY <1>2, LandInv, AckInv, NameInv, DropEInv, DropNInv, RestampInv, FlawOff DEF Next
<1> QED BY <1>1, <1>2

THEOREM S5 == Spec => []AtMostOnce
<1>1. Spec => []IndInv
  BY InitInv, NextInv, PTL DEF Spec
<1> QED BY <1>1, PTL DEF IndInv
=============================================================================
