---- MODULE Tx ----
EXTENDS Env, TLC

CONSTANTS
    Scenario,
    TimedRoom,
    MarkCap,
    OwedCap,
    Win,
    SettleAge,
    MaxAttempts,
    Retries,
    FixCommitAfterAll,
    FixResolveAttempt,
    FixDropVerified,
    FixRefuseWrites,
    FixOrderRule,
    FixHorizonRaise,
    FixCleanRule,
    FixFenceFirst,
    MustExist,
    Erasable,
    LateAge,
    RemoveSend,
    FixIdCheck,
    Wtx,
    OrphanAge,
    SealAge,
    RemoveLate,
    ReadLag,
    FixGate,
    FixDrainPins,
    FixCommitWindow,
    FixOrphanAge,
    FixSealAge,
    FixResolveTerms,
    FixCreateOnce,
    FixOwnEvidence,
    KCut,
    FixCutMarks,
    FixKeep,
    FixPinProve,
    FixProveWrites,
    FixCutOrphan,
    FixFenceNotEvidence,
    ShareHost,
    LearnAtEnd,
    FixWriterOrphan

VARIABLES
    ls,
    started,
    finished,
    ans,
    ic,
    dec, comAt, comT, committer, applied, fenced, finF, refd, made, edTook, edBy, bad,
    edIds, late, lossOf, orph, incN, gave

lvars == <<ls, started, finished, ans, ic>>
gvars == <<dec, comAt, comT, committer, applied, fenced, finF, refd, made, edTook, edBy, bad,
           edIds, late, lossOf, orph, incN, gave>>
vars == <<envVars, lvars, gvars>>

ASSUME /\ TimedRoom \in Nat \ {0} /\ MarkCap \in Nat \ {0} /\ OwedCap \in Nat \ {0}
       /\ Win \in Nat \ {0} /\ SettleAge \in Nat /\ MaxAttempts \in Nat \ {0} /\ Retries \in Nat

NONE == -100
Host(s) == IF ShareHost /\ s = "A2" THEN "A" ELSE s
Names == 1..3

LegRec(k, d, op) == [k |-> k, d |-> d, op |-> op]
Legs(t) ==
    CASE t = 1 -> << LegRec("a", -1, ""), LegRec("b", 1, "") >>
      [] t = 2 -> << LegRec("b", -1, ""), LegRec("a", 1, "") >>
      [] t = 3 -> << LegRec("a", -1, ""), LegRec("c", 1, "") >>
      [] t = 4 -> << LegRec("a", -1, ""), LegRec("b", 0, "claim"), LegRec("c", 1, "") >>
      [] t = 5 -> << LegRec("a", -2, ""), LegRec("b", 1, ""), LegRec("c", 1, "") >>
Hot(t) == IF t = 4 THEN 3 ELSE 0
TxTerms == 1..5

