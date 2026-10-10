------------------------------ MODULE TxAbsSums ------------------------------
\* TLAPS proof of S1 (Conservation) and of NonNeg for TxAbs, for any
\* finite keys and uses, any amounts whose legs sum to 0, and any number
\* of attempts. It rests on Core, which TxAbsProofs proves inductive, and
\* on the community lemmas about MapThenSumSet (FiniteSetsExtTheorems,
\* proved there). TxAbs's Sum is a FoldSet, the form Apalache takes; the
\* first lemma shows it is MapThenSumSet.
\*
\* The argument: an action other than Commit leaves Bal(k), the money on k
\* counting committed legs not yet resolved, the same on every key; a
\* Commit of u adds Amt[u][k] to Bal(k) on every key, and those sum to 0.
\* LowOn(k), the least k can end at, stays at or above 0 by the guards of
\* Tent and Commit, and Bal(k) is at least LowOn(k) term by term.
EXTENDS TxAbsProofs, FiniteSetsExtTheorems, FoldsTheorems, FiniteSetTheorems, TLAPS

\* Sums.

LEMMA SumIsMap ==
    ASSUME NEW S, IsFiniteSet(S), NEW f(_)
    PROVE  Sum(S, f) = MapThenSumSet(f, S)
<1> DEFINE ch(T) == CHOOSE x \in T : TRUE
           op1(x, acc) == f(x) + acc
           P(T) == Sum(T, f) = MapThenSumSet(f, T)
<1>1. ASSUME NEW T \in SUBSET S, \A V \in (SUBSET T) \ {T} : P(V)
      PROVE  P(T)
  <2>0. IsFiniteSet(T) BY FS_Subset
  <2>1. \A V \in SUBSET T : V # {} => ch(V) \in V OBVIOUS
  <2>2. Sum(T, f) = IF T = {} THEN 0 ELSE op1(ch(T), Sum(T \ {ch(T)}, f))
    <3>1. MapThenFoldSet(op1, 0, LAMBDA x : x, ch, T)
            = IF T = {} THEN 0
              ELSE op1(ch(T), MapThenFoldSet(op1, 0, LAMBDA x : x, ch, T \ {ch(T)}))
      BY <2>0, <2>1, MapThenFoldSetDef, Isa
    <3> QED BY <3>1 DEF Sum, FoldSet
  <2>3. MapThenSumSet(f, T) = IF T = {} THEN 0 ELSE f(ch(T)) + MapThenSumSet(f, T \ {ch(T)})
    <3>1. MapThenFoldSet(+, 0, f, ch, T)
            = IF T = {} THEN 0 ELSE f(ch(T)) + MapThenFoldSet(+, 0, f, ch, T \ {ch(T)})
      BY <2>0, <2>1, MapThenFoldSetDef, Isa
    <3> QED BY <3>1 DEF MapThenSumSet
  <2>4. CASE T = {} BY <2>2, <2>3, <2>4
  <2>5. CASE T # {}
    <3>1. ch(T) \in T BY <2>1, <2>5
    <3>2. T \ {ch(T)} \in (SUBSET T) \ {T} BY <3>1
    <3>3. P(T \ {ch(T)}) BY <1>1, <3>2
    <3> QED BY <2>2, <2>3, <2>5, <3>3
  <2> QED BY <2>4, <2>5
<1> HIDE DEF P
<1>2. P(S) BY <1>1, FS_WFInduction, Isa
<1> QED BY <1>2 DEF P

LEMMA SumInt ==
    ASSUME NEW S, IsFiniteSet(S), NEW f(_), \A x \in S : f(x) \in Int
    PROVE  Sum(S, f) \in Int
BY SumIsMap, MapThenSumSetInt, Isa

LEMMA SumEq ==
    ASSUME NEW S, IsFiniteSet(S), NEW f(_), NEW g(_), \A x \in S : f(x) = g(x)
    PROVE  Sum(S, f) = Sum(S, g)
<1> DEFINE ch(T) == CHOOSE x \in T : TRUE
<1>1. \A T \in SUBSET S : T # {} => ch(T) \in T OBVIOUS
<1>2. MapThenFoldSet(+, 0, f, ch, S) = MapThenFoldSet(+, 0, g, ch, S)
  BY <1>1, MapThenFoldSetEqual, Isa
<1> QED BY <1>2, SumIsMap DEF MapThenSumSet

LEMMA SumPoint ==
    ASSUME NEW S, IsFiniteSet(S), NEW x \in S, NEW f(_), NEW g(_),
           \A y \in S : f(y) \in Int /\ g(y) \in Int,
           \A y \in S \ {x} : f(y) = g(y)
    PROVE  Sum(S, g) = Sum(S, f) + (g(x) - f(x))
