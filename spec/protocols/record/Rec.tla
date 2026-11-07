---- MODULE Rec ----
EXTENDS Env, TLC

CONSTANTS
    Scenario,
    TimedRoom,
    UntimedRoom,
    Win,
    Ahead,
    Ntry,
    FixHorizonRaise,
    FixEntryRule,
    FixCleanRule,
    FixRestampClean,
    FixUntimedRoom,
    FixPrefix,
    KCut,
    FixViewCut,
    FixShownTable,
    FixProbeForFalse,
    FixTurnOk,
    FixAdoptUnwritten

VARIABLES
    ws,
    started,
    finished,
    ans,
    tk,
    rj,
    hc,
    sv,
    rd,
    tq,
    bit,
    lastShown,
    back,
    unheld

vars == <<envVars, ws, started, finished, ans, tk, rj, hc, sv, rd, tq, bit, lastShown, back, unheld>>

NONE == -100
K == "a"

ASSUME /\ TimedRoom \in Nat \ {0} /\ UntimedRoom \in Nat /\ Win \in Nat \ {0}
       /\ Ahead \in Nat /\ Ntry \in Nat \ {0} /\ KCut \in Nat \ {0}

Z == [ex |-> FALSE, g |-> 0, E |-> {}, T |-> {}, U |-> {}, h |-> NONE, q |-> 0, fx |-> {},
      c |-> 0, K |-> {}, hk |-> NONE]
SeedVal(b) == [Z EXCEPT !.ex = TRUE, !.g = b]
NoW == <<"", 0>>

View(x) == [q |-> x.q, c |-> x.c, g |-> x.g]

MinOf(S) == CHOOSE x \in S : \A y \in S : x <= y
MaxOf(S) == CHOOSE x \in S : \A y \in S : x >= y

Writerly(o) == o.kind \in {"minted", "hopeful"}

OpId(w, o) == IF Writerly(o) THEN <<"m", w, o.seq>> ELSE <<o.kind, o.n, 0>>

A0 == [kd |-> "", w |-> NoW, ack |-> 0, ops |-> {}, sb |-> 0, reps |-> {}, h |-> NONE, wr |-> FALSE,
       ran |-> {}, vs |-> View(Z), pn |-> 0, pst |-> 0, pr |-> ""]

EntryOf(R, w) == IF \E e \in R.E : e.w = w THEN CHOOSE e \in R.E : e.w = w ELSE [w |-> NoW]
HasE(R, w) == \E e \in R.E : e.w = w
HeldT(R, n) == {x \in R.T : x.n = n}
HeldU(R, n) == {x \in R.U : x.n = n}
HeldK(R, n) == {x \in R.K : x.n = n}

JudgeOne(R, w, o, clk, stopped, c) ==
    LET E == EntryOf(R, w)
        took(R1, f) == [R |-> R1, rep |-> f, dec |-> TRUE, stop |-> FALSE]
        say(r, st) == [R |-> R, rep |-> r, dec |-> FALSE, stop |-> st]
        held == CASE o.kind = "timed" -> HeldT(R, o.n)
                  [] o.kind = "untimed" -> HeldU(R, o.n)
                  [] o.kind = "cut" -> HeldK(R, o.n)
                  [] OTHER -> {}
        H == IF o.kind = "cut" THEN R.hk ELSE R.h
        verdict == IF o.kind = "cut" \/ R.g + o.tm >= 0 THEN "took" ELSE "R"
        fxe == [e |-> verdict, id |-> OpId(w, o), tm |-> o.tm, c |-> o.c, w |-> w, seq |-> o.seq, ck |-> clk,
                vc |-> o.vc, rc |-> R.c, kind |-> o.kind]
        R9 == IF o.kind = "cut"
              THEN [R EXCEPT !.g = 0, !.c = @ + 1, !.K = @ \cup {[n |-> o.n, st |-> o.st, f |-> "took", tm |-> o.tm]},
                             !.fx = @ \cup {fxe}]
              ELSE [R EXCEPT !.g = IF verdict = "took" THEN @ + o.tm ELSE @, !.fx = @ \cup {fxe}]
    IN
    IF stopped THEN say("undecided", TRUE)
    ELSE IF HasE(R, w) /\ o.seq <= E.lo
         THEN say(IF \E f \in E.fs : f.seq = o.seq THEN (CHOOSE f \in E.fs : f.seq = o.seq).f ELSE "took", FALSE)
    ELSE IF held # {}
         THEN say(IF (CHOOSE x \in held : TRUE).tm = o.tm THEN (CHOOSE x \in held : TRUE).f ELSE "Spent", FALSE)
    ELSE IF o.kind \in {"timed", "cut"} /\ o.st <= H THEN say("forgotten", TRUE)
    ELSE IF Writerly(o) /\ ~HasE(R, w) /\ o.st <= R.h THEN say("forgotten", TRUE)
    ELSE IF o.kind # "untimed" /\ o.st > MaxOf({clk, H}) + Ahead THEN say("ahead", TRUE)
    ELSE IF o.kind = "hopeful" /\ o.vc # R.c /\ FixViewCut
         THEN [R |-> [R EXCEPT !.fx = @ \cup {[fxe EXCEPT !.e = "C"]}], rep |-> "C", dec |-> TRUE, stop |-> FALSE]
    ELSE IF o.kind = "untimed" /\ Cardinality(R.U) >= UntimedRoom /\ FixUntimedRoom
         THEN say("noroom", TRUE)
    ELSE LET RU == IF o.kind = "untimed" /\ Cardinality(R.U) >= UntimedRoom /\ UntimedRoom > 0
                   THEN [R9 EXCEPT !.U = @ \ {CHOOSE x \in @ : \A y \in @ : x.at <= y.at}]
                   ELSE R9
             R11 == CASE o.kind = "timed" -> [RU EXCEPT !.T = @ \cup {[n |-> o.n, st |-> o.st, f |-> verdict, tm |-> o.tm]}]
                      [] o.kind = "untimed" /\ UntimedRoom > 0 ->
                            [RU EXCEPT !.U = @ \cup {[n |-> o.n, at |-> clk, f |-> verdict, tm |-> o.tm]}]
                      [] OTHER -> RU
         IN took(R11, verdict)