DOf(t) ==
    LET L == Legs(t)
        ops == {i \in DOMAIN L : L[i].op # ""}
        cr == {i \in DOMAIN L : L[i].d > 0}
    IN IF Hot(t) # 0 THEN L[Hot(t)].k
       ELSE IF Cardinality(ops) = 1 THEN L[CHOOSE i \in ops : TRUE].k
       ELSE IF cr # {} THEN L[CHOOSE i \in cr : \A j \in cr : i <= j].k
       ELSE L[Len(L)].k
LegKeys(t) == {Legs(t)[i].k : i \in DOMAIN Legs(t)}
LegIdx(t, k) == CHOOSE i \in DOMAIN Legs(t) : Legs(t)[i].k = k

EdT(ek) == CASE ek = "dc" -> 101 [] ek = "dd" -> 102 [] ek = "gd" -> 103 [] ek = "claim" -> 104

It0 == [c |-> "", n |-> 0, st |-> 0, f |-> "", a |-> 0, fin |-> FALSE, t |-> 0, dk |-> "",
        amt |-> 0, legs |-> {}]
NoId == [j |-> <<"", 0>>, n |-> 0]
Fx0 == [e |-> "", n |-> 0, a |-> 0, st |-> 0, t |-> 0, dk |-> "", amt |-> 0, fin |-> FALSE, c |-> 0,
        id |-> NoId]

NoGate == [n |-> 0, st |-> 0, at |-> 0, kd |-> ""]
Z == [ex |-> FALSE, g |-> 0, x |-> 0, p |-> NONE, h |-> NONE, T |-> {}, P |-> {}, fx |-> {},
      id |-> NoId, sl |-> FALSE, sn |-> 0, rt |-> 0, ssrv |-> "", nam |-> 0, G |-> NoGate, L |-> {},
      K |-> {}, hk |-> NONE]
SeedVal(b) == [Z EXCEPT !.ex = TRUE, !.g = b, !.fx = {[Fx0 EXCEPT !.e = "seed", !.amt = b]}]

One(S) == CHOOSE e \in S : TRUE
Marks(R) == {m \in R.P : m.c \in {"esc", "exc"}}
Pins(R) == {m \in R.P : m.c = "pin"}
Named(S, n) == {e \in S : e.n = n}
IsHeld(R, n) == Named(R.T \cup R.P, n) # {}
Forgot(R, n, st) == ~IsHeld(R, n) /\ st <= R.h
HasExc(R) == \E m \in R.P : m.c = "exc"

RECURSIVE SumAmt(_)
SumAmt(S) == IF S = {} THEN 0 ELSE LET e == One(S) IN e.amt + SumAmt(S \ {e})

Low(R) == R.g + SumAmt({m \in R.P : m.c = "esc" /\ m.amt < 0})

LegFate(n, st, f, a, t) == [It0 EXCEPT !.c = "leg", !.n = n, !.st = st, !.f = f, !.a = a, !.t = t]
DecEnt(n, st, f, a, fin, t) == [It0 EXCEPT !.c = "dec", !.n = n, !.st = st, !.f = f, !.a = a,
                                           !.fin = fin, !.t = t]
SetT(R, e) == [R EXCEPT !.T = {x \in @ : ~(x.n = e.n /\ x.c = e.c)} \cup {e}]
AddFx(R, f) == [R EXCEPT !.fx = @ \cup {f}]
FxOf(e, m, c) == [e |-> e, n |-> m.n, a |-> m.a, st |-> m.st, t |-> m.t, dk |-> m.dk,
                  amt |-> m.amt, fin |-> m.fin, c |-> c]

AnyId == [m |-> "any", v |-> NoId]
A0 == [k |-> "", ky |-> "", c |-> 0, n |-> 0, st |-> 0, t |-> 0, a |-> 0, li |-> 0, fin |-> FALSE,
       legs |-> {}, ends |-> {}, dr |-> {}, ek |-> "", sb |-> 0, iid |-> AnyId,
       r |-> "", w |-> FALSE, it |-> {}, fa |-> 0, df |-> "", rf |-> FALSE, srt |-> 0, nam |-> 0, sv |-> ""]

J(R, act, r) == [R |-> R, act |-> act, r |-> r, it |-> {}, fa |-> 0, df |-> "", rf |-> FALSE]
JIt(R, act, r, it) == [J(R, act, r) EXCEPT !.it = it]
JDec(R, act, r, fa, df, rf) == [J(R, act, r) EXCEPT !.fa = fa, !.df = df, !.rf = rf]

ResEnd(R, e, ci) ==
    LET mks == {m \in Named(Marks(R), e.n) : ~FixResolveTerms \/ m.t = e.t}
        fs == {x \in R.T : x.c = "leg" /\ x.n = e.n}
    IN IF mks # {}
       THEN LET m == One(mks)
                Rm == [R EXCEPT !.P = @ \ {m}, !.p = IF m.c = "exc" THEN NONE ELSE @]
            IN IF e.out = "commit" /\ (m.a = e.a \/ ~FixResolveAttempt)
               THEN [R |-> AddFx(SetT([Rm EXCEPT !.g = IF m.c = "esc" THEN @ + m.amt ELSE @,
                                                 !.x = IF m.c = "exc" THEN R.p ELSE @],
                                      LegFate(m.n, m.st, "took", m.a, m.t)),
                                 FxOf("apply", m, ci)),
                     act |-> TRUE]
               ELSE IF e.out = "orphan"
               THEN [R |-> AddFx([SetT(Rm, LegFate(m.n, m.st, "aborted", m.a, m.t))
                                  EXCEPT !.L = @ \cup {[n |-> m.n, dk |-> m.dk, amt |-> m.amt]}],
                                 FxOf("orphan", m, ci)),
                     act |-> TRUE]
               ELSE IF \/ e.out = "abort" /\ (m.a <= e.a \/ ~FixResolveAttempt)
                       \/ e.out = "commit" /\ m.a < e.a
               THEN [R |-> AddFx(SetT(Rm, LegFate(m.n, m.st, "aborted", m.a, m.t)), FxOf("rm", m, ci)),
                     act |-> TRUE]
               ELSE [R |-> R, act |-> FALSE]
       ELSE IF Forgot(R, e.n, e.st) THEN [R |-> R, act |-> FALSE]
       ELSE IF e.out = "commit"
       THEN IF \E x \in fs : x.f = "took" THEN [R |-> R, act |-> FALSE]
            ELSE [R |-> AddFx(SetT(R, LegFate(e.n, e.st, "took", e.a, e.t)),
                              [FxOf("nomark", [It0 EXCEPT !.n = e.n, !.a = e.a], ci) EXCEPT !.dk = e.dk]),
                  act |-> TRUE]
       ELSE IF \E x \in fs : x.f # "aborted" \/ x.a >= e.a THEN [R |-> R, act |-> FALSE]
       ELSE [R |-> SetT(R, LegFate(e.n, e.st, "aborted", e.a, e.t)), act |-> TRUE]

RECURSIVE Ends(_, _, _)
Ends(R, E, ci) ==
    IF E = {} THEN [R |-> R, act |-> FALSE]
    ELSE LET e == One(E)
             o == ResEnd(R, e, ci)
             rest == Ends(o.R, E \ {e}, ci)
         IN [R |-> rest.R, act |-> o.act \/ rest.act]

DropPins(R, D) ==
    LET ps == {p \in Pins(R) : p.n \in D} IN
    [R EXCEPT !.P = @ \ ps,
              !.T = {x \in @ : x.n \notin {p.n : p \in ps}}
                    \cup {DecEnt(p.n, p.st, "took", p.a, FALSE, p.t) : p \in ps}]

MaxSt(S) == IF S = {} THEN NONE ELSE (CHOOSE e \in S : \A f \in S : f.st <= e.st).st
Raise(h, x) == IF FixHorizonRaise /\ x > h THEN x ELSE h
AgeT(R, clk) == LET old == {e \in R.T : clk - e.st >= Win} IN
               [R EXCEPT !.T = @ \ old, !.h = Raise(@, MaxSt(old))]
Fit1(R, own) ==
    IF Cardinality(R.T) <= TimedRoom THEN R
    ELSE LET pool == IF R.T \ own # {} THEN R.T \ own ELSE R.T
             e == CHOOSE e \in pool : \A f \in pool : e.st <= f.st
         IN [R EXCEPT !.T = @ \ {e}, !.h = Raise(@, e.st)]
Post(R, v, clk) ==
    LET own == R.T \ v.T
        R1 == AgeT(R, clk)
    IN Fit1(Fit1(Fit1(R1, own), own), own)

TentJ(R, a, ci) ==
    LET L == Legs(a.t)[a.li]
        mks == Named(Marks(R), a.n)
        m == One(mks)
    IN IF mks # {} /\ m.t # a.t THEN J(R, FALSE, "other")
       ELSE IF mks # {} /\ m.a = a.a THEN J(R, FALSE, "mine")
       ELSE IF mks # {} /\ m.a > a.a THEN J(R, FALSE, "superseded")
       ELSE
       LET R1 == IF mks # {}
                 THEN AddFx([R EXCEPT !.P = @ \ {m}, !.p = IF m.c = "exc" THEN NONE ELSE @],
                            FxOf("rm", m, ci))
                 ELSE R
           act1 == mks # {}
           fs == {x \in R1.T : x.c = "leg" /\ x.n = a.n}
           f == One(fs)
           els == {x \in R1.T \cup R1.P : x.n = a.n /\ x.c \in {"dec", "pin", "edit"}}
           mk == [It0 EXCEPT !.n = a.n, !.a = a.a, !.st = a.st, !.t = a.t, !.dk = DOf(a.t), !.amt = L.d]
       IN IF fs # {} /\ f.t # a.t THEN J(R1, act1, "other")
          ELSE IF fs # {} /\ ~(f.f = "aborted" /\ f.a < a.a) THEN JDec(R1, act1, "decided", f.a, f.f, FALSE)
          ELSE IF els # {} THEN J(R1, act1, "other")
          ELSE IF Forgot(R1, a.n, a.st) THEN J(R1, act1, "forgotten")
          ELSE IF FixGate /\ R1.G.n # 0 THEN JIt(R1, act1, "gated", {[It0 EXCEPT !.n = R1.G.n, !.st = R1.G.at]})
          ELSE IF L.op = ""
          THEN IF HasExc(R1) THEN JIt(R1, act1, "blocked", {x \in R1.P : x.c = "exc"})
               ELSE IF L.d < 0 /\ Low(R1) + L.d < 0
               THEN IF FixRefuseWrites
                    THEN J(AddFx(SetT(R1, LegFate(a.n, a.st, "R", a.a, a.t)), FxOf("Rleg", mk, ci)),
                           TRUE, "refused")
                    ELSE J(R1, act1, "refused")
               ELSE IF Cardinality(Marks(R1)) >= MarkCap THEN JIt(R1, act1, "noroom", Marks(R1))
               ELSE J([R1 EXCEPT !.P = @ \cup {[mk EXCEPT !.c = "esc"]}], TRUE, "mine")
          ELSE IF Marks(R1) # {} THEN JIt(R1, act1, "blocked", Marks(R1))
          ELSE IF R1.x # 0
          THEN IF FixRefuseWrites
               THEN J(AddFx(SetT(R1, LegFate(a.n, a.st, "R", a.a, a.t)), FxOf("Rleg", mk, ci)),
                      TRUE, "refused")
               ELSE J(R1, act1, "refused")
          ELSE IF Cardinality(Marks(R1)) >= MarkCap THEN JIt(R1, act1, "noroom", Marks(R1))
          ELSE J([R1 EXCEPT !.P = @ \cup {[mk EXCEPT !.c = "exc"]}, !.p = 1], TRUE, "mine")

CommitJ(R0, a, ci) ==
    LET R == IF ~FixDropVerified /\ Cardinality(Pins(R0)) >= OwedCap
             THEN DropPins(R0, {p.n : p \in Pins(R0)}) ELSE R0
        k == DOf(a.t)
        L == Legs(a.t)[LegIdx(a.t, k)]
        ps == Named(Pins(R), a.n)
        ds == {x \in R.T : x.c = "dec" /\ x.n = a.n}
        d == One(ds)
        pin == [It0 EXCEPT !.c = "pin", !.n = a.n, !.a = a.a, !.st = a.st, !.t = a.t,
                           !.dk = k, !.legs = LegKeys(a.t) \ {k}]
        rdec(f) == DecEnt(a.n, a.st, f, a.a, FALSE, a.t)
        ok == \/ L.op = "" /\ (L.d >= 0 \/ Low(R) + L.d >= 0)
              \/ L.op = "claim" /\ R.x = 0
        blk == IF L.op = "" THEN HasExc(R) ELSE Marks(R) # {}
    IN IF ps # {} THEN (IF One(ps).t # a.t THEN J(R, FALSE, "other")
                        ELSE JDec(R, FALSE, "committed", One(ps).a, "took", FALSE))
       ELSE IF ds # {} /\ d.t # a.t THEN J(R, FALSE, "other")
       ELSE IF ds # {} /\ d.f = "took" THEN JDec(R, FALSE, "committed", d.a, "took", FALSE)
       ELSE IF ds # {} /\ d.f \in {"R", "F"} THEN JDec(R, FALSE, "refused", d.a, d.f, FALSE)
       ELSE IF ds # {} /\ d.f = "fenced" /\ (d.fin \/ d.a >= a.a)
            THEN JDec(R, FALSE, "fenced", d.a, "fenced", d.fin)
       ELSE IF Named({x \in R.T \cup Marks(R) : x.c # "dec"}, a.n) # {} THEN J(R, FALSE, "other")
       ELSE IF ds = {} /\ Forgot(R, a.n, a.st) THEN J(R, FALSE, "forgotten")
       ELSE IF FixGate /\ R.G.n # 0 /\ R.G.kd = "erase"
            THEN JIt(R, FALSE, "gated", {[It0 EXCEPT !.n = R.G.n, !.st = R.G.at]})
       ELSE IF blk THEN JIt(R, FALSE, "blocked", IF L.op = "" THEN {x \in R.P : x.c = "exc"} ELSE Marks(R))
       ELSE IF ~ok
            THEN J(AddFx(SetT(R, rdec("R")), FxOf("Rdec", pin, ci)), TRUE, "refused")
       ELSE IF Cardinality(Pins(R)) >= OwedCap THEN JIt(R, FALSE, "owed", Pins(R))
       ELSE J(AddFx([R EXCEPT !.g = @ + L.d, !.x = IF L.op = "claim" THEN 1 ELSE @,
                              !.T = {x \in @ : ~(x.c = "dec" /\ x.n = a.n)}, !.P = @ \cup {pin}],
                    FxOf("commit", pin, ci)),
              TRUE, "committed")

FenceJ(R, a, ci) ==
    LET ps == Named(Pins(R), a.n)
        ds == {x \in R.T : x.c = "dec" /\ x.n = a.n}
        d == One(ds)
        fe(at, fin) == FxOf("fence", [It0 EXCEPT !.n = a.n, !.a = at, !.fin = fin, !.dk = a.ky], ci)
    IN IF ps # {} THEN JDec(R, FALSE, "committed", One(ps).a, "took", FALSE)
       ELSE IF ds # {} /\ d.f = "took" THEN JDec(R, FALSE, "committed", d.a, "took", FALSE)
       ELSE IF ds # {} /\ d.f \in {"R", "F"} THEN JDec(R, FALSE, "refused", d.a, d.f, FALSE)
       ELSE IF ds # {} /\ d.a >= a.a /\ (d.fin \/ ~a.fin) THEN JDec(R, FALSE, "fenced", d.a, "fenced", d.fin)
       ELSE IF ds # {}
            THEN LET at == IF d.a >= a.a THEN d.a ELSE a.a
                     fin == d.fin \/ a.fin
                 IN JDec(AddFx(SetT(R, DecEnt(a.n, d.st, "fenced", at, fin, d.t)), fe(at, fin)),
                         TRUE, "fenced", at, "fenced", fin)
       ELSE IF Forgot(R, a.n, a.st) THEN J(R, FALSE, "forgotten")
       ELSE JDec(AddFx(SetT(R, DecEnt(a.n, a.st, "fenced", a.a, a.fin, a.t)), fe(a.a, a.fin)),
                 TRUE, "fenced", a.a, "fenced", a.fin)

EditJ(R, a, ci) ==
    LET es == Named(R.T \cup R.P, a.n)
        e == One(es)
        esc == {m \in R.P : m.c = "esc"}
        verdicts == IF FixOrderRule THEN {R.g + SumAmt(S) >= 1 : S \in SUBSET esc} ELSE {R.g >= 1}
        took(dg, dx) == AddFx(SetT([R EXCEPT !.g = @ + dg, !.x = IF dx THEN 1 ELSE @],
                                   [It0 EXCEPT !.c = "edit", !.n = a.n, !.st = a.st, !.f = "took", !.t = a.t]),
                              [Fx0 EXCEPT !.e = "edit", !.n = a.n, !.amt = dg, !.c = ci, !.id = R.id])
        refused == SetT(R, [It0 EXCEPT !.c = "edit", !.n = a.n, !.st = a.st, !.f = "R", !.t = a.t])
    IN IF es # {} THEN (IF e.c = "edit" /\ e.t = a.t
                        THEN J(R, FALSE, IF e.f = "took" THEN "took" ELSE "refused")
                        ELSE J(R, FALSE, "other"))
       ELSE IF Forgot(R, a.n, a.st) THEN J(R, FALSE, "forgotten")
       ELSE IF HasExc(R) THEN JIt(R, FALSE, "blocked", {x \in R.P : x.c = "exc"})
       ELSE CASE a.ek = "dc" -> J(took(1, FALSE), TRUE, "took")
              [] a.ek = "dd" -> IF Low(R) - 1 < 0 THEN J(refused, TRUE, "refused")
                                ELSE J(took(-1, FALSE), TRUE, "took")
              [] a.ek = "gd" -> IF verdicts = {TRUE} THEN J(took(-1, FALSE), TRUE, "took")
                                ELSE IF verdicts = {FALSE} THEN J(refused, TRUE, "refused")
                                ELSE JIt(R, FALSE, "blocked", esc)
              [] a.ek = "claim" -> IF R.x = 0 THEN J(took(0, TRUE), TRUE, "took")
                                   ELSE J(refused, TRUE, "refused")

MayCreate(a, clk) ==
    /\ a.ky \notin MustExist
    /\ a.iid.m \in {"absent", "any"}
    /\ \/ a.k \in {"tent", "edit"}
       \/ a.k = "commit" /\ (clk - a.st <= Wtx \/ ~FixCommitWindow)
LeftOver(v, clk) == v.sl /\ (clk - v.rt >= SealAge \/ ~FixSealAge)
IdOk(a, v) == a.ky \notin Erasable \/ a.iid.m = "any" \/ a.iid.v = v.id \/ ~FixIdCheck

EraseStep(c, v, R, act) ==
    LET a == c.arg
        clk == Clock(c.srv)
        M == Marks(R) \cup (IF FixDrainPins THEN Pins(R) ELSE {})
        gate == R.G.n = 0
        R2 == IF gate THEN [R EXCEPT !.G = [n |-> a.n, st |-> a.st, at |-> clk, kd |-> "erase"]] ELSE R
    IN IF M # {}
       THEN IF gate \/ act
            THEN WriteNote(Post(R2, v, clk), [a EXCEPT !.r = "marks", !.it = M, !.w = TRUE])
            ELSE CancelNote(v, [a EXCEPT !.r = "marks", !.it = M, !.w = c.note.w])
       ELSE WriteNote([Z EXCEPT !.sl = TRUE, !.sn = a.n, !.rt = clk, !.ssrv = c.srv, !.nam = R.g,
                                !.fx = R.fx \cup {[Fx0 EXCEPT !.e = "erase", !.n = a.n, !.amt = -R.g, !.c = a.c]}],
                      [a EXCEPT !.r = "sealed", !.srt = clk, !.nam = R.g, !.sv = c.srv, !.w = TRUE])

RECURSIVE FitK(_)
FitK(R) ==
    IF Cardinality(R.K) <= KCut THEN R
    ELSE LET d == CHOOSE x \in R.K : \A y \in R.K : x.st <= y.st
         IN FitK([R EXCEPT !.K = @ \ {d}, !.hk = IF d.st > @ THEN d.st ELSE @])

ResetStep(c, v, R, act) ==
    LET a == c.arg
        clk == Clock(c.srv)
        own == R.G.n = a.n /\ R.G.kd = "reset"
        M == Marks(R)
        say(r) == IF act THEN WriteNote(Post(R, v, clk), [a EXCEPT !.r = r, !.w = TRUE])
                  ELSE CancelNote(v, [a EXCEPT !.r = r, !.w = c.note.w])
        R2 == IF R.G.n = 0 THEN [R EXCEPT !.G = [n |-> a.n, st |-> a.st, at |-> clk, kd |-> "reset"]] ELSE R
        cut == FitK([R EXCEPT !.g = 0, !.x = 0, !.p = NONE, !.K = @ \cup {[n |-> a.n, st |-> a.st]},
                              !.G = IF own THEN NoGate ELSE @,
                              !.fx = @ \cup {[Fx0 EXCEPT !.e = "cut", !.n = a.n, !.amt = -R.g, !.c = a.c]}])
    IN IF FixKeep /\ \E x \in R.K : x.n = a.n THEN say("took")
       ELSE IF ~own /\ a.st <= R.hk THEN say("forgotten")
       ELSE IF ~own /\ R.G.n # 0 THEN say("gatedBy")
       ELSE IF M # {} /\ FixCutMarks
            THEN IF R.G.n = 0 \/ act
                 THEN WriteNote(Post(R2, v, clk), [a EXCEPT !.r = "marks", !.it = M, !.w = TRUE])
                 ELSE CancelNote(v, [a EXCEPT !.r = "marks", !.it = M, !.w = c.note.w])
       ELSE WriteNote(Post(cut, v, clk), [a EXCEPT !.r = "took", !.nam = R.g, !.w = TRUE])

Step(c, v) ==
    LET a == c.arg
        clk == Clock(c.srv)
        create == ((~v.ex /\ ~v.sl) \/ LeftOver(v, clk)) /\ MayCreate(a, clk) /\ (~FixCreateOnce \/ ~c.note.w)
        R0 == IF create
              THEN [Z EXCEPT !.ex = TRUE, !.id = a.iid.v,
                             !.fx = {[Fx0 EXCEPT !.e = "create", !.n = a.n]}
                                    \cup IF clk - a.st > LateAge THEN {[Fx0 EXCEPT !.e = "late", !.n = a.n]} ELSE {}]
              ELSE [v EXCEPT !.fx = {}]
        en == Ends(R0, a.ends, a.c)
        dp == IF a.k \in {"commit", "drop", "erase"} THEN DropPins(en.R, a.dr) ELSE en.R
        ea == en.act \/ dp.P # en.R.P
        j == CASE a.k = "tent"   -> TentJ(dp, a, a.c)
               [] a.k = "commit" -> CommitJ(dp, a, a.c)
               [] a.k = "fence"  -> FenceJ(dp, a, a.c)
               [] a.k = "edit"   -> EditJ(dp, a, a.c)
               [] a.k \in {"res", "drop", "erase", "reset"} -> J(dp, FALSE, "done")
        act == create \/ ea \/ j.act \/ (a.k = "commit" /\ j.R.P # dp.P)
        nt == [a EXCEPT !.r = j.r, !.w = c.note.w \/ act, !.it = j.it, !.fa = j.fa, !.df = j.df, !.rf = j.rf]
    IN IF a.k = "seed"
       THEN IF v.ex \/ v.sl THEN CancelNote(v, [a EXCEPT !.r = "done", !.w = c.note.w])
            ELSE WriteNote(SeedVal(a.sb), [a EXCEPT !.r = "done", !.w = TRUE])
       ELSE IF a.k = "prove"
       THEN IF ~v.ex /\ (~v.sl \/ LeftOver(v, clk))
            THEN IF FixProveWrites
                 THEN WriteNote([Z EXCEPT !.sl = TRUE, !.rt = clk, !.ssrv = c.srv],
                                [a EXCEPT !.r = "proved", !.srt = clk, !.sv = c.srv, !.w = TRUE])
                 ELSE CancelNote(v, [a EXCEPT !.r = "proved", !.w = c.note.w])
            ELSE CancelNote(v, [a EXCEPT !.r = "exists", !.w = c.note.w])
       ELSE IF v.sl /\ ~create
            THEN IF a.k = "erase" /\ a.n = v.sn
                 THEN CancelNote(v, [a EXCEPT !.r = "sealed", !.srt = v.rt, !.nam = v.nam, !.sv = v.ssrv,
                                             !.w = c.note.w])
                 ELSE CancelNote(v, [a EXCEPT !.r = "missing", !.w = c.note.w])
       ELSE IF ~v.ex /\ ~create THEN CancelNote(v, [nt EXCEPT !.r = "missing", !.w = c.note.w])
       ELSE IF v.ex /\ ~IdOk(a, v) THEN CancelNote(v, [a EXCEPT !.r = "missing", !.w = c.note.w])
       ELSE IF a.k = "erase" THEN EraseStep(c, v, dp, ea)
       ELSE IF a.k = "reset" THEN ResetStep(c, v, dp, ea)
       ELSE IF act THEN WriteNote(Post(j.R, v, Clock(c.srv)), nt)
       ELSE CancelNote(v, [nt EXCEPT !.w = c.note.w])

Tf(c, v) == Step(c, v)
MsTf(c, it) == MsCancel(c, it)

E0 == [s |-> "A", m |-> "", n |-> 0, t |-> 0, st |-> NONE, k |-> "", ek |-> "", sb |-> 0,
       pre |-> FALSE, retry |-> FALSE, q |-> FALSE, wait |-> 0]
Seed(s, k, b) == [E0 EXCEPT !.s = s, !.m = "seed", !.k = k, !.sb = b, !.pre = TRUE]
TxE(s, n, t) == [E0 EXCEPT !.s = s, !.m = "tx", !.n = n, !.t = t]
GameTx(s, n, t, st) == [TxE(s, n, t) EXCEPT !.st = st]
Again(e) == [e EXCEPT !.retry = TRUE]
Ed(s, n, k, ek, st) == [E0 EXCEPT !.s = s, !.m = "edit", !.n = n, !.k = k, !.ek = ek, !.st = st,
                                  !.t = EdT(ek)]
Touch(s, k) == [E0 EXCEPT !.s = s, !.m = "touch", !.k = k]
Er(s, n, k, st) == [E0 EXCEPT !.s = s, !.m = "erase", !.n = n, !.k = k, !.st = st]
Rs(s, n, k, st) == [E0 EXCEPT !.s = s, !.m = "reset", !.n = n, !.k = k, !.st = st]
Calm(e) == [e EXCEPT !.q = TRUE]
After(e, i) == [e EXCEPT !.wait = i]

Script ==
    CASE Scenario = "Main"   -> << Seed("A", "a", 1), Seed("A", "b", 0),
                                  TxE("A", 1, 1), TxE("B", 2, 1), Touch("B", "a") >>
      [] Scenario = "Cross"  -> << Seed("A", "a", 1), Seed("A", "b", 1),
                                  TxE("A", 1, 1), TxE("B", 2, 2) >>
      [] Scenario = "Edit"   -> << Seed("A", "a", 1), Seed("A", "b", 0),
                                  TxE("A", 1, 1), Ed("B", 2, "a", "gd", 0) >>
      [] Scenario = "Retry"  -> << Seed("A", "a", 1), Seed("A", "b", 0),
                                  GameTx("A", 1, 1, 0), Again(GameTx("B", 1, 1, 0)) >>
      [] Scenario = "Terms"  -> << Seed("A", "a", 2), Seed("A", "b", 0), Seed("A", "c", 0),
                                  GameTx("A", 1, 1, 0), GameTx("B", 1, 3, 0) >>
      [] Scenario = "Three"  -> << Seed("A", "a", 2), Seed("A", "b", 0), Seed("A", "c", 0),
                                  TxE("A", 1, 5), TxE("B", 2, 1) >>
      [] Scenario = "Excl"   -> << Seed("A", "a", 1), Seed("A", "b", 0), Seed("A", "c", 0),
                                  TxE("A", 1, 4), Ed("B", 2, "b", "claim", 0) >>
      [] Scenario = "Owed"   -> << Seed("A", "a", 2), Seed("A", "b", 0),
                                  TxE("A", 1, 1), TxE("A", 2, 1), Touch("B", "a") >>
      [] Scenario = "Stuck"  -> << Seed("A", "a", 1), Seed("A", "b", 0),
                                  TxE("A", 1, 1), Touch("B", "a"), Touch("B", "b") >>
      [] Scenario = "Forget" -> << Seed("A", "a", 2), Seed("A", "b", 0),
                                  GameTx("A", 1, 1, 0), After(Touch("B", "b"), 3),
                                  Ed("A", 2, "b", "dc", 1), Ed("A", 3, "a", "dc", 1),
                                  After(Again(GameTx("B", 1, 1, 0)), 6) >>
      [] Scenario = "Clean"  -> << Seed("A", "a", 1),
                                  Ed("A", 1, "a", "dc", 0), Ed("B", 2, "a", "dc", 1) >>
      [] Scenario = "LateCreate" -> << Ed("A", 1, "a", "dc", 0), Er("B", 2, "a", 0) >>
      [] Scenario = "EraseSeed"  -> << Seed("A", "a", 2), Er("B", 2, "a", 0), Ed("A", 1, "a", "dc", 0) >>
      [] Scenario = "EraseLeg"   -> << Seed("A", "a", 2), Seed("A", "b", 0),
                                      TxE("A", 1, 1), Er("B", 2, "a", 0) >>
      [] Scenario = "EraseDec"   -> << Seed("A", "a", 2), Seed("A", "b", 0),
                                      TxE("A", 1, 1), Er("B", 2, "b", 0), Touch("B", "a") >>
      [] Scenario = "Orphan"     -> << Seed("A", "a", 1), TxE("A", 1, 3), Touch("B", "a") >>
      [] Scenario = "OrphanMade" -> << Seed("A", "a", 1), TxE("A", 1, 3), Touch("B", "a"),
                                      After(Ed("B", 2, "c", "dc", NONE), 3) >>
      [] Scenario = "Reseal"     -> << Seed("A", "a", 1), Er("B", 2, "a", 0), Ed("A", 1, "a", "dc", 0) >>
      [] Scenario = "OrphanWrite" -> << Seed("A", "a", 1), TxE("A", 1, 3), After(Ed("B", 2, "a", "gd", NONE), 2) >>
      [] Scenario = "TouchFence" -> << Seed("A", "a", 1), Seed("A", "c", 0), TxE("A", 1, 3), Touch("B", "a") >>
      [] Scenario = "TouchPin" -> << Seed("A", "a", 1), Seed("A", "c", 0), TxE("A", 1, 3), After(Touch("B", "c"), 3),
                                    Ed("B", 2, "c", "dc", NONE), Touch("B", "a") >>
      [] Scenario = "PinErased" -> << Seed("A", "a", 1), Seed("A", "c", 0), TxE("A", 1, 3), After(Er("B", 2, "a", 0), 3),
                                     Touch("B", "c"), Touch("B", "c") >>
      [] Scenario = "PinLateCreate" -> << Seed("A", "a", 1), Seed("A", "c", 0), TxE("A", 1, 4), After(Er("B", 2, "b", 0), 3),
                                         Touch("B", "c"), Touch("B", "c"), Ed("B", 3, "c", "dc", NONE), Touch("B", "b") >>
      [] Scenario = "CutOrphan" -> << Seed("A", "a", 1), TxE("A", 1, 3), After(Er("B", 2, "a", NONE), 2) >>
      [] Scenario = "SameServer" -> << Seed("A", "a", 2), Seed("A", "b", 0), TxE("A", 1, 1),
                                       Ed("A2", 2, "a", "gd", 0), Er("B", 3, "a", 0) >>
      [] Scenario = "Reset"      -> << Seed("A", "a", 2), Seed("A", "b", 0), TxE("A", 1, 1),
                                      Rs("B", 2, "a", 0), Again(Rs("A", 2, "a", 0)) >>
Idx == DOMAIN Script

Rq(k, op, a) == [ky |-> k, op |-> op, arg |-> [a EXCEPT !.ky = k], tr |-> 0]

L0 == [pc |-> "", i |-> 0, m |-> "", n |-> 0, st |-> 0, t |-> 0, a |-> 1, dk |-> "", ks |-> {},
       ek |-> "", mk |-> {}, todo |-> {}, out |-> {}, got |-> {}, wr |-> FALSE, er |-> FALSE,
       fgt |-> FALSE, mis |-> FALSE, rno |-> FALSE, rd |-> 0, hb |-> It0, hk |-> "", ret |-> "", rides |-> {},
       vp |-> {}, said |-> FALSE, slow |-> FALSE, cnt |-> 0, iids |-> {}, nam |-> NONE,
       npc |-> "", ntodo |-> {}, lk |-> {}, edr |-> {}, gat |-> 0, gc |-> 0, cw |-> FALSE, gu |-> FALSE]

NoIc == [m |-> "none", v |-> NoId]
IidOf(l, k) == IF k \notin Erasable \/ ~\E x \in l.iids : x.k = k THEN AnyId
               ELSE (CHOOSE x \in l.iids : x.k = k).iid
Arg(l) == [A0 EXCEPT !.c = l.i, !.n = l.n, !.st = l.st, !.t = l.t, !.a = l.a]
RidesOn(l, k) == {r.e : r \in {x \in l.rides : x.ky = k}}
TentItem(l, k) == Rq(k, "upd", [Arg(l) EXCEPT !.k = "tent", !.li = LegIdx(l.t, k), !.ends = RidesOn(l, k),
                                               !.iid = IidOf(l, k)])
Tents(l) == {TentItem(l, k) : k \in l.ks \ l.mk}
CommitItem(l, dr) == Rq(l.dk, "upd", [Arg(l) EXCEPT !.k = "commit", !.legs = l.ks, !.dr = dr,
                                                     !.ends = RidesOn(l, l.dk), !.iid = IidOf(l, l.dk)])
FenceItem(dk, n, a, fin, st, t, ci) ==
    Rq(dk, "upd", [A0 EXCEPT !.k = "fence", !.c = ci, !.n = n, !.a = a, !.fin = fin, !.st = st, !.t = t])
EndRec(n, a, out, st, t, dk) == [n |-> n, a |-> a, out |-> out, st |-> st, t |-> t, dk |-> dk]
ResItem(k, E, ci) == Rq(k, "upd", [A0 EXCEPT !.k = "res", !.c = ci, !.ends = E])
OwnEnd(l, out, a) == EndRec(l.n, a, out, l.st, l.t, l.dk)
Resolves(l, out, a) == {ResItem(k, {OwnEnd(l, out, a)}, l.i) : k \in IF out = "commit" THEN l.ks ELSE l.lk}
EditItem(l) == Rq(l.dk, "upd", [Arg(l) EXCEPT !.k = "edit", !.ek = l.ek, !.ends = RidesOn(l, l.dk),
                                              !.iid = IidOf(l, l.dk)])
EraseItem(l) == Rq(l.dk, "upd", [Arg(l) EXCEPT !.k = IF l.m = "reset" THEN "reset" ELSE "erase", !.iid = IidOf(l, l.dk),
                                               !.ends = RidesOn(l, l.dk), !.dr = l.edr])
GetItem(k, ci) == Rq(k, "get", [A0 EXCEPT !.k = "get", !.c = ci])

CallKeys(e) == CASE e.m = "tx" -> LegKeys(e.t) [] e.m \in {"edit", "erase", "reset"} -> {e.k} [] OTHER -> {}

Rebuild(l, pc, todo) ==
    CASE pc = "tent" -> Tents(l)
      [] pc = "edit" -> {EditItem(l)}
      [] pc = "erase" -> {EraseItem(l)}
      [] OTHER -> todo

WithIds(s, l, keys) ==
    LET need == {k \in keys \cap Erasable : ic[Host(s)][k].m = "none"}
        l2 == [l EXCEPT !.iids = {[k |-> k, iid |-> ic[Host(s)][k]] : k \in keys \cap Erasable}]
    IN IF need = {} THEN [l2 EXCEPT !.todo = Rebuild(l2, l.pc, l.todo)]
       ELSE [l EXCEPT !.npc = l.pc, !.ntodo = l.todo, !.pc = "iread", !.todo = {GetItem(k, l.i) : k \in need}]

Begin0(s, i, e, l) ==
    CASE e.m = "seed" -> [l EXCEPT !.pc = "seed",
                                      !.todo = {Rq(e.k, "upd", [A0 EXCEPT !.k = "seed", !.sb = e.sb])}]
         [] e.m = "tx" -> LET l2 == [l EXCEPT !.dk = DOf(e.t), !.ks = LegKeys(e.t) \ {DOf(e.t)}] IN
                          IF e.retry THEN [l2 EXCEPT !.pc = "rread", !.slow = TRUE, !.todo = {GetItem(l2.dk, i)}]
                          ELSE [l2 EXCEPT !.pc = "tent", !.todo = Tents(l2)]
         [] e.m = "edit" -> LET l2 == [l EXCEPT !.dk = e.k, !.ek = e.ek] IN
                            [l2 EXCEPT !.pc = "edit", !.todo = {EditItem(l2)}]
         [] e.m = "touch" -> [l EXCEPT !.pc = "tread", !.dk = e.k, !.todo = {GetItem(e.k, i)}]
         [] e.m \in {"erase", "reset"} -> [l EXCEPT !.pc = "erase", !.dk = e.k, !.todo = {EraseItem([l EXCEPT !.dk = e.k])}]

Begin(s, i) ==
    LET e == Script[i]
        st == IF e.st = NONE THEN Clock(s) ELSE e.st
        l == [L0 EXCEPT !.i = i, !.m = e.m, !.n = e.n, !.t = e.t, !.st = st]
    IN WithIds(s, Begin0(s, i, e, l), CallKeys(e))

NextOf(s) ==
    LET open == {i \in Idx : Script[i].s = s /\ i \notin started} IN
    IF open = {} THEN 0 ELSE CHOOSE i \in open : \A j \in open : i <= j

Ready(i) ==
    /\ i # 0
    /\ ~Script[i].pre => \A j \in Idx : Script[j].pre => j \in finished
    /\ Script[i].wait # 0 => Script[i].wait \in finished
    /\ Script[i].q => calm

Start(s) ==
    LET i == NextOf(s) IN
    /\ up[s] /\ ls[s].pc = "" /\ Ready(i)
    /\ ls' = [ls EXCEPT ![s] = Begin(s, i)]
    /\ started' = started \cup {i}
    /\ UNCHANGED <<envVars, finished, ans, ic, gvars>>

Send(s) ==
    LET l == ls[s] IN
    /\ \E it \in l.todo :
          /\ ~\E o \in l.out : o.ky = it.ky
          /\ CASE it.op = "upd" -> Issue(s, it.ky, it.arg)
               [] it.op = "get" -> IssueGet(s, it.ky, it.arg)
               [] it.op = "set" -> Clock(s) - it.arg.srt <= RemoveSend /\ IssueSet(s, it.ky, it.arg, Z)
          /\ ls' = [ls EXCEPT ![s].todo = @ \ {it},
                              ![s].out = @ \cup {[ky |-> it.ky, r |-> NextReq, it |-> it]},
                              ![s].cnt = @ + (IF it.op = "upd" THEN 1 ELSE 0)]
    /\ UNCHANGED <<started, finished, ans, ic, gvars>>

DropLate(s) ==
    LET l == ls[s] IN
    /\ \E it \in l.todo :
          /\ it.op = "set" /\ Clock(s) - it.arg.srt > RemoveSend
          /\ ls' = [ls EXCEPT ![s].todo = @ \ {it}]
    /\ UNCHANGED <<envVars, started, finished, ans, ic, gvars>>

Hear(s) ==
    LET l == ls[s] IN
    \E o \in l.out, a \in Heard :
       /\ Reply(o.r, a)
       /\ LET nt == NoteOf(o.r)
              again == a = "err" /\ o.it.tr < Retries
              g == [ky |-> o.ky, op |-> o.it.op, arg |-> o.it.arg, a |-> a, nt |-> nt,
                    rd |-> IF o.it.op = "get" /\ a = "ok" THEN ReadOf(o.r).v ELSE Z]
          IN ls' = [ls EXCEPT ![s].out = @ \ {o},
                              ![s].todo = IF again
                                          THEN @ \cup {[o.it EXCEPT !.tr = @ + 1,
                                                                    !.arg.iid.m = IF FixCreateOnce /\ @ = "absent"
                                                                                  THEN "id" ELSE @]}
                                          ELSE @,
                              ![s].got = IF again THEN @ ELSE @ \cup {g},
                              ![s].wr = @ \/ a = "err" \/ (o.it.op = "upd" /\ nt.w),
                              ![s].er = @ \/ a = "err",
                              ![s].cw = @ \/ (o.it.arg.k = "commit" /\ (a = "err" \/ nt.w)),
                              ![s].lk = IF o.it.arg.k = "tent" /\ (a = "err" \/ nt.w \/ nt.r = "mine")
                                        THEN @ \cup {o.ky} ELSE @]
       /\ UNCHANGED <<started, finished, ans, ic, gvars>>