<1> DEFINE sf == Sum(S, f)
           sg == Sum(S, g)
           mf == MapThenSumSet(f, S)
           mg == MapThenSumSet(g, S)
           rf == MapThenSumSet(f, S \ {x})
           rg == MapThenSumSet(g, S \ {x})
           fx == f(x)
           gx == g(x)
<1>0. /\ \A y \in S : f(y) \in Int
      /\ \A y \in S : g(y) \in Int
      /\ \A y \in S \ {x} : f(y) \in Int
      /\ fx \in Int /\ gx \in Int
  OBVIOUS
<1>1. IsFiniteSet(S \ {x}) BY FS_RemoveElement
<1>2. mf = fx + rf BY <1>0, MapThenSumSetNonempty
<1>3. mg = gx + rg BY <1>0, MapThenSumSetNonempty
<1>4. rf = rg
  <2>1. Sum(S \ {x}, f) = Sum(S \ {x}, g) BY <1>1, SumEq
  <2>2. Sum(S \ {x}, f) = rf /\ Sum(S \ {x}, g) = rg BY <1>1, SumIsMap
  <2> QED BY <2>1, <2>2
<1>5. rf \in Int BY <1>0, <1>1, MapThenSumSetInt
<1>6. sf = mf /\ sg = mg BY SumIsMap
<1> SUFFICES sg = sf + (gx - fx) OBVIOUS
<1> HIDE DEF sf, sg, mf, mg, rf, rg, fx, gx
<1> QED BY <1>0, <1>2, <1>3, <1>4, <1>5, <1>6

LEMMA SumPlus ==
    ASSUME NEW S, IsFiniteSet(S), NEW f(_), NEW g(_), \A y \in S : f(y) \in Int /\ g(y) \in Int
    PROVE  Sum(S, LAMBDA y : f(y) + g(y)) = Sum(S, f) + Sum(S, g)
<1> DEFINE h(y) == f(y) + g(y)
           P(T) == Sum(T, h) = Sum(T, f) + Sum(T, g)
<1>1. P({})
  <2>1. MapThenSumSet(f, {}) = 0 /\ MapThenSumSet(g, {}) = 0 /\ MapThenSumSet(h, {}) = 0
    BY MapThenSumSetEmpty, Isa
  <2> QED BY <2>1, SumIsMap, FS_EmptySet, Isa
<1>2. ASSUME NEW T \in SUBSET S, IsFiniteSet(T), P(T), NEW x \in S \ T
      PROVE  P(T \cup {x})
  <2> DEFINE mf == MapThenSumSet(f, T)
             mg == MapThenSumSet(g, T)
             mh == MapThenSumSet(h, T)
             nf == MapThenSumSet(f, T \cup {x})
             ng == MapThenSumSet(g, T \cup {x})
             nh == MapThenSumSet(h, T \cup {x})
             fx == f(x)
             gx == g(x)
             hx == h(x)
  <2>1. /\ \A y \in T \cup {x} : f(y) \in Int
        /\ \A y \in T \cup {x} : g(y) \in Int
        /\ \A y \in T \cup {x} : h(y) \in Int
        /\ \A y \in T : f(y) \in Int
        /\ \A y \in T : g(y) \in Int
        /\ fx \in Int /\ gx \in Int /\ hx = fx + gx
    BY <1>2
  <2>2. x \notin T BY <1>2
  <2>3. nf = fx + mf BY <1>2, <2>1, <2>2, MapThenSumSetAddElement
  <2>4. ng = gx + mg BY <1>2, <2>1, <2>2, MapThenSumSetAddElement
  <2>5. nh = hx + mh BY <1>2, <2>1, <2>2, MapThenSumSetAddElement
  <2>6. IsFiniteSet(T \cup {x}) BY <1>2, FS_AddElement
  <2>7. mf \in Int /\ mg \in Int BY <1>2, <2>1, MapThenSumSetInt
  <2>8. /\ Sum(T, h) = mh /\ Sum(T, f) = mf /\ Sum(T, g) = mg
        /\ Sum(T \cup {x}, h) = nh /\ Sum(T \cup {x}, f) = nf /\ Sum(T \cup {x}, g) = ng
    BY <1>2, <2>6, SumIsMap
  <2>9. mh = mf + mg BY <1>2, <2>8 DEF P
  <2>10. nh = nf + ng
    <3> HIDE DEF mf, mg, mh, nf, ng, nh, fx, gx, hx
    <3> QED BY <2>1, <2>3, <2>4, <2>5, <2>7, <2>9
  <2> QED BY <2>8, <2>10 DEF P