RECURSIVE Sorted(_)
Sorted(S) == IF S = {} THEN << >> ELSE LET o == CHOOSE x \in S : \A y \in S : x.seq <= y.seq
                                        IN <<o>> \o Sorted(S \ {o})

RECURSIVE JudgeAll(_, _, _, _, _, _)
JudgeAll(R, w, seq, clk, stopped, acc) ==
    IF seq = << >> THEN [acc EXCEPT !.R = R]
    ELSE LET o == Head(seq)
             j == JudgeOne(R, w, o, clk, stopped, o.c)
             acc2 == [acc EXCEPT !.reps = @ \cup {[seq |-> o.seq, r |-> j.rep]},
                                 !.dec = IF j.dec THEN @ \cup {o.seq} ELSE @,
                                 !.st = IF j.dec THEN @ \cup {o.st} ELSE @,
                                 !.fs = IF j.dec /\ j.rep # "took" THEN @ \cup {[seq |-> o.seq, f |-> j.rep]} ELSE @,
                                 !.m9 = @ \/ (j.dec /\ Writerly(o))]
         IN JudgeAll(j.R, w, Tail(seq), clk, (stopped \/ j.stop) /\ FixPrefix, acc2)

WithEntry(R, a, res) ==
    LET E == EntryOf(R, a.w)
        make == HasE(R, a.w) \/ res.m9 \/ (~FixEntryRule /\ res.dec # {})
        lo == IF res.dec = {} THEN (IF HasE(R, a.w) THEN E.lo ELSE 0) ELSE MaxOf(res.dec)
        t == MaxOf(res.st \cup (IF HasE(R, a.w) THEN {E.t} ELSE {NONE}))
        fs == {f \in (IF HasE(R, a.w) THEN E.fs ELSE {}) \cup res.fs : f.seq > a.ack}
    IN IF ~make THEN R
       ELSE [R EXCEPT !.E = {e \in @ : e.w # a.w} \cup {[w |-> a.w, lo |-> lo, t |-> t, fs |-> fs]}]

Raise(h, x) == IF FixHorizonRaise /\ x > h THEN x ELSE h

AgeStep(R, w, clk) ==
    LET oldE == {e \in R.E : e.w # w /\ clk - e.t >= Win}
        oldT == {x \in R.T : clk - x.st >= Win}
        oldK == {x \in R.K : clk - x.st >= Win}
        hs == {e.t : e \in oldE} \cup {x.st : x \in oldT}
    IN [R EXCEPT !.E = @ \ oldE, !.T = @ \ oldT, !.U = {x \in @ : clk - x.at < Win},
                 !.h = IF hs = {} THEN @ ELSE Raise(@, MaxOf(hs)),
                 !.K = @ \ oldK, !.hk = IF oldK = {} THEN @ ELSE Raise(@, MaxOf({x.st : x \in oldK}))]

RECURSIVE FitT(_, _)
FitT(R, w) ==
    LET items == {[k |-> "e", s |-> e.t, x |-> e] : e \in {e2 \in R.E : e2.w # w}}
                 \cup {[k |-> "t", s |-> x.st, x |-> x] : x \in R.T}
    IN IF Cardinality(R.E) + Cardinality(R.T) <= TimedRoom \/ items = {} THEN R
       ELSE LET d == CHOOSE i \in items : \A j \in items : i.s <= j.s
                R1 == IF d.k = "e" THEN [R EXCEPT !.E = @ \ {d.x}] ELSE [R EXCEPT !.T = @ \ {d.x}]
            IN FitT([R1 EXCEPT !.h = Raise(@, d.s)], w)

RECURSIVE FitK(_)
FitK(R) ==
    IF Cardinality(R.K) <= KCut THEN R
    ELSE LET d == CHOOSE x \in R.K : \A y \in R.K : x.st <= y.st
         IN FitK([R EXCEPT !.K = @ \ {d}, !.hk = Raise(@, d.st)])

Fit(R, w) == FitK(FitT(R, w))

Step(c, v) ==
    LET a == c.arg
        clk == Clock(c.srv)
    IN IF a.kd = "seed"
       THEN IF v.ex THEN CancelNote(v, [a EXCEPT !.reps = {}, !.vs = View(v)])
            ELSE WriteNote(SeedVal(a.sb), [a EXCEPT !.wr = TRUE, !.vs = View(SeedVal(a.sb))])
       ELSE IF ~v.ex THEN CancelNote(v, [a EXCEPT !.reps = {[seq |-> o.seq, r |-> "undecided"] : o \in a.ops},
                                                 !.wr = c.note.wr, !.ran = c.note.ran, !.pr = "missing"])
       ELSE IF a.kd = "fresh"
            THEN LET R1 == [v EXCEPT !.q = @ + 1, !.fx = {}] IN WriteNote(R1, [a EXCEPT !.vs = View(R1)])
       ELSE IF a.kd = "probe"
            THEN IF HeldT(v, a.pn) # {} THEN CancelNote(v, [a EXCEPT !.pr = (CHOOSE x \in HeldT(v, a.pn) : TRUE).f,
                                                                    !.vs = View(v)])
                 ELSE IF a.pst <= v.h THEN CancelNote(v, [a EXCEPT !.pr = "forgotten", !.vs = View(v)])
                 ELSE LET R1 == [v EXCEPT !.q = @ + 1, !.fx = {}] IN
                      WriteNote(R1, [a EXCEPT !.pr = "landed", !.vs = View(R1)])
       ELSE LET res == JudgeAll([v EXCEPT !.fx = {}], a.w, Sorted(a.ops), clk, FALSE,
                                [R |-> v, reps |-> {}, dec |-> {}, st |-> {}, fs |-> {}, m9 |-> FALSE])
                R3 == Fit(AgeStep(WithEntry(res.R, a, res), a.w, clk), a.w)
                act == res.dec # {}
                nt == [a EXCEPT !.reps = res.reps, !.h = R3.h, !.wr = c.note.wr \/ act,
                                !.ran = c.note.ran \cup res.dec]
            IN IF act THEN WriteNote([R3 EXCEPT !.q = @ + 1], [nt EXCEPT !.vs = View([R3 EXCEPT !.q = @ + 1])])
               ELSE CancelNote(v, [nt EXCEPT !.h = v.h, !.vs = View(v)])

Tf(c, v) == Step(c, v)
MsTf(c, it) == MsCancel(c, it)

I0 == [s |-> "A", kind |-> "", n |-> 0, tm |-> 0, st |-> NONE, sb |-> 0, pre |-> FALSE, wait |-> 0]
Seed(b) == [I0 EXCEPT !.kind = "seed", !.sb = b, !.pre = TRUE]
Mint(s, d) == [I0 EXCEPT !.s = s, !.kind = "minted", !.tm = d]
Timed(s, n, d, st) == [I0 EXCEPT !.s = s, !.kind = "timed", !.n = n, !.tm = d, !.st = st]
Untimed(s, n, d) == [I0 EXCEPT !.s = s, !.kind = "untimed", !.n = n, !.tm = d]
After(i, e) == [e EXCEPT !.wait = i]
Hope(s, d) == [I0 EXCEPT !.s = s, !.kind = "hopeful", !.tm = d]
Cut(s, n) == [I0 EXCEPT !.s = s, !.kind = "cut", !.n = n]
Load(s) == [I0 EXCEPT !.s = s, !.kind = "load"]
Release(s) == [I0 EXCEPT !.s = s, !.kind = "release"]
Peek(s) == [I0 EXCEPT !.s = s, !.kind = "peek"]
DidApply(s, n, st) == [I0 EXCEPT !.s = s, !.kind = "didapply", !.n = n, !.st = st]

Script ==
    CASE Scenario = "Mint"    -> << Seed(1), Mint("A", -1), Mint("A", -1), Mint("A", 1), Mint("B", 1) >>
      [] Scenario = "Timed"   -> << Seed(1), Timed("A", 1, -1, 0), Timed("B", 1, -1, 0), Timed("B", 2, 1, NONE),
                                   After(2, Timed("A", 1, -1, 0)) >>
      [] Scenario = "Terms"   -> << Seed(2), Timed("A", 1, -1, 0), Timed("B", 1, 1, 0) >>
      [] Scenario = "Untimed" -> << Seed(0), Untimed("A", 1, 1), Untimed("B", 1, 1), Untimed("A", 2, 1),
                                   After(2, Untimed("B", 1, 1)) >>
      [] Scenario = "Drop"    -> << Seed(0), Mint("A", 1), Mint("B", 1) >>
      [] Scenario = "Entry"   -> << Seed(0), Untimed("A", 1, 1), Mint("A", 1), Mint("B", 1) >>
      [] Scenario = "Mixed"   -> << Seed(1), Mint("A", -1), Timed("A", 1, 1, NONE), Mint("A", -1),
                                   Mint("B", -1), Untimed("B", 2, 1) >>
      [] Scenario = "Cut"     -> << Seed(1), Load("A"), Hope("A", -1), Cut("B", 1), Hope("A", 1) >>
      [] Scenario = "Shown"   -> << Seed(1), Mint("B", 1), After(2, Peek("A")), Peek("A") >>
      [] Scenario = "Session" -> << Seed(1), Load("A"), Hope("A", -1), Mint("B", 1), Release("A"), Peek("A") >>
      [] Scenario = "Probe"   -> << Seed(1), Timed("A", 1, -1, 0), DidApply("B", 1, 0) >>
      [] Scenario = "View"    -> << Seed(1), Load("A"), Mint("B", -1), After(3, Hope("A", 1)), Hope("A", -2) >>
Idx == DOMAIN Script

W0 == [wid |-> NoW, nxt |-> 1, ops |-> {}, ack |-> 0, out |-> 0, seed |-> 0]

Unheard(W) == {o \in W.ops : ~o.heard}

AckOf(ops) == LET open == {o.seq : o \in {x \in ops : ~x.heard}} IN
              IF open = {} THEN (IF ops = {} THEN 0 ELSE MaxOf({o.seq : o \in ops})) ELSE MinOf(open) - 1

NextOf(s) ==
    LET open == {i \in Idx : Script[i].s = s /\ i \notin started} IN
    IF open = {} THEN 0 ELSE MinOf(open)

Ready(i) ==
    /\ i # 0
    /\ ~Script[i].pre => \A j \in Idx : Script[j].pre => j \in finished
    /\ Script[i].wait # 0 => Script[i].wait \in finished

rvars == <<sv, rd, tq, bit, lastShown, back, unheld>>

S0 == [on |-> FALSE, q |-> 0, c |-> 0, g |-> 0, b |-> 0]
RD0 == [out |-> 0, i |-> 0, kd |-> ""]

Ans0 == [c |-> 0, r |-> "", unk |-> FALSE, m |-> "op", n |-> 0, pr |-> FALSE, eff |-> 0]
Rec(o, r, unk) == [Ans0 EXCEPT !.c = o.c, !.r = r, !.unk = unk]

StartOp(s, i) ==
    LET e == Script[i]
        W == ws[s]
        wid == IF W.wid = NoW THEN Job(s) ELSE W.wid
        st == IF e.kind = "timed" /\ e.st # NONE THEN e.st ELSE MaxOf({Clock(s), hc[s] + 1})
        o == [seq |-> W.nxt, kind |-> e.kind, n |-> e.n, tm |-> e.tm, st |-> st, c |-> i, vc |-> 0,
              tries |-> 0, dirty |-> FALSE, heard |-> FALSE, said |-> FALSE]
    IN
    \/ /\ e.kind = "seed"
       /\ W.out = 0
       /\ Issue(s, K, [A0 EXCEPT !.kd = "seed", !.sb = e.sb])
       /\ ws' = [ws EXCEPT ![s].out = NextReq, ![s].seed = i]
       /\ UNCHANGED <<finished, ans, sv>>
    \/ /\ e.kind \in {"minted", "timed", "untimed", "cut"}
       /\ ws' = [ws EXCEPT ![s].wid = wid, ![s].nxt = @ + 1, ![s].ops = @ \cup {o}]
       /\ UNCHANGED <<envVars, finished, ans, sv>>
    \/ /\ e.kind = "hopeful"
       /\ sv[s].on
       /\ IF sv[s].g + e.tm < 0
          THEN /\ ans' = ans \cup {[Ans0 EXCEPT !.c = i, !.r = "ViewRefused", !.m = "apply"]}
               /\ finished' = finished \cup {i}
               /\ UNCHANGED <<ws, sv>>
          ELSE /\ ws' = [ws EXCEPT ![s].wid = wid, ![s].nxt = @ + 1, ![s].ops = @ \cup {[o EXCEPT !.vc = sv[s].c]}]
               /\ sv' = [sv EXCEPT ![s].g = @ + e.tm]
               /\ UNCHANGED <<finished, ans>>
       /\ UNCHANGED envVars
    \/ /\ e.kind = "release"
       /\ sv' = [sv EXCEPT ![s].on = FALSE]
       /\ finished' = finished \cup {i}
       /\ UNCHANGED <<envVars, ws, ans>>

StartRead(s, i) ==
    LET e == Script[i]
        fresh == e.kind \in {"load", "peek"} /\ tq[s] = NONE /\ bit[s] /\ FixShownTable
        probe == e.kind = "didapply" /\ FixProbeForFalse
    IN
    /\ e.kind \in {"load", "peek", "didapply"}
    /\ rd[s].out = 0
    /\ IF fresh THEN Issue(s, K, [A0 EXCEPT !.kd = "fresh"])
       ELSE IF probe THEN Issue(s, K, [A0 EXCEPT !.kd = "probe", !.pn = e.n, !.pst = e.st])
       ELSE IssueGet(s, K, [A0 EXCEPT !.kd = "get"])
    /\ rd' = [rd EXCEPT ![s] = [out |-> NextReq, i |-> i, kd |-> IF fresh THEN "fresh" ELSE IF probe THEN "probe" ELSE "get"]]
    /\ UNCHANGED <<ws, finished, ans, sv>>

Start(s) ==
    LET i == NextOf(s) IN
    /\ up[s] /\ Ready(i)
    /\ started' = started \cup {i}
    /\ \/ StartOp(s, i) /\ UNCHANGED rd
       \/ StartRead(s, i)
    /\ UNCHANGED <<tk, rj, hc, tq, bit, lastShown, back, unheld>>

Send(s) ==
    LET W == ws[s]
        carry == {o \in Unheard(W) : o.seq > W.ack}
    IN
    /\ up[s] /\ W.out = 0 /\ carry # {}
    /\ Issue(s, K, [A0 EXCEPT !.kd = "upd", !.w = W.wid, !.ack = W.ack,
                              !.ops = {[seq |-> o.seq, kind |-> o.kind, n |-> o.n, tm |-> o.tm, st |-> o.st,
                                        c |-> o.c, vc |-> o.vc] : o \in carry}])
    /\ ws' = [ws EXCEPT ![s].out = NextReq]
    /\ UNCHANGED <<started, finished, ans, tk, rj, hc, rvars>>

Definite == {"Refused", "Spent", "Expired", "NoRoom", "Turned"}

Learn(s, o, rep, nt, clean) ==
    LET fin(f, r) == [o |-> [o EXCEPT !.heard = TRUE, !.said = TRUE], say |-> ~o.said, rec |-> Rec(o, r, o.dirty)]
        keep(o2) == [o |-> o2, say |-> FALSE, rec |-> Rec(o, "", FALSE)]
        restamp == [o EXCEPT !.st = MaxOf({Clock(s), nt.h + 1})]
    IN CASE rep = "took" -> fin("took", "true")
         [] rep \in {"R", "C"} /\ o.kind = "hopeful" -> fin("turned", "Turned")
         [] rep = "R" -> fin("R", "Refused")
         [] rep = "Spent" -> fin("Spent", "Spent")
         [] rep = "forgotten" ->
              IF Writerly(o) /\ (clean \/ ~FixRestampClean) THEN keep(restamp)
              ELSE IF clean THEN fin("exp", "Expired")
              ELSE fin("unk", "Unresolved")
         [] rep = "noroom" -> IF clean THEN fin("noroom", "NoRoom") ELSE fin("unk", "Unresolved")
         [] rep = "ahead" -> IF Writerly(o) /\ clean THEN keep(restamp) ELSE keep(o)
         [] OTHER -> keep(o)

ShowGhosts(s, x) ==
    /\ lastShown' = [lastShown EXCEPT ![s] = x.q]
    /\ back' = (back \/ x.q < lastShown[s])
    /\ unheld' = (unheld \/ ~\E j \in 0..ver[K] : View(hist[K][j]) = x)
    /\ tq' = [tq EXCEPT ![s] = IF tq[s] = NONE THEN x.q ELSE MaxOf({tq[s], x.q})]

IsShownAt(s, q) == IF tq[s] = NONE THEN ~(bit[s] /\ FixShownTable) ELSE q >= tq[s]

RECURSIVE SumTm(_)
SumTm(S) == IF S = {} THEN 0 ELSE LET o == CHOOSE x \in S : TRUE IN o.tm + SumTm(S \ {o})

Hear(s) ==
    LET W == ws[s] IN
    /\ W.out # 0
    /\ \E a \in Heard :
         /\ Reply(W.out, a)
         /\ IF W.seed # 0
            THEN /\ ws' = [ws EXCEPT ![s].out = 0, ![s].seed = 0]
                 /\ finished' = IF a = "err" THEN finished ELSE finished \cup {W.seed}
                 /\ started' = IF a = "err" THEN started \ {W.seed} ELSE started
                 /\ UNCHANGED <<ans, hc, sv, tq, lastShown, back, unheld>>
            ELSE LET nt == NoteOf(W.out)
                     carried == {o \in W.ops : o.seq \in {x.seq : x \in req[W.out].arg.ops}}
                     repOf(o) == IF \E x \in nt.reps : x.seq = o.seq THEN (CHOOSE x \in nt.reps : x.seq = o.seq).r
                                 ELSE "undecided"
                     d2(o) == o.dirty \/ a = "err" \/ o.seq \in nt.ran
                     clean(o) == ~d2(o) \/ ~FixCleanRule
                     ln(o) == IF a = "err"
                              THEN LET o2 == [o EXCEPT !.dirty = TRUE, !.tries = @ + 1] IN
                                   IF o2.tries >= Ntry /\ ~o.said
                                   THEN [o |-> [o2 EXCEPT !.said = TRUE], say |-> TRUE, rec |-> Rec(o, "Unresolved", TRUE)]
                                   ELSE [o |-> o2, say |-> FALSE, rec |-> Rec(o, "", FALSE)]
                              ELSE Learn(s, [o EXCEPT !.dirty = d2(o), !.tries = 0], repOf(o), nt, clean(o))
                     res == {[old |-> o, n |-> ln(o)] : o \in carried}
                     ops1 == (W.ops \ carried) \cup {x.n.o : x \in res}
                     old == IF a = "err" \/ (a # "ok" /\ FixTurnOk) THEN {}
                            ELSE {o \in ops1 : ~o.heard /\ o.kind = "hopeful" /\ o.vc < nt.vs.c}
                     turned == {[o EXCEPT !.heard = TRUE, !.said = TRUE] : o \in old}
                     ops2 == (ops1 \ old) \cup turned
                     said == {x.n.rec : x \in {y \in res : y.n.say}} \cup {Rec(o, "Turned", FALSE) : o \in {x \in old : ~x.said}}
                     unwritten == a = "nil" /\ FixAdoptUnwritten /\ IsShownAt(s, nt.vs.q)
                     adopt == sv[s].on /\ (a = "ok" \/ unwritten) /\ nt.vs.q > sv[s].q
                     queued == {o \in ops2 : ~o.heard /\ o.kind = "hopeful"}
                     turnedAny == old # {} \/ \E x \in res : x.n.rec.r = "Turned"
                     relaid == sv[s].on /\ ~adopt /\ turnedAny
                 IN /\ ws' = [ws EXCEPT ![s].out = 0, ![s].ops = ops2, ![s].ack = AckOf(ops2)]
                    /\ ans' = ans \cup said
                    /\ finished' = finished \cup {r.c : r \in said}
                    /\ hc' = IF a # "err" /\ nt.h > hc[s] THEN [hc EXCEPT ![s] = nt.h] ELSE hc
                    /\ IF adopt
                       THEN /\ sv' = [sv EXCEPT ![s] = [on |-> TRUE, q |-> nt.vs.q, c |-> nt.vs.c,
                                                         g |-> nt.vs.g + SumTm(queued), b |-> nt.vs.g]]
                            /\ ShowGhosts(s, nt.vs)
                       ELSE /\ sv' = IF relaid THEN [sv EXCEPT ![s].g = sv[s].b + SumTm(queued)] ELSE sv
                            /\ UNCHANGED <<tq, lastShown, back, unheld>>
                    /\ UNCHANGED started
    /\ UNCHANGED <<tk, rj, rd, bit>>

ReadHear(s) ==
    LET R == rd[s]
        i == R.i
        e == Script[i]
    IN
    /\ R.out # 0
    /\ \E a \in Heard :
         /\ Reply(R.out, a)
         /\ rd' = [rd EXCEPT ![s] = RD0]
         /\ LET nt == NoteOf(R.out)
                x == IF R.kd = "get" THEN ReadOf(R.out).v ELSE hist[K][0]
                vw == IF R.kd = "get" THEN View(x) ELSE nt.vs
                gone == (R.kd = "get" /\ ~x.ex) \/ (R.kd # "get" /\ nt.pr = "missing")
                shown == R.kd = "fresh" \/ (tq[s] # NONE /\ vw.q >= tq[s])
                         \/ (tq[s] = NONE /\ (~bit[s] \/ ~FixShownTable))
                eff == Cardinality({y \in tk : y.id = <<"timed", e.n, 0>> /\ y.v <= req[R.out].rv})
                held == HeldT(x, e.n)
                da == IF R.kd = "probe"
                      THEN CASE nt.pr = "took" -> "true"
                             [] nt.pr = "forgotten" -> "Unresolved"
                             [] OTHER -> "false"
                      ELSE IF held # {} /\ (CHOOSE y \in held : TRUE).f = "took" THEN "true" ELSE "false"
            IN
            IF a = "err" \/ gone \/ (e.kind \in {"load", "peek"} /\ ~shown)
            THEN /\ started' = started \ {i}
                 /\ UNCHANGED <<finished, ans, sv, tq, lastShown, back, unheld>>
            ELSE IF e.kind = "didapply"
            THEN /\ ans' = ans \cup {[Ans0 EXCEPT !.c = i, !.r = da, !.unk = TRUE, !.m = "didapply", !.n = e.n,
                                                  !.pr = (R.kd = "probe"), !.eff = eff]}
                 /\ finished' = finished \cup {i}
                 /\ UNCHANGED <<started, sv, tq, lastShown, back, unheld>>
            ELSE /\ ShowGhosts(s, vw)
                 /\ sv' = IF e.kind = "load" THEN [sv EXCEPT ![s] = [on |-> TRUE, q |-> vw.q, c |-> vw.c, g |-> vw.g,
                                                                      b |-> vw.g]]
                          ELSE sv
                 /\ finished' = finished \cup {i}
                 /\ UNCHANGED <<started, ans>>
    /\ UNCHANGED <<ws, tk, rj, hc, bit>>

Evict(s) ==
    /\ tq[s] # NONE /\ ~sv[s].on
    /\ tq' = [tq EXCEPT ![s] = NONE]
    /\ bit' = [bit EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<envVars, ws, started, finished, ans, tk, rj, hc, sv, rd, lastShown, back, unheld>>

Obs ==
    IF ver'[K] = ver[K] THEN UNCHANGED <<tk, rj>>
    ELSE LET fx == hist'[K][ver'[K]].fx IN
         /\ tk' = tk \cup {[id |-> e.id, tm |-> e.tm, c |-> e.c, v |-> ver'[K], at |-> now, w |-> e.w, seq |-> e.seq,
                            ck |-> e.ck, kind |-> e.kind, vc |-> e.vc, rc |-> e.rc]
                           : e \in {x \in fx : x.e = "took"}}
         /\ rj' = rj \cup {[id |-> e.id, tm |-> e.tm] : e \in {x \in fx : x.e = "R"}}