NoRec == [i |-> 0, m |-> "", n |-> 0, t |-> 0, v |-> FALSE, r |-> "", rno |-> FALSE, unk |-> FALSE,
          fgt |-> FALSE, mis |-> FALSE, abs |-> FALSE, wr |-> 0, slow |-> FALSE, nam |-> NONE]
Rec(l, v, r) == [i |-> l.i, m |-> l.m, n |-> l.n, t |-> l.t, v |-> v, r |-> r, rno |-> l.rno,
                 unk |-> l.er, fgt |-> l.fgt, mis |-> l.mis,
                 abs |-> \E k \in l.ks \cup {l.dk} : ~Cur(k).ex, wr |-> l.cnt, slow |-> l.slow,
                 nam |-> l.nam]
Go(l) == {[l |-> l, say |-> FALSE, rec |-> NoRec]}
Say(l, l2, v, r) == {[l |-> [l2 EXCEPT !.said = TRUE], say |-> ~l.said, rec |-> Rec(l2, v, r)]}
Fin(l) == [l EXCEPT !.pc = "fin"]
Rp(g) == IF g.a = "err" THEN "err" ELSE g.nt.r

ResThen(l, out, a) == [l EXCEPT !.pc = "res", !.todo = Resolves(l, out, a)]
FenceFinal(l) == [l EXCEPT !.pc = "ff", !.slow = TRUE,
                           !.todo = {FenceItem(l.dk, l.n, l.a, TRUE, l.st, l.t, l.i)}]