<1> HIDE DEF P
\* Strong induction over subsets, as in SumIsMap: a nonempty T is T \ {x} with x added.
<1>4. ASSUME NEW T \in SUBSET S, \A V \in (SUBSET T) \ {T} : P(V)
      PROVE  P(T)
  <2>0. IsFiniteSet(T) BY FS_Subset
  <2>1. CASE T = {} BY <1>1, <2>1
  <2>2. CASE T # {}
    <3>1. PICK x \in T : TRUE BY <2>2
    <3>2. (T \ {x}) \in (SUBSET T) \ {T} BY <3>1
    <3>3. P(T \ {x}) BY <1>4, <3>2
    <3>4. IsFiniteSet(T \ {x}) BY <2>0, FS_RemoveElement
    <3>5. P((T \ {x}) \cup {x}) BY <1>2, <3>3, <3>4
    <3>6. (T \ {x}) \cup {x} = T BY <3>1
    <3> QED BY <3>5, <3>6
  <2> QED BY <2>1, <2>2
<1>3. P(S) BY <1>4, FS_WFInduction, IsaM("iprover")
<1> QED BY <1>3 DEF P, h

LEMMA SumMono ==
    ASSUME NEW S, IsFiniteSet(S), NEW f(_), NEW g(_),
           \A y \in S : f(y) \in Int /\ g(y) \in Int /\ f(y) <= g(y)
    PROVE  Sum(S, f) <= Sum(S, g)
<1>1. /\ \A y \in S : f(y) \in Int
      /\ \A y \in S : g(y) \in Int
      /\ \A y \in S : f(y) <= g(y)
  OBVIOUS
<1>2. MapThenSumSet(f, S) <= MapThenSumSet(g, S) BY <1>1, MapThenSumSetMonotonic
<1>3. Sum(S, f) = MapThenSumSet(f, S) /\ Sum(S, g) = MapThenSumSet(g, S) BY SumIsMap
<1> QED BY <1>2, <1>3

LEMMA SumZero ==
    ASSUME NEW S, IsFiniteSet(S), NEW f(_), \A y \in S : f(y) = 0
    PROVE  Sum(S, f) = 0
<1>1. \A y \in S : f(y) \in Nat OBVIOUS
<1>2. MapThenSumSet(f, S) = 0 BY <1>1, MapThenSumSetZero, Isa
<1> QED BY <1>2, SumIsMap, Isa

\* The money terms: TxAbs defines them as constant operators of the state
\* they read (HeldV, BalV, NegV, LowV, ConsV), so a primed term is the
\* same operator of the primed variables.

LEMMA Bridge ==
    /\ \A k \in K : LowOn(k) = LowV(bal, mk, k)
    /\ Conservation <=> ConsV(bal, gd, ca, mk) = Total
    /\ NonNeg <=> \A k \in K : BalV(bal, gd, ca, mk, k) >= 0
    /\ LowOK <=> \A k \in K : LowV(bal, mk, k) >= 0
BY DEF Bal, LowOn, Conservation, NonNeg, LowOK

LEMMA BridgePrime ==
    /\ Conservation' <=> ConsV(bal', gd', ca', mk') = Total
    /\ NonNeg' <=> \A k \in K : BalV(bal', gd', ca', mk', k) >= 0
    /\ LowOK' <=> \A k \in K : LowV(bal', mk', k) >= 0
BY DEF Bal, LowOn, Conservation, NonNeg, LowOK

LEMMA TermsInt ==
    ASSUME NEW g, NEW c, NEW m, NEW k \in K, NEW u \in U
    PROVE  HeldV(g, c, m, k, u) \in Int /\ NegV(m, k, u) \in Int
BY AbsConstants DEF HeldV, NegV

\* The sums over U are integers, so Bal and LowOn are wherever bal is.
LEMMA VInt ==
    ASSUME NEW b, NEW g, NEW c, NEW m, NEW k \in K, b[k] \in Int
    PROVE  /\ Sum(U, LAMBDA u : HeldV(g, c, m, k, u)) \in Int
           /\ Sum(U, LAMBDA u : NegV(m, k, u)) \in Int
           /\ BalV(b, g, c, m, k) \in Int
           /\ LowV(b, m, k) \in Int
<1> DEFINE f(x) == HeldV(g, c, m, k, x)
           h(x) == NegV(m, k, x)
<1>1. IsFiniteSet(U) BY AbsConstants
<1>2. \A x \in U : f(x) \in Int BY TermsInt
<1>3. \A x \in U : h(x) \in Int BY TermsInt
<1>4. Sum(U, f) \in Int BY <1>1, <1>2, SumInt
<1>5. Sum(U, h) \in Int BY <1>1, <1>3, SumInt
<1> QED BY <1>4, <1>5 DEF BalV, LowV