Init ==
    /\ EnvInit(Z, 0)
    /\ ws = [s \in Servers |-> W0]
    /\ started = {} /\ finished = {} /\ ans = {} /\ tk = {} /\ rj = {}
    /\ hc = [s \in Servers |-> NONE]
    /\ sv = [s \in Servers |-> S0]
    /\ rd = [s \in Servers |-> RD0]
    /\ tq = [s \in Servers |-> NONE]
    /\ bit = [s \in Servers |-> FALSE]
    /\ lastShown = [s \in Servers |-> NONE]
    /\ back = FALSE /\ unheld = FALSE

EnvStep == EnvNext(Tf, MsTf, FALSE) /\ Obs /\ UNCHANGED <<ws, started, finished, ans, hc, rvars>>

Lost(s) == {o.c : o \in {x \in ws[s].ops : ~x.said}} \cup (IF ws[s].seed # 0 THEN {ws[s].seed} ELSE {})
           \cup (IF rd[s].out # 0 THEN {rd[s].i} ELSE {})

Next ==
    \/ EnvStep
    \/ \E s \in Servers : /\ Crash(s)
                          /\ ws' = [ws EXCEPT ![s] = W0]
                          /\ hc' = [hc EXCEPT ![s] = NONE]
                          /\ finished' = finished \cup Lost(s)
                          /\ sv' = [sv EXCEPT ![s] = S0]
                          /\ rd' = [rd EXCEPT ![s] = RD0]
                          /\ tq' = [tq EXCEPT ![s] = NONE]
                          /\ bit' = [bit EXCEPT ![s] = FALSE]
                          /\ lastShown' = [lastShown EXCEPT ![s] = NONE]
                          /\ UNCHANGED <<started, ans, tk, rj, back, unheld>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<ws, started, finished, ans, tk, rj, hc, rvars>>
    \/ \E s \in Servers : Start(s) \/ Send(s) \/ Hear(s) \/ ReadHear(s) \/ Evict(s)

Spec == Init /\ [][Next]_vars

IdOfItem(i) == IF Writerly(Script[i]) THEN <<"m", NoW, 0>> ELSE <<Script[i].kind, Script[i].n, 0>>

AtMostOnce == \A x, y \in tk : x.id = y.id /\ x.id[1] # "untimed" => x = y
UntimedOnce == \A x, y \in tk : x.id = y.id /\ x.id[1] = "untimed" /\ x # y => x.ck - y.ck >= Win \/ y.ck - x.ck >= Win
OneTerms == \A x, y \in tk : x.id = y.id => x.tm = y.tm
InOrder == \A x, y \in tk : x.w = y.w /\ x.w # NoW /\ x.seq < y.seq => \E x2 \in tk : x2.id = x.id /\ x2.w = x.w /\ x2.v <= y.v
TrueTook == \A a \in ans : a.m = "op" /\ a.r = "true" =>
    \E x \in tk : x.c = a.c \/ (~Writerly(Script[a.c]) /\ x.id = IdOfItem(a.c) /\ x.tm = Script[a.c].tm)
NoMeansNever == \A a \in ans : a.m = "op" /\ a.r \in Definite => ~\E x \in tk : x.c = a.c
RulesSaidNo == \A a \in ans : a.m = "op" /\ a.r = "Refused" =>
    \E x \in rj : x.tm = Script[a.c].tm /\ (Writerly(Script[a.c]) \/ x.id = IdOfItem(a.c))
UnresolvedOnlyWhenUnknown == \A a \in ans : a.m = "op" /\ a.r = "Unresolved" => a.unk

NoStaleView == \A x \in tk : x.kind = "hopeful" => x.vc = x.rc
ReadWasHeld == ~unheld
DidApplyTrue == \A a \in ans : a.m = "didapply" /\ a.r = "true" => \E x \in tk : x.id = <<"timed", a.n, 0>>
DidApplyFalse == \A a \in ans : a.m = "didapply" /\ a.r = "false" => a.pr /\ a.eff = 0
NeverBack == ~back
TookSince(s) == {x \in tk : x.kind = "hopeful" /\ x.w = ws[s].wid /\ hist[K][x.v].q > sv[s].q
                              /\ \E o \in ws[s].ops : o.seq = x.seq /\ o.heard}
ViewHoldsTook == \A s \in Servers : sv[s].on =>
    sv[s].g = sv[s].b + SumTm({o \in ws[s].ops : ~o.heard /\ o.kind = "hopeful"}) + SumTm(TookSince(s))

ScriptUnfinished == ~(Idx \subseteq finished)

DbgUnheard == ~\E s \in Servers : \E o \in ws[s].ops :
    ~o.heard /\ o.kind = "minted" /\ \E x \in tk : x.w = ws[s].wid /\ x.seq = o.seq
DbgDropped == ~\E s \in Servers : \E o \in ws[s].ops :
    ~o.heard /\ o.kind = "minted" /\ ~HasE(Cur(K), ws[s].wid) /\ \E x \in tk : x.w = ws[s].wid /\ x.seq = o.seq
DbgDirty == ~\E s \in Servers : \E o \in ws[s].ops :
    ~o.heard /\ o.dirty /\ o.kind = "minted" /\ ~HasE(Cur(K), ws[s].wid) /\ \E x \in tk : x.w = ws[s].wid /\ x.seq = o.seq
DbgErr == ~\E s \in Servers : \E o \in ws[s].ops : o.tries > 0
====