DecOf(V, n, a, st) ==
    LET ps == Named(Pins(V), n)
        ds == {x \in V.T : x.c = "dec" /\ x.n = n}
        d == One(ds)
    IN IF ~V.ex THEN [d |-> "gone", a |-> 0]
       ELSE IF ps # {} THEN [d |-> "commit", a |-> One(ps).a]
       ELSE IF ds # {} /\ d.f = "took" THEN [d |-> "commit", a |-> d.a]
       ELSE IF ds # {} /\ d.f \in {"R", "F"} THEN [d |-> "abort", a |-> a]
       ELSE IF ds # {} /\ d.f = "fenced" /\ (d.fin \/ d.a >= a) THEN [d |-> "abort", a |-> a]
       ELSE IF Forgot(V, n, st) THEN [d |-> "abort", a |-> a]
       ELSE [d |-> "none", a |-> 0]

FenceSays(nt, a) ==
    CASE nt.r = "committed" -> [d |-> "commit", a |-> nt.fa]
      [] nt.r \in {"fenced", "refused", "forgotten"} -> [d |-> "abort", a |-> a]
      [] OTHER -> [d |-> "none", a |-> 0]

Younger(y, l) == y.st > l.st \/ (y.st = l.st /\ y.n > l.n)

Help(l, B, k, ret, clk) ==
    IF B = {} THEN Go(FenceFinal(l))
    ELSE {[l |-> [l EXCEPT !.pc = "hread", !.hb = y, !.hk = k, !.ret = ret, !.slow = TRUE, !.gc = clk,
                           !.todo = {GetItem(y.dk, l.i)}],
           say |-> FALSE, rec |-> NoRec] : y \in B}