\* Bal and LowOn move by what changes on one use, the rest held equal.
LEMMA BalPoint ==
    ASSUME NEW b1, NEW g1, NEW c1, NEW m1, NEW b2, NEW g2, NEW c2, NEW m2, NEW k \in K, NEW u \in U,
           b1[k] \in Int, NEW d \in Int, b2[k] = b1[k] + d,
           \A x \in U \ {u} : HeldV(g1, c1, m1, k, x) = HeldV(g2, c2, m2, k, x)
    PROVE  BalV(b2, g2, c2, m2, k)
             = BalV(b1, g1, c1, m1, k) + d + (HeldV(g2, c2, m2, k, u) - HeldV(g1, c1, m1, k, u))
<1> DEFINE f(x) == HeldV(g1, c1, m1, k, x)
           g(x) == HeldV(g2, c2, m2, k, x)
<1>0. IsFiniteSet(U) BY AbsConstants
<1>1. \A x \in U : f(x) \in Int /\ g(x) \in Int BY TermsInt
<1>2. Sum(U, g) = Sum(U, f) + (g(u) - f(u)) BY <1>0, <1>1, SumPoint, Isa
<1>3. Sum(U, f) \in Int BY VInt
<1> QED BY <1>2, <1>3, <1>1 DEF BalV

LEMMA LowPoint ==
    ASSUME NEW b1, NEW m1, NEW b2, NEW m2, NEW k \in K, NEW u \in U,
           b1[k] \in Int, NEW d \in Int, b2[k] = b1[k] + d,
           \A x \in U \ {u} : NegV(m1, k, x) = NegV(m2, k, x)
    PROVE  LowV(b2, m2, k) = LowV(b1, m1, k) + d + (NegV(m2, k, u) - NegV(m1, k, u))
<1> DEFINE f(x) == NegV(m1, k, x)
           g(x) == NegV(m2, k, x)
<1>0. IsFiniteSet(U) BY AbsConstants
<1>1. \A x \in U : f(x) \in Int /\ g(x) \in Int BY TermsInt
<1>2. Sum(U, g) = Sum(U, f) + (g(u) - f(u)) BY <1>0, <1>1, SumPoint, Isa
<1>3. Sum(U, f) \in Int BY VInt
<1> QED BY <1>2, <1>3, <1>1 DEF LowV

\* The same two lemmas with every parameter first order, so a solver can instantiate them.
LEMMA BalPointQ ==
    \A b1, g1, c1, m1, b2, g2, c2, m2 : \A k \in K, u \in U, d \in Int :
        (/\ b1[k] \in Int /\ b2[k] = b1[k] + d
         /\ \A x \in U \ {u} : HeldV(g1, c1, m1, k, x) = HeldV(g2, c2, m2, k, x))
        => BalV(b2, g2, c2, m2, k)
             = BalV(b1, g1, c1, m1, k) + d + (HeldV(g2, c2, m2, k, u) - HeldV(g1, c1, m1, k, u))
<1> TAKE b1, g1, c1, m1, b2, g2, c2, m2
<1> TAKE k \in K, u \in U, d \in Int
<1> HAVE /\ b1[k] \in Int /\ b2[k] = b1[k] + d
         /\ \A x \in U \ {u} : HeldV(g1, c1, m1, k, x) = HeldV(g2, c2, m2, k, x)
<1> QED BY BalPoint, Isa

LEMMA LowPointQ ==
    \A b1, m1, b2, m2 : \A k \in K, u \in U, d \in Int :
        (/\ b1[k] \in Int /\ b2[k] = b1[k] + d
         /\ \A x \in U \ {u} : NegV(m1, k, x) = NegV(m2, k, x))
        => LowV(b2, m2, k) = LowV(b1, m1, k) + d + (NegV(m2, k, u) - NegV(m1, k, u))
<1> TAKE b1, m1, b2, m2
<1> TAKE k \in K, u \in U, d \in Int
<1> HAVE /\ b1[k] \in Int /\ b2[k] = b1[k] + d
         /\ \A x \in U \ {u} : NegV(m1, k, x) = NegV(m2, k, x)
<1> QED BY LowPoint, Isa

\* Bal is at least LowOn, term by term (NonNeg from LowOK).
LEMMA BalAboveLow ==
    ASSUME NEW b, NEW g, NEW c, NEW m, NEW k \in K, b[k] \in Int
    PROVE  BalV(b, g, c, m, k) >= LowV(b, m, k)