Resend(l, ride) ==
    LET l2 == [l EXCEPT !.rd = @ + 1, !.rides = @ \cup {[ky |-> l.hk, e |-> r] : r \in ride}] IN
    CASE l.ret = "tent"   -> [l2 EXCEPT !.pc = "tent", !.todo = {TentItem(l2, l.hk)}]
      [] l.ret = "commit" -> [l2 EXCEPT !.pc = "commit", !.todo = {CommitItem(l2, {})}]
      [] l.ret = "edit"   -> [l2 EXCEPT !.pc = "edit", !.todo = {EditItem(l2)}]
      [] l.ret = "touch"  -> IF ride = {} THEN Fin(l2)
                             ELSE [l2 EXCEPT !.pc = "fin2", !.todo = {ResItem(l.hk, ride, l.i)}]

BEnd(y, d) == EndRec(y.n, IF d.d = "commit" THEN d.a ELSE y.a, d.d, y.st, y.t, y.dk)

Verify(l, ps, pc) ==
    [l EXCEPT !.pc = pc, !.vp = ps, !.slow = TRUE,
              !.todo = UNION {{ResItem(k, {EndRec(p.n, p.a, "commit", p.st, p.t, p.dk)}, l.i) : k \in p.legs}
                              : p \in ps}]
LegDone(p, k, G) == \E g \in G : g.ky = k /\ p.n \in {e.n : e \in g.arg.ends}
                                 /\ (g.a = "ok" \/ (g.a = "nil" /\ g.nt.r = "done"))
LegMissing(p, k, G) == \E g \in G : g.ky = k /\ p.n \in {e.n : e \in g.arg.ends} /\ g.a # "err"
                                    /\ g.nt.r = "missing"
Verified(l, G) == {p \in l.vp : \A k \in p.legs : LegDone(p, k, G)}
ProveLegs(l, G) ==
    IF FixPinProve /\ \A p \in l.vp : \A k \in p.legs : LegDone(p, k, G) \/ LegMissing(p, k, G)
    THEN {k \in UNION {p.legs : p \in l.vp} : \E p \in l.vp : k \in p.legs /\ LegMissing(p, k, G)}
    ELSE {}
ProveItem(k, ci) == Rq(k, "upd", [A0 EXCEPT !.k = "prove", !.c = ci])
Proved(g) == IF FixProveWrites THEN g.a = "ok" /\ g.nt.r = "proved" ELSE g.a # "err" /\ g.nt.r = "proved"
DropItem(l) == Rq(l.dk, "upd", [A0 EXCEPT !.k = "drop", !.c = l.i, !.dr = {p.n : p \in l.vp}])
Unseals(l, G) == {Rq(g.ky, "set", [A0 EXCEPT !.k = "remove", !.c = l.i, !.srt = g.nt.srt])
                  : g \in {h \in G : h.a = "ok" /\ h.nt.r = "proved"}}

Steps(s, l) ==
    LET G == l.got
        clk == Clock(s)
        g1 == One(G)
    IN
    CASE l.pc = "seed" -> Go(Fin(l))
      [] l.pc = "iread" ->
         IF \E g \in G : g.a # "ok" THEN Say(l, Fin([l EXCEPT !.er = TRUE]), FALSE, "Unresolved")
         ELSE LET got == {[k |-> g.ky, iid |-> IF g.rd.ex THEN [m |-> "id", v |-> g.rd.id]
                                               ELSE [m |-> "absent", v |-> [j |-> Job(s), n |-> l.i]]]
                          : g \in G}
                  have == {[k |-> k, iid |-> ic[Host(s)][k]] : k \in {k2 \in Erasable : ic[Host(s)][k2].m = "id"}}
                  l2 == [l EXCEPT !.iids = got \cup {x \in have : x.k \notin {y.k : y \in got}},
                                  !.pc = l.npc, !.npc = ""]
              IN Go([l2 EXCEPT !.todo = Rebuild(l2, l.npc, l.ntodo)])
      [] l.pc = "erase" ->
         LET r == Rp(g1)
             mine == g1.a = "ok" \/ (g1.a = "nil" /\ g1.nt.w)
         IN CASE r = "sealed" ->
                   LET l2 == [l EXCEPT !.nam = g1.nt.nam] IN
                   IF mine /\ g1.nt.sv = s /\ clk - g1.nt.srt <= RemoveSend
                   THEN Say(l, [l2 EXCEPT !.pc = "fin2", !.todo = {Rq(l.dk, "set", [A0 EXCEPT !.k = "remove", !.c = l.i, !.srt = g1.nt.srt])}],
                            TRUE, "")
                   ELSE Say(l, Fin(l2), TRUE, "")
              [] r = "missing" -> IF ~l.wr THEN Say(l, Fin([l EXCEPT !.mis = TRUE]), FALSE, "Missing")
                                  ELSE IF l.m = "reset" THEN Say(l, Fin([l EXCEPT !.mis = TRUE]), FALSE, "Unresolved")
                                  ELSE Say(l, Fin(l), TRUE, "")
              [] r = "took" -> Say(l, Fin([l EXCEPT !.nam = g1.nt.nam]), TRUE, "")
              [] r = "forgotten" -> IF ~l.wr \/ ~FixCleanRule
                                    THEN Say(l, Fin([l EXCEPT !.fgt = TRUE]), FALSE, "Expired")
                                    ELSE Say(l, Fin([l EXCEPT !.fgt = TRUE]), FALSE, "Unresolved")
              [] r = "gatedBy" /\ l.rd < Retries -> Go([l EXCEPT !.rd = @ + 1, !.slow = TRUE, !.todo = {EraseItem(l)}])
              [] r = "gatedBy" -> Say(l, Fin([l EXCEPT !.er = TRUE]), FALSE, "Unresolved")
              [] r = "marks" /\ l.rd <= Retries ->
                   LET M == g1.nt.it
                       fences == {FenceItem(m.dk, m.n, m.a, FALSE, m.st, m.t, l.i) : m \in {x \in M : x.c # "pin"}}
                       vers == UNION {{ResItem(k, {EndRec(p.n, p.a, "commit", p.st, p.t, p.dk)}, l.i) : k \in p.legs}
                                      : p \in {x \in M : x.c = "pin"}}
                   IN Go([l EXCEPT !.pc = "edrain", !.slow = TRUE, !.vp = {x \in M : x.c = "pin"},
                                   !.hb = [It0 EXCEPT !.legs = {x \in M : x.c # "pin"}],
                                   !.todo = fences \cup vers])
              [] r = "marks" -> Say(l, Fin([l EXCEPT !.er = TRUE]), FALSE, "Unresolved")
              [] OTHER -> Say(l, Fin(l), FALSE, "Unresolved")
      [] l.pc = "tent" ->
         LET refs == {g \in G : Rp(g) = "refused" \/ (Rp(g) = "decided" /\ g.nt.df \in {"R", "F"})}
             stored == \E g \in refs : g.a = "ok" \/ Rp(g) = "decided"
             mk2 == l.mk \cup {g.ky : g \in {h \in G : Rp(h) = "mine"
                                                    \/ (~FixCommitAfterAll /\ Rp(h) = "err")}}
             l2 == [l EXCEPT !.mk = mk2]
             oth == \E g \in G : Rp(g) \in {"other", "superseded"}
                                 \/ (Rp(g) = "decided" /\ g.nt.df \in {"took", "aborted"})
             fgt == \E g \in G : Rp(g) = "forgotten"
             blk == {g \in G : Rp(g) \in {"blocked", "noroom"}}
             mis == \E g \in G : Rp(g) = "missing"
             gtd == {g \in G : Rp(g) = "gated"}
         IN IF refs # {}
            THEN Say(l, ResThen([l2 EXCEPT !.rno = stored], "abort", l.a) , FALSE, "Refused")
            ELSE IF l.ks \subseteq mk2 THEN Go([l2 EXCEPT !.pc = "commit", !.todo = {CommitItem(l2, {})}])
            ELSE IF oth THEN Go(FenceFinal(l2))
            ELSE IF fgt
                 THEN IF ~l.wr \/ ~FixCleanRule
                      THEN Say(l, Fin([l2 EXCEPT !.fgt = TRUE]), FALSE, "Expired")
                      ELSE Go(FenceFinal([l2 EXCEPT !.fgt = TRUE]))
            ELSE IF mis
                 THEN IF ~l.wr THEN Say(l, Fin([l2 EXCEPT !.mis = TRUE]), FALSE, "Missing")
                      ELSE Go(FenceFinal([l2 EXCEPT !.mis = TRUE]))
            ELSE IF gtd # {}
                 THEN IF l.rd < Retries
                      THEN Go([l2 EXCEPT !.pc = "gwait", !.ret = "tent", !.hk = One(gtd).ky, !.slow = TRUE,
                                         !.gat = One(One(gtd).nt.it).st])
                      ELSE Go(FenceFinal(l2))
            ELSE IF blk # {}
                 THEN IF l.rd < Retries THEN Help(l2, UNION {g.nt.it : g \in blk}, One(blk).ky, "tent", clk)
                      ELSE Go(FenceFinal(l2))
            ELSE Say(l, Fin(l2), FALSE, "Unresolved")
      [] l.pc = "ff" ->
         LET r == Rp(g1) IN
         CASE r = "committed" -> Say(l, ResThen(l, "commit", g1.nt.fa), TRUE, "")
           [] r = "fenced" -> Say(l, ResThen(l, "abort", l.a), FALSE, "Spent")
           [] r = "refused" -> Say(l, ResThen([l EXCEPT !.rno = TRUE], "abort", l.a), FALSE, "Refused")
           [] r = "forgotten" -> Say(l, ResThen([l EXCEPT !.fgt = TRUE], "abort", l.a), FALSE, "Unresolved")
           [] r = "missing" /\ l.rd < Retries -> Go([FenceFinal(l) EXCEPT !.rd = @ + 1, !.mis = TRUE])
           [] r = "missing" -> Say(l, Fin([l EXCEPT !.mis = TRUE]), FALSE, "Unresolved")
           [] OTHER -> Say(l, Fin(l), FALSE, "Unresolved")
      [] l.pc = "commit" ->
         LET r == Rp(g1) IN
         CASE r = "committed" -> Say(l, ResThen(l, "commit", g1.nt.fa), TRUE, "")
           [] r = "fenced" /\ ~g1.nt.rf /\ l.a < MaxAttempts ->
                LET l2 == [l EXCEPT !.a = @ + 1, !.mk = {}, !.slow = TRUE] IN
                Go([l2 EXCEPT !.pc = "tent", !.todo = Tents(l2)])
           [] r = "fenced" \/ r = "other" -> Say(l, ResThen(l, "abort", l.a), FALSE, "Spent")
           [] r = "refused" -> Say(l, ResThen([l EXCEPT !.rno = TRUE], "abort", l.a), FALSE, "Refused")
           [] r = "forgotten" -> Go(FenceFinal([l EXCEPT !.fgt = TRUE]))
           [] r = "missing" /\ g1.a = "nil" /\ ~g1.nt.w /\ ~l.cw /\ ~FixOwnEvidence ->
                Say(l, ResThen([l EXCEPT !.mis = TRUE, !.gu = TRUE], "abort", l.a), FALSE, "Missing")
           [] r = "missing" -> Go(FenceFinal([l EXCEPT !.mis = TRUE]))
           [] r = "gated" -> IF l.rd < Retries
                             THEN Go([l EXCEPT !.pc = "gwait", !.ret = "commit", !.hk = l.dk, !.slow = TRUE,
                                               !.gat = One(g1.nt.it).st])
                             ELSE Go(FenceFinal(l))
           [] r = "owed" -> IF l.rd < Retries THEN Go(Verify(l, g1.nt.it, "ver")) ELSE Go(FenceFinal(l))
           [] r = "blocked" -> IF l.rd < Retries THEN Help(l, g1.nt.it, l.dk, "commit", clk) ELSE Go(FenceFinal(l))
           [] OTHER -> Say(l, Fin(l), FALSE, "Unresolved")
      [] l.pc = "ver" ->
         LET l2 == [l EXCEPT !.rd = @ + 1] IN
         Go([l2 EXCEPT !.pc = "commit", !.todo = {CommitItem(l2, {p.n : p \in Verified(l, G)})}])
      [] l.pc = "res" -> Go(Fin(l))
      [] l.pc = "rread" ->
         LET V == g1.rd
             d == DecOf(V, l.n, 1, l.st)
             tk == Named(Pins(V), l.n) \cup {x \in V.T : x.c = "dec" /\ x.n = l.n /\ x.f = "took"}
         IN IF g1.a = "ok" /\ d.d = "commit" /\ \A x \in tk : x.t = l.t THEN Say(l, Fin(l), TRUE, "")
            ELSE IF g1.a = "ok" /\ d.d = "commit" THEN Say(l, Fin(l), FALSE, "Spent")
            ELSE Go([l EXCEPT !.pc = "tent", !.todo = Tents(l)])
      [] l.pc = "edit" ->
         LET r == Rp(g1) IN
         CASE r = "took" -> Say(l, Fin(l), TRUE, "")
           [] r = "refused" -> Say(l, Fin([l EXCEPT !.rno = TRUE]), FALSE, "Refused")
           [] r = "other" -> Say(l, Fin(l), FALSE, "Spent")
           [] r = "forgotten" -> IF ~l.wr \/ ~FixCleanRule
                                 THEN Say(l, Fin([l EXCEPT !.fgt = TRUE]), FALSE, "Expired")
                                 ELSE Say(l, Fin([l EXCEPT !.fgt = TRUE]), FALSE, "Unresolved")
           [] r = "missing" -> IF ~l.wr THEN Say(l, Fin([l EXCEPT !.mis = TRUE]), FALSE, "Missing")
                               ELSE Say(l, Fin([l EXCEPT !.mis = TRUE]), FALSE, "Unresolved")
           [] r = "blocked" -> IF l.rd < Retries THEN Help(l, g1.nt.it, l.dk, "edit", clk)
                               ELSE Say(l, Fin([l EXCEPT !.er = TRUE]), FALSE, "Unresolved")
           [] OTHER -> Say(l, Fin(l), FALSE, "Unresolved")
      [] l.pc = "hread" ->
         LET y == l.hb
             d == DecOf(g1.rd, y.n, y.a, y.st)
         IN IF g1.a # "ok" THEN Go(Resend(l, {}))
            ELSE IF d.d = "gone" \/ g1.rd.sl
            THEN
                 IF (l.ret = "touch" \/ FixWriterOrphan) /\ (l.gc - y.st >= OrphanAge \/ ~FixOrphanAge)
                 THEN Go(Resend(l, {EndRec(y.n, y.a, "orphan", y.st, y.t, y.dk)}))
                 ELSE Go(Resend(l, {}))
            ELSE IF d.d # "none" THEN Go(Resend(l, {BEnd(y, d)}))
            ELSE IF ~FixFenceFirst THEN Go(Resend(l, {BEnd(y, [d |-> "abort", a |-> y.a])}))
            ELSE IF Younger(y, l) \/ clk - y.st >= SettleAge
                 THEN Go([l EXCEPT !.pc = "hfence", !.todo = {FenceItem(y.dk, y.n, y.a, FALSE, y.st, y.t, l.i)}])
            ELSE Go([l EXCEPT !.pc = "hwait"])
      [] l.pc = "edrain" ->
         LET fe(m) == {g \in G : g.arg.k = "fence" /\ g.arg.n = m.n /\ g.ky = m.dk}
             ends == UNION {{BEnd(m, FenceSays(g.nt, m.a)) : g \in {h \in fe(m) : h.a # "err"
                                                                 /\ FenceSays(h.nt, m.a).d # "none"}}
                            : m \in l.hb.legs}
             l2 == [l EXCEPT !.rd = @ + 1, !.edr = @ \cup {p.n : p \in Verified(l, G)},
                             !.rides = @ \cup {[ky |-> l.dk, e |-> e] : e \in ends}]
             gone == {m \in l.hb.legs : \E g \in fe(m) : g.a # "err" /\ g.nt.r = "missing"
                                                          /\ clk - m.st >= OrphanAge}
         IN IF FixCutOrphan /\ gone # {}
            THEN Go([l2 EXCEPT !.pc = "eread", !.gc = clk, !.hb = [It0 EXCEPT !.legs = gone],
                               !.todo = {GetItem(m.dk, l.i) : m \in gone}])
            ELSE Go([l2 EXCEPT !.pc = "erase", !.todo = {EraseItem(l2)}])
      [] l.pc = "eread" ->
         LET shown(m) == {g \in G : g.ky = m.dk /\ g.a = "ok"
                                     /\ (DecOf(g.rd, m.n, m.a, m.st).d = "gone" \/ g.rd.sl)}
             ends == {EndRec(m.n, m.a, "orphan", m.st, m.t, m.dk)
                      : m \in {x \in l.hb.legs : shown(x) # {} /\ l.gc - x.st >= OrphanAge}}
             l2 == [l EXCEPT !.rides = @ \cup {[ky |-> l.dk, e |-> e] : e \in ends}]
         IN Go([l2 EXCEPT !.pc = "erase", !.todo = {EraseItem(l2)}])
      [] l.pc = "gwait"
 -> IF clk - l.gat >= SettleAge THEN Go(Resend(l, {})) ELSE {}
      [] l.pc = "hwait" -> IF clk - l.hb.st >= SettleAge
                           THEN Go([l EXCEPT !.pc = "hfence",
                                             !.todo = {FenceItem(l.hb.dk, l.hb.n, l.hb.a, FALSE, l.hb.st, l.hb.t, l.i)}])
                           ELSE {}
      [] l.pc = "hfence" ->
         LET d == FenceSays(g1.nt, l.hb.a) IN
         IF g1.a # "err" /\ d.d # "none" THEN Go(Resend(l, {BEnd(l.hb, d)}))
         ELSE IF ~FixFenceNotEvidence /\ l.ret = "touch" /\ g1.a # "err" /\ g1.nt.r = "missing"
                 /\ clk - l.hb.st >= OrphanAge
              THEN Go(Resend(l, {EndRec(l.hb.n, l.hb.a, "orphan", l.hb.st, l.hb.t, l.hb.dk)}))
         ELSE Go(Resend(l, {}))
      [] l.pc = "tread" ->
         LET V == g1.rd
             old == {m \in V.P : clk - m.st >= SettleAge}
         IN IF g1.a # "ok" \/ old = {} THEN Go(Fin(l))
            ELSE {[l |-> IF m.c = "pin" THEN Verify(l, {m}, "tver")
                         ELSE [l EXCEPT !.pc = "hread", !.hb = m, !.hk = l.dk, !.ret = "touch", !.gc = clk,
                                        !.todo = {GetItem(m.dk, l.i)}],
                   say |-> FALSE, rec |-> NoRec] : m \in old}
      [] l.pc = "tver" ->
         IF Verified(l, G) = l.vp
         THEN Go([l EXCEPT !.pc = "fin2", !.todo = {DropItem(l)}])
         ELSE IF ProveLegs(l, G) # {}
         THEN Go([l EXCEPT !.pc = "tprove", !.todo = {ProveItem(k, l.i) : k \in ProveLegs(l, G)}])
         ELSE Go(Fin(l))
      [] l.pc = "tprove" ->
         IF \A g \in G : Proved(g)
         THEN Go([l EXCEPT !.pc = "fin2", !.todo = {DropItem(l)} \cup Unseals(l, G)])
         ELSE Go([l EXCEPT !.pc = "fin2", !.todo = Unseals(l, G)])
      [] l.pc = "fin2" -> Go(Fin(l))

Proceed(s) ==
    LET l == ls[s] IN
    /\ up[s] /\ l.pc # "" /\ l.todo = {} /\ l.out = {}
    /\ \E nx \in Steps(s, l) :
          /\ ls' = [ls EXCEPT ![s] = IF nx.l.pc = "fin" THEN L0 ELSE [nx.l EXCEPT !.got = {}]]
          /\ finished' = IF nx.l.pc = "fin" THEN finished \cup {l.i} ELSE finished
          /\ ans' = IF nx.say THEN ans \cup {nx.rec} ELSE ans
          /\ ic' = IF l.pc = "iread"
                   THEN [ic EXCEPT ![Host(s)] = [k \in Keys |->
                           IF \E x \in nx.l.iids : x.k = k /\ x.iid.m = "id"
                           THEN (CHOOSE x \in nx.l.iids : x.k = k).iid ELSE ic[Host(s)][k]]]
                   ELSE IF LearnAtEnd /\ nx.l.pc = "fin"
                   THEN [ic EXCEPT ![Host(s)] = [k \in Keys |->
                           IF \E x \in l.iids : x.k = k /\ x.iid.m = "id"
                           THEN (CHOOSE x \in l.iids : x.k = k).iid ELSE ic[Host(s)][k]]]
                   ELSE ic
          /\ gave' = IF nx.l.gu /\ ~l.gu THEN gave \cup {[n |-> l.n, a |-> l.a, dk |-> l.dk]} ELSE gave
    /\ UNCHANGED <<envVars, started, dec, comAt, comT, committer, applied, fenced, finF, refd, made, edTook,
                   edBy, bad, edIds, late, lossOf, orph, incN>>

DForgot(n, dk, st) == LET V == Cur(dk) IN V.ex /\ Forgot(V, n, st)
NeverCommits(n, a, dk, st) ==
    \/ fenced[n][dk] >= a \/ finF[n][dk] \/ refd[n][dk] \/ orph[n][dk]
    \/ [n |-> n, a |-> a, dk |-> dk] \in gave
    \/ dec[n] = "commit" /\ comAt[n] # a
    \/ DForgot(n, dk, st)

ObsFx(k, fx) ==
    LET cs == {e \in fx : e.e = "commit"}
        aps == {e \in fx : e.e = "apply"}
        rms == {e \in fx : e.e = "rm"}
        fes == {e \in fx : e.e = "fence"}
        rjs == {e \in fx : e.e \in {"Rleg", "Rdec"}}
        eds == {e \in fx : e.e = "edit"}
        sds == {e \in fx : e.e = "seed"}
        ers == {e \in fx : e.e = "erase"}
        rcs == {e \in fx : e.e = "cut"}
        lts == {e \in fx : e.e = "late"}
        ors == {e \in fx : e.e = "orphan"}
        crs == {e \in fx : e.e = "create"}
        inc2 == incN[k] + (IF crs # {} THEN 1 ELSE 0)
        com(n) == {e \in cs : e.n = n}
        dec2 == [n \in Names |-> IF com(n) # {} THEN "commit" ELSE dec[n]]
        comAt2 == [n \in Names |-> IF com(n) # {} THEN One(com(n)).a ELSE comAt[n]]
    IN
    /\ dec' = dec2
    /\ comAt' = comAt2
    /\ comT' = [n \in Names |-> IF com(n) # {} THEN One(com(n)).t ELSE comT[n]]
    /\ committer' = [n \in Names |-> IF com(n) # {} THEN One(com(n)).c ELSE committer[n]]
    /\ applied' = [n \in Names |-> [kk \in Keys |->
                     applied[n][kk] + (IF kk = k THEN Cardinality({e \in cs \cup aps : e.n = n}) ELSE 0)]]
    /\ fenced' = [n \in Names |-> [d \in Keys |->
                     IF \E e \in fes : e.n = n /\ e.dk = d /\ e.a > fenced[n][d]
                     THEN (CHOOSE e \in fes : e.n = n /\ e.dk = d).a ELSE fenced[n][d]]]
    /\ finF' = [n \in Names |-> [d \in Keys |-> finF[n][d] \/ \E e \in fes : e.n = n /\ e.dk = d /\ e.fin]]
    /\ refd' = [n \in Names |-> [d \in Keys |-> refd[n][d] \/ \E e \in rjs : e.n = n /\ e.dk = d]]
    /\ made' = made + SumAmt(eds) + SumAmt(sds) + SumAmt(ers) + SumAmt(rcs)
    /\ incN' = [incN EXCEPT ![k] = inc2]
    /\ gave' = gave
    /\ edIds' = [n \in Names |-> edIds[n] \cup (IF \E f \in eds : f.n = n THEN {<<k, inc2>>} ELSE {})]
    /\ late' = late \cup {e.n : e \in lts}
    /\ lossOf' = [n \in Names |-> IF \E e \in ers \cup rcs : e.n = n THEN (CHOOSE e \in ers \cup rcs : e.n = n).amt
                                  ELSE lossOf[n]]
    /\ orph' = [n \in Names |-> [d \in Keys |-> orph[n][d] \/ \E e \in ors : e.n = n /\ e.dk = d]]
    /\ edTook' = [n \in Names |-> edTook[n] + Cardinality({e \in eds : e.n = n})]
    /\ edBy' = [n \in Names |-> IF \E e \in eds : e.n = n THEN (CHOOSE e \in eds : e.n = n).c ELSE edBy[n]]
    /\ bad' = bad
              \cup (IF \E e \in cs : NeverCommits(e.n, e.a, k, e.st) THEN {"CommitAfterNever"} ELSE {})
              \cup (IF \E e \in cs : dec[e.n] = "commit" THEN {"CommitTwice"} ELSE {})
              \cup (IF \E e \in aps : dec2[e.n] # "commit" \/ comAt2[e.n] # e.a THEN {"ApplyAttempt"} ELSE {})
              \cup (IF \E e \in rms : ~NeverCommits(e.n, e.a, e.dk, e.st) THEN {"EndUndecided"} ELSE {})
              \cup (IF \E e \in ers \cup rcs : lossOf[e.n] # NONE THEN {"CutTwice"} ELSE {})

Obs ==
    LET kk == {k \in Keys : ver'[k] # ver[k]} IN
    IF kk = {} THEN UNCHANGED gvars
    ELSE LET k == CHOOSE k \in kk : TRUE IN ObsFx(k, hist'[k][ver'[k]].fx)

Init ==
    /\ EnvInit(Z, 0)
    /\ ls = [s \in Servers |-> L0]
    /\ started = {}
    /\ finished = {}
    /\ ans = {}
    /\ ic = [s \in Servers |-> [k \in Keys |-> NoIc]]
    /\ dec = [n \in Names |-> "none"]
    /\ comAt = [n \in Names |-> 0]
    /\ comT = [n \in Names |-> 0]
    /\ committer = [n \in Names |-> 0]
    /\ applied = [n \in Names |-> [k \in Keys |-> 0]]
    /\ fenced = [n \in Names |-> [d \in Keys |-> 0]]
    /\ finF = [n \in Names |-> [d \in Keys |-> FALSE]]
    /\ refd = [n \in Names |-> [d \in Keys |-> FALSE]]
    /\ made = 0
    /\ edTook = [n \in Names |-> 0]
    /\ edBy = [n \in Names |-> 0]
    /\ bad = {}
    /\ edIds = [n \in Names |-> {}]
    /\ late = {}
    /\ lossOf = [n \in Names |-> NONE]
    /\ orph = [n \in Names |-> [d \in Keys |-> FALSE]]
    /\ incN = [k \in Keys |-> 0]
    /\ gave = {}

RemoveLateOK ==
    RemoveLate = NONE \/
    \A r \in DOMAIN req' :
        (req'[r].kind = "set" /\ req'[r].made # {} /\ (r \notin DOMAIN req \/ req[r].made = {}))
            => now - req'[r].at <= RemoveLate
ReadLagOK ==
    ReadLag = NONE \/
    \A r \in DOMAIN req' :
        (req'[r].kind = "get" /\ req'[r].ph = "read" /\ r \in DOMAIN req /\ req[r].ph = "sent")
            => \/ req'[r].rv = ver[req'[r].key]
               \/ curAt[req'[r].key][req'[r].rv + 1] >= now - ReadLag

EnvStep == EnvNext(Tf, MsTf, FALSE) /\ RemoveLateOK /\ ReadLagOK /\ Obs /\ UNCHANGED lvars

Next ==
    \/ EnvStep
    \/ \E s \in Servers : /\ Crash(s)
                          /\ ls' = [ls EXCEPT ![s] = L0]
                          /\ ic' = [ic EXCEPT ![s] = [k \in Keys |-> NoIc]]
                          /\ UNCHANGED <<started, finished, ans, gvars>>
    \/ /\ CrashAll
       /\ ls' = [s \in Servers |-> L0]
       /\ ic' = [s \in Servers |-> [k \in Keys |-> NoIc]]
       /\ UNCHANGED <<started, finished, ans, gvars>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<lvars, gvars>>
    \/ \E s \in Servers : Start(s) \/ Send(s) \/ DropLate(s) \/ Hear(s) \/ Proceed(s)

Spec == Init /\ [][Next]_vars

Bal(k) ==
    LET V == Cur(k) IN
    IF ~V.ex THEN 0
    ELSE V.g + SumAmt({m \in V.P : m.c = "esc" /\ dec[m.n] = "commit" /\ m.a = comAt[m.n]})

RECURSIVE SumBal(_)
SumBal(S) == IF S = {} THEN 0 ELSE LET k == One(S) IN Bal(k) + SumBal(S \ {k})

Conservation == SumBal(Keys) = made

NonNeg == \A k \in Keys : Bal(k) >= 0

MarkStands(n, a, k) == \E m \in Cur(k).P : m.c \in {"esc", "exc"} /\ m.n = n /\ m.a = a

AllOrNone ==
    \A n \in Names :
        /\ \A k \in Keys : applied[n][k] <= 1
        /\ dec[n] # "commit" => \A k \in Keys : applied[n][k] = 0
        /\ dec[n] = "commit" =>
              \A k \in Keys :
                 IF k \in LegKeys(comT[n])
                 THEN applied[n][k] = 1 \/ MarkStands(n, comAt[n], k)
                 ELSE applied[n][k] = 0
DecideOnce == "CommitAfterNever" \notin bad /\ "CommitTwice" \notin bad
MarkEndsDecided == "EndUndecided" \notin bad
ApplyRight == "ApplyAttempt" \notin bad
CutOnce == "CutTwice" \notin bad

AtMostOnce == \A n \in Names : edTook[n] <= Cardinality(edIds[n]) /\ \A k \in Keys : applied[n][k] <= 1

TrueCommitted == \A a \in ans : a.m = "tx" /\ a.v => dec[a.n] = "commit" /\ comT[a.n] = a.t
TrueEdit == \A a \in ans : a.m = "edit" /\ a.v => edTook[a.n] >= 1

Definite == {"Refused", "Spent", "Full", "Expired", "NoRoom", "Missing", "Behind", "Busy"}

NoMeansNever == \A a \in ans : a.r \in Definite => committer[a.n] # a.i /\ edBy[a.n] # a.i
NoForName ==
    \A a \in ans : a.r \in {"Refused", "Spent", "Full"} =>
        /\ a.m = "tx" => dec[a.n] # "commit" \/ (a.r = "Spent" /\ comT[a.n] # a.t)
        /\ a.m = "edit" => edTook[a.n] = 0 \/ a.r = "Spent"
RulesSaidNo == \A a \in ans : a.r = "Refused" => a.rno
ExpiredForgot == \A a \in ans : a.r = "Expired" => a.fgt

UnresolvedOnlyWhenUnknown == \A a \in ans : a.r = "Unresolved" => a.unk \/ a.fgt \/ a.mis

MissingSaysAbsent == \A a \in ans : a.r = "Missing" => a.abs

CostBound == \A a \in ans : a.m = "tx" /\ a.v /\ ~a.slow /\ ~a.unk => a.wr = Len(Legs(a.t))

Safety ==
    /\ Conservation /\ NonNeg /\ AllOrNone /\ DecideOnce /\ MarkEndsDecided /\ ApplyRight
    /\ AtMostOnce /\ TrueCommitted /\ TrueEdit /\ NoMeansNever /\ NoForName /\ RulesSaidNo
    /\ ExpiredForgot /\ UnresolvedOnlyWhenUnknown /\ CostBound

LateCreateWarned == \A n \in Names : Cardinality(edIds[n]) >= 2 => n \in late

OnceAcrossErase == \A n \in Names : edTook[n] <= 1

EraseNamed == \A a \in ans : a.m = "erase" /\ a.v /\ a.nam # NONE => lossOf[a.n] = -a.nam

NoEditTrue == ~\E a \in ans : a.m = "edit" /\ a.v

OrphanEditBlocked == edTook[2] = 0
ScriptUnfinished == ~(Idx \subseteq finished)
PinStays == ~(dec[1] = "commit" /\ ~Cur("a").ex /\ Cur("c").ex /\ Pins(Cur("c")) = {})
CutNoOrphan == ~orph[1]["c"]

DbgOrphanMade == ~(orph[1]["c"] /\ Cur("c").ex)
DbgOrphan == ~orph[1]["c"]
DbgMadeC == ~Cur("c").ex
DbgResetTrue == ~\E a \in ans : a.m = "reset" /\ a.v
DbgResetGate == ~\E k \in Keys : Cur(k).ex /\ Cur(k).G.kd = "reset" /\ Marks(Cur(k)) # {}
DbgResetAfterGate == ~\E k \in Keys : \E i \in 1..ver[k] :
    hist[k][i].G.kd = "reset" /\ \E x \in Cur(k).K : x.n = hist[k][i].G.n

====