<1> DEFINE f(x) == NegV(m, k, x)
           h(x) == HeldV(g, c, m, k, x)
<1>0. IsFiniteSet(U) BY AbsConstants
<1>1. \A x \in U : f(x) \in Int /\ h(x) \in Int /\ f(x) <= h(x) BY TermsInt DEF NegV, HeldV
<1>2. Sum(U, f) <= Sum(U, h) BY <1>0, <1>1, SumMono, Isa
<1>3. Sum(U, f) \in Int /\ Sum(U, h) \in Int BY VInt
<1> QED BY <1>2, <1>3 DEF BalV, LowV

\* S1 and NonNeg.

Inv == Core /\ Conservation /\ LowOK

LEMMA InitInv == Init => Inv
<1> SUFFICES ASSUME Init PROVE Inv OBVIOUS
<1>1. Core BY InitCore
<1>2. \A k \in K : BalV(bal, gd, ca, mk, k) = Start[k] /\ LowV(bal, mk, k) = Start[k]
  <2> TAKE k \in K
  <2>1. Sum(U, LAMBDA u : HeldV(gd, ca, mk, k, u)) = 0
    BY AbsConstants, SumZero, Isa DEF Init, HeldV
  <2>2. Sum(U, LAMBDA u : NegV(mk, k, u)) = 0
    BY AbsConstants, SumZero, Isa DEF Init, NegV
  <2> QED BY <2>1, <2>2, AbsConstants DEF Init, BalV, LowV
<1>3. ConsV(bal, gd, ca, mk) = Total
  <2> DEFINE f(k) == BalV(bal, gd, ca, mk, k)
             s(k) == Start[k]
  <2>1. \A k \in K : f(k) = s(k) BY <1>2
  <2>2. IsFiniteSet(K) BY AbsConstants
  <2>3. Sum(K, f) = Sum(K, s) BY <2>1, <2>2, SumEq
  <2> QED BY <2>3 DEF ConsV, Total
<1>4. \A k \in K : LowV(bal, mk, k) >= 0 BY <1>2, AbsConstants
<1> QED BY <1>1, <1>3, <1>4, Bridge DEF Inv

\* Every key's Bal after a step: unchanged, or for a Commit of u, moved by u's leg there.
LEMMA BalStep ==
    ASSUME Core, [Next]_vars
    PROVE  \/ \A k \in K : BalV(bal', gd', ca', mk', k) = BalV(bal, gd, ca, mk, k)
           \/ \E u \in U : \A k \in K : BalV(bal', gd', ca', mk', k) = BalV(bal, gd, ca, mk, k) + Amt[u][k]
<1> USE AbsConstants, Design
<1>0. \A k \in K : bal[k] \in Int /\ BalV(bal, gd, ca, mk, k) \in Int
  <2>1. \A k \in K : bal[k] \in Int BY DEF Core, TypeOK
  <2> QED BY <2>1, VInt
<1>1. CASE UNCHANGED vars BY <1>1 DEF vars
<1>2. CASE \E u \in U, a \in A, k \in K : Tent(u, a, k)
  <2> PICK u \in U, a \in A, k \in K : Tent(u, a, k) BY <1>2
  <2>1. gd[u] # "commit" BY TentUncommitted
  <2>2. \A j \in K, x \in U : HeldV(gd', ca', mk', j, x) = HeldV(gd, ca, mk, j, x)
    BY <2>1 DEF Tent, HeldV, Core, TypeOK
  <2>3. \A j \in K : BalV(bal', gd', ca', mk', j) = BalV(bal, gd, ca, mk, j)
    BY <2>2, SumEq, Isa DEF Tent, BalV
  <2> QED BY <2>3
<1>3. CASE \E u \in U, a \in A : Commit(u, a)
  <2> PICK u \in U, a \in A : Commit(u, a) BY <1>3
  <2>1. /\ gd[u] # "commit"
        /\ \A k \in Others(u) : mk[k][u] = a
        /\ mk[D[u]][u] = 0
    BY CommitFinds
  <2>2. ASSUME NEW k \in K
        PROVE  BalV(bal', gd', ca', mk', k) = BalV(bal, gd, ca, mk, k) + Amt[u][k]
    <3>0. /\ (IF k = D[u] THEN Amt[u][k] ELSE 0) \in Int
          /\ Amt[u][k] \in Int
          /\ HeldV(gd', ca', mk', k, u) \in Int
      BY TermsInt
    <3>1. \A x \in U \ {u} : HeldV(gd, ca, mk, k, x) = HeldV(gd', ca', mk', k, x)
      BY DEF Commit, HeldV, Core, TypeOK
    <3>2. HeldV(gd, ca, mk, k, u) = 0 BY <2>1 DEF HeldV
    <3>3. bal'[k] = bal[k] + (IF k = D[u] THEN Amt[u][k] ELSE 0) BY DEF Commit, Core, TypeOK
    <3>4. HeldV(gd', ca', mk', k, u) = IF k = D[u] THEN 0 ELSE Amt[u][k]
      BY <2>1, Design DEF Commit, HeldV, Others, Legs, A, Core, TypeOK
    <3>5. BalV(bal', gd', ca', mk', k)
            = BalV(bal, gd, ca, mk, k) + (IF k = D[u] THEN Amt[u][k] ELSE 0)
              + (HeldV(gd', ca', mk', k, u) - HeldV(gd, ca, mk, k, u))
      BY <1>0, <3>0, <3>1, <3>3, BalPointQ
    <3> QED BY <1>0, <3>0, <3>2, <3>4, <3>5
  <2> QED BY <2>2
<1>4. CASE \E u \in U, a \in A : GiveUp(u, a)
  BY <1>4 DEF GiveUp
<1>5. CASE \E u \in U, a \in A, fin \in BOOLEAN : Fence(u, a, fin)
  BY <1>5 DEF Fence
<1>6. CASE \E u \in U, a \in A, k \in K, out \in {"commit", "abort"} : Resolve(u, a, out, k)
  <2> PICK u \in U, a \in A, k \in K, out \in {"commit", "abort"} : Resolve(u, a, out, k) BY <1>6
  <2>1. /\ out = "commit" /\ mk[k][u] = a => gd[u] = "commit" /\ ca[u] = a
        /\ ~(out = "commit" /\ mk[k][u] = a) => ~(gd[u] = "commit" /\ mk[k][u] = ca[u])
    BY ResolveEnds
  <2>2. ASSUME NEW j \in K
        PROVE  BalV(bal', gd', ca', mk', j) = BalV(bal, gd, ca, mk, j)
    <3>1. CASE j # k
      <4>1. \A x \in U : HeldV(gd', ca', mk', j, x) = HeldV(gd, ca, mk, j, x)
        BY <3>1 DEF Resolve, HeldV, Core, TypeOK
      <4> QED BY <3>1, <4>1, SumEq, Isa DEF Resolve, BalV, Core, TypeOK
    <3>2. CASE j = k
      <4>0. /\ (IF out = "commit" /\ mk[k][u] = a THEN Amt[u][k] ELSE 0) \in Int
            /\ HeldV(gd, ca, mk, k, u) \in Int
        BY TermsInt
      <4>1. \A x \in U \ {u} : HeldV(gd, ca, mk, k, x) = HeldV(gd', ca', mk', k, x)
        BY DEF Resolve, HeldV, Core, TypeOK
      <4>2. HeldV(gd', ca', mk', k, u) = 0 BY DEF Resolve, HeldV, Core, TypeOK
      <4>3. bal'[k] = bal[k] + (IF out = "commit" /\ mk[k][u] = a THEN Amt[u][k] ELSE 0)
        BY DEF Resolve, Core, TypeOK
      <4>4. HeldV(gd, ca, mk, k, u) = IF out = "commit" /\ mk[k][u] = a THEN Amt[u][k] ELSE 0
        BY <2>1 DEF Resolve, HeldV
      <4>5. BalV(bal', gd', ca', mk', k)
              = BalV(bal, gd, ca, mk, k) + (IF out = "commit" /\ mk[k][u] = a THEN Amt[u][k] ELSE 0)
                + (HeldV(gd', ca', mk', k, u) - HeldV(gd, ca, mk, k, u))
        BY <1>0, <4>0, <4>1, <4>3, BalPointQ
      <4> QED BY <3>2, <1>0, <4>0, <4>2, <4>4, <4>5
    <3> QED BY <3>1, <3>2
  <2> QED BY <2>2
<1>7. CASE \E u \in U : Drop(u)
  BY <1>7 DEF Drop
<1>8. CASE \E k \in K, u \in U : Forget(k, u)
  BY <1>8 DEF Forget
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8 DEF Next

\* The least each key can end at stays at or above 0.
LEMMA LowStep ==
    ASSUME Core, LowOK, [Next]_vars
    PROVE  \A k \in K : LowV(bal', mk', k) >= 0
<1> USE AbsConstants, Design
<1>0. /\ \A k \in K : bal[k] \in Int
      /\ \A k \in K : LowV(bal, mk, k) >= 0
      /\ \A k \in K : LowV(bal, mk, k) \in Int
  <2>1. \A k \in K : bal[k] \in Int BY DEF Core, TypeOK
  <2>2. \A k \in K : LowV(bal, mk, k) \in Int BY <2>1, VInt
  <2> QED BY <2>1, <2>2, Bridge
<1>1. CASE UNCHANGED vars BY <1>0, <1>1 DEF vars
<1>2. CASE \E u \in U, a \in A, k \in K : Tent(u, a, k)
  <2> PICK u \in U, a \in A, k \in K : Tent(u, a, k) BY <1>2
  <2> TAKE j \in K
  <2>1. CASE j # k
    <3>1. \A x \in U : NegV(mk', j, x) = NegV(mk, j, x) BY <2>1 DEF Tent, NegV, Core, TypeOK
    <3>2. LowV(bal', mk', j) = LowV(bal, mk, j) BY <3>1, SumEq, Isa DEF Tent, LowV
    <3> QED BY <3>2, <1>0
  <2>2. CASE j = k
    <3>0. bal'[k] = bal[k] + 0 BY <1>0 DEF Tent
    <3>1. \A x \in U \ {u} : NegV(mk, k, x) = NegV(mk', k, x) BY DEF Tent, NegV, Core, TypeOK
    <3>2. LowV(bal', mk', k) = LowV(bal, mk, k) + 0 + (NegV(mk', k, u) - NegV(mk, k, u))
      BY <1>0, <3>0, <3>1, LowPointQ
    <3>3. NegV(mk, k, u) \in Int /\ NegV(mk', k, u) \in Int BY TermsInt
    <3>4. NegV(mk, k, u) <= 0 /\ NegV(mk', k, u) <= 0 BY TermsInt DEF NegV
    <3>5. \/ NegV(mk', k, u) = 0
          \/ LowV(bal, mk, k) - NegV(mk, k, u) + NegV(mk', k, u) >= 0
      BY <1>0, <3>3, Design DEF Tent, NegV, LowOn, Core, TypeOK, A
    <3> QED BY <2>2, <3>2, <3>3, <3>4, <3>5, <1>0
  <2> QED BY <2>1, <2>2
<1>3. CASE \E u \in U, a \in A : Commit(u, a)
  <2> PICK u \in U, a \in A : Commit(u, a) BY <1>3
  <2> TAKE j \in K
  <2> DEFINE sm == Sum(U, LAMBDA x : NegV(mk, j, x))
  <2>0. mk' = mk BY DEF Commit
  <2>1. sm \in Int BY <1>0, VInt
  <2>2. bal'[j] = bal[j] + (IF j = D[u] THEN Amt[u][j] ELSE 0) BY DEF Commit, Core, TypeOK
  <2>3. LowV(bal', mk', j) = bal'[j] + sm /\ LowV(bal, mk, j) = bal[j] + sm BY <2>0 DEF LowV
  <2>4. j = D[u] => Amt[u][j] >= 0 \/ LowV(bal, mk, j) + Amt[u][j] >= 0
    BY Design DEF Commit, LowOn
  <2>5. Amt[u][j] \in Int OBVIOUS
  <2> HIDE DEF sm
  <2> QED BY <1>0, <2>1, <2>2, <2>3, <2>4, <2>5
<1>4. CASE \E u \in U, a \in A : GiveUp(u, a)
  BY <1>0, <1>4 DEF GiveUp
<1>5. CASE \E u \in U, a \in A, fin \in BOOLEAN : Fence(u, a, fin)
  BY <1>0, <1>5 DEF Fence
<1>6. CASE \E u \in U, a \in A, k \in K, out \in {"commit", "abort"} : Resolve(u, a, out, k)
  <2> PICK u \in U, a \in A, k \in K, out \in {"commit", "abort"} : Resolve(u, a, out, k) BY <1>6
  <2> TAKE j \in K
  <2>1. CASE j # k
    <3>1. \A x \in U : NegV(mk', j, x) = NegV(mk, j, x) BY <2>1 DEF Resolve, NegV, Core, TypeOK
    <3>2. LowV(bal', mk', j) = LowV(bal, mk, j) BY <2>1, <3>1, SumEq, Isa DEF Resolve, LowV, Core, TypeOK
    <3> QED BY <3>2, <1>0
  <2>2. CASE j = k
    <3>0. /\ (IF out = "commit" /\ mk[k][u] = a THEN Amt[u][k] ELSE 0) \in Int
          /\ Amt[u][k] \in Int
          /\ NegV(mk, k, u) \in Int /\ NegV(mk', k, u) \in Int
      BY AbsConstants DEF NegV
    <3>1. \A x \in U \ {u} : NegV(mk, k, x) = NegV(mk', k, x) BY DEF Resolve, NegV, Core, TypeOK
    <3>2. bal'[k] = bal[k] + (IF out = "commit" /\ mk[k][u] = a THEN Amt[u][k] ELSE 0)
      BY DEF Resolve, Core, TypeOK
    <3>3. LowV(bal', mk', k)
            = LowV(bal, mk, k) + (IF out = "commit" /\ mk[k][u] = a THEN Amt[u][k] ELSE 0)
              + (NegV(mk', k, u) - NegV(mk, k, u))
      BY <1>0, <3>0, <3>1, <3>2, LowPointQ
    <3>4. NegV(mk', k, u) = 0 /\ NegV(mk, k, u) = IF Amt[u][k] < 0 THEN Amt[u][k] ELSE 0
      BY DEF Resolve, NegV, Core, TypeOK
    <3> QED BY <2>2, <1>0, <3>0, <3>3, <3>4
  <2> QED BY <2>1, <2>2
<1>7. CASE \E u \in U : Drop(u)
  BY <1>0, <1>7 DEF Drop
<1>8. CASE \E k \in K, u \in U : Forget(k, u)
  BY <1>0, <1>8 DEF Forget
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8 DEF Next

THEOREM InvInductive == Inv /\ [Next]_vars => Inv'
<1> SUFFICES ASSUME Inv, [Next]_vars PROVE Inv' OBVIOUS
<1> USE AbsConstants
<1>1. Core' BY CoreInductive DEF Inv
<1>2. LowOK' BY LowStep, BridgePrime DEF Inv
<1>3. Conservation'
  <2>0. ConsV(bal, gd, ca, mk) = Total BY Bridge DEF Inv
  <2> DEFINE f(k) == BalV(bal, gd, ca, mk, k)
             f2(k) == BalV(bal', gd', ca', mk', k)
  <2>a. ConsV(bal', gd', ca', mk') = Sum(K, f2) /\ ConsV(bal, gd, ca, mk) = Sum(K, f) BY DEF ConsV
  <2>b. \A k \in K : f(k) \in Int
    <3>1. \A k \in K : bal[k] \in Int BY DEF Inv, Core, TypeOK
    <3> QED BY <3>1, VInt
  <2>1. CASE \A k \in K : f2(k) = f(k)
    <3>1. Sum(K, f2) = Sum(K, f) BY <2>1, SumEq
    <3> QED BY <2>0, <2>a, <3>1, BridgePrime
  <2>2. CASE \E u \in U : \A k \in K : f2(k) = f(k) + Amt[u][k]
    <3> PICK u \in U : \A k \in K : f2(k) = f(k) + Amt[u][k] BY <2>2
    <3> DEFINE g(k) == Amt[u][k]
    <3>1. \A k \in K : f(k) \in Int /\ g(k) \in Int BY <2>b
    <3>2. Sum(K, LAMBDA k : f(k) + g(k)) = Sum(K, f) + Sum(K, g) BY <3>1, SumPlus
    <3>3. Sum(K, g) = 0 BY LegsBalance
    <3>4. Sum(K, f2) = Sum(K, LAMBDA k : f(k) + g(k)) BY SumEq
    <3>5. Sum(K, f) \in Int BY <2>b, SumInt
    <3>6. Sum(K, f2) = Sum(K, f) BY <3>2, <3>3, <3>4, <3>5
    <3> QED BY <2>0, <2>a, <3>6, BridgePrime
  <2> QED BY <2>1, <2>2, BalStep DEF Inv
<1> QED BY <1>1, <1>2, <1>3 DEF Inv

THEOREM InvHolds == Spec => []Inv
BY InitInv, InvInductive, PTL DEF Spec

\* S1: conservation.
THEOREM S1 == Spec => []Conservation
BY InvHolds, PTL DEF Inv

\* The game's rule: no key's money, counting committed legs, goes below 0.
LEMMA InvNonNeg == Inv => NonNeg
<1> SUFFICES ASSUME Inv PROVE NonNeg OBVIOUS
<1>1. \A k \in K : bal[k] \in Int BY DEF Inv, Core, TypeOK
<1>2. \A k \in K : BalV(bal, gd, ca, mk, k) >= LowV(bal, mk, k) BY <1>1, BalAboveLow
<1>3. \A k \in K : LowV(bal, mk, k) >= 0 BY Bridge DEF Inv
<1>4. \A k \in K : BalV(bal, gd, ca, mk, k) \in Int /\ LowV(bal, mk, k) \in Int BY <1>1, VInt
<1> QED BY <1>2, <1>3, <1>4, Bridge

THEOREM NonNegHolds == Spec => []NonNeg
BY InvHolds, InvNonNeg, PTL

=============================================================================
