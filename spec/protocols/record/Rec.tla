--------------------------------- MODULE Rec ---------------------------------
\* Rec is the record of the record design, part R1: one key, its
\* writers, and durable ops under every datastore fault. It extends
\* env/Env.tla (a copy sits beside it).
\*
\* WHAT IS MODELLED
\*
\* Key a holds a value cut to what the rules read: the money field g, the
\* writer entries E (one per writer: its id w, lo, the newest stamp t it
\* decided, and the fates not took above the last ack), the timed room T
\* of named entries, the untimed room U, the horizon h and the write count
\* q. Rooms are counted in items: writer entries and timed names share
\* TimedRoom (2.2: T holds both), untimed names UntimedRoom. fx is what
\* the write that made the version did, for the ghost observer only.
\*
\* A server has one writer on the key (3.1), with the id Job(s), fresh for
\* each life, as a server number is. Ops join its queue with the next
\* number and a stamp, the larger of the clock and the newest h the server
\* saw plus 1 (3.1's horizon cache). At most one request is out; each
\* carries ack and every op above it whose fate is not heard, in order
\* (3.2). Every write is one Env Issue whose transform is Step (4): per op
\* in order, the lookups (the writer's entry, a held name), the horizon,
\* ahead, the judgement (a debit may not take g below 0: R), the untimed
\* room, the record; then the entry (step 5), age and fit (steps 7, 8),
\* which raise h over every writer entry and timed name they drop. The
\* prefix rule stops the run's decisions at the first op it leaves
\* undecided. A run that decides nothing cancels (step 9). Each run's note
\* carries each op's report, h, and the closure's wrote and ran, which
\* only grow (3.3).
\*
\* Ops: minted (named by writer and number), timed (a game name with its
\* first send time), untimed (a game name with no time, judged against U).
\* The answers are table 5.1's, under the clean rule of 3.3: a no from a
\* cancel or a horizon counts only for a clean op; a clean minted op met
\* as forgotten or ahead is restamped (3.4).
\*
\* Part R2 adds, in scenarios of their own: a Reset (8.4, cuts 3) as a
\* timed name of cut kind held in K with its horizon hk, which puts g back
\* to its default and adds 1 to the cut count c; hopeful ops (5.2), which
\* ride the writer as minted ops do, carry the c of the session view they
\* were judged on, and meet rule 7; sessions (6): Load, Apply judged on
\* the view, the adoption of a state whose q is higher, and the local turn
\* of queued ops judged at an older c; reads (5.3): GetAsync through the
\* shown table, whose key may be evicted (a table full of other keys) and
\* then sets its bit, the fresh read, and DidApply with its probe.
\*
\* WHAT IS LEFT OUT, AND WHY
\*
\* The cut's gate, fences and loss events (cuts; TxCut), migrations
\* (TxBuild), existence and erase (Tx phase B), the work room (Tx), Idle
\* reads (a Load again is the same read). SeqMax and FatesMax never bind
\* with the scripts' few ops. Fingerprints are exact terms. Stamps are
\* ticks.
\*
\* PROPERTIES, by their id in the property list
\*   S5 AtMostOnce (minted and timed ops). S6 UntimedOnce: an untimed name
\*   takes effect at most once within W. S7 OneTerms: a name takes effect
\*   with one set of terms. S14 InOrder: a writer's ops take effect in
\*   number order. A2 TrueTook. A3 NoMeansNever, RulesSaidNo. A5
\*   UnresolvedOnlyWhenUnknown. And Env's EnvNoZWrite.
\*   R2: S10 NoStaleView (a hopeful op takes effect only on the cut count
\*   its view had). S13 through AtMostOnce, TrueTook and NoMeansNever on
\*   hopeful fates (a turned op never took). A7 ReadWasHeld, DidApplyTrue,
\*   DidApplyFalse. A8 NeverBack (a ghost that a show going back sets).
EXTENDS Env, TLC

CONSTANTS
    Scenario,          \* the script to run, a string
    TimedRoom,         \* items T keeps: writer entries and timed names
    UntimedRoom,       \* items U keeps
    Win,               \* W in ticks, for every kind
    Ahead,             \* in ticks
    Ntry,              \* errors in a row before a call answers Unresolved
    FixHorizonRaise,   \* a drop raises h over the stamp it drops
    FixEntryRule,      \* an entry is made only by a run that judged a minted op of its writer
    FixCleanRule,      \* a no from a cancel or a horizon counts only for a clean op
    FixRestampClean,   \* only a clean op is restamped
    FixUntimedRoom,    \* a full U refuses the next untimed name (no room); else it drops its oldest
    FixPrefix,         \* a run decides nothing after the first op it leaves undecided
    KCut,              \* cut names K keeps (K_cut)
    FixViewCut,        \* rule 7: a hopeful op whose view's cut count is not c is turned away (C)
    FixShownTable,     \* 5.3: a read below the table's q is not shown, and a key whose bit is set
                       \* is shown first from a landed write (a fresh read)
    FixProbeForFalse,  \* 5.3: DidApply answers false only from a landed probe
    FixTurnOk          \* 6: a session turns away queued ops of an older c only after "ok"

VARIABLES
    ws,        \* ws[s]: server s's writer on the key
    started,   \* the script items started
    finished,  \* the script items that answered, or ended as seeds
    ans,       \* every answer. Ghost.
    tk,        \* every effect that took: [id, tm, c, v, at, w, seq]. Ghost.
    rj,        \* every refusal written: [id, tm]. Ghost.
    hc,        \* hc[s]: the newest h server s saw (3.1's horizon cache)
    sv,        \* sv[s]: server s's session on the key: open, and the view's q, c and g
    rd,        \* rd[s]: server s's read out (a get, a fresh read or a probe): request and item
    tq,        \* tq[s]: the shown table's q for the key, NONE when the key is not in it
    bit,       \* bit[s]: the table's bit for the key, set when the key left the table
    lastShown, \* lastShown[s]: q of the state in server s's latest show. Ghost.
    back,      \* a show went back past one before it (A8). Ghost.
    unheld     \* a show of a state the key never held (A7). Ghost.

vars == <<envVars, ws, started, finished, ans, tk, rj, hc, sv, rd, tq, bit, lastShown, back, unheld>>

NONE == -100
K == "a"

ASSUME /\ TimedRoom \in Nat \ {0} /\ UntimedRoom \in Nat /\ Win \in Nat \ {0}
       /\ Ahead \in Nat /\ Ntry \in Nat \ {0} /\ KCut \in Nat \ {0}

\* The value.

\* c is the cut count, K the cut names held and hk their horizon (8.4).
Z == [ex |-> FALSE, g |-> 0, E |-> {}, T |-> {}, U |-> {}, h |-> NONE, q |-> 0, fx |-> {},
      c |-> 0, K |-> {}, hk |-> NONE]
SeedVal(b) == [Z EXCEPT !.ex = TRUE, !.g = b]
NoW == <<"", 0>>

\* What a read or a note shows of a value: its write count, cut count and money.
View(x) == [q |-> x.q, c |-> x.c, g |-> x.g]

MinOf(S) == CHOOSE x \in S : \A y \in S : x <= y
MaxOf(S) == CHOOSE x \in S : \A y \in S : x >= y

\* Minted and hopeful ops ride the writer and are named by it (5.2); the others carry a name.
Writerly(o) == o.kind \in {"minted", "hopeful"}

\* The identity of an op, the same across its sends: its writer and number when it rides the writer,
\* else its name.
OpId(w, o) == IF Writerly(o) THEN <<"m", w, o.seq>> ELSE <<o.kind, o.n, 0>>

\* Step (record 4), for one request of writer a.w.

\* A0 is every field a request argument and its note carry. vs is the state the note shows (the
\* value written, or the one a cancel read); pn and pst are a probe's name and stamp, pr its report.
A0 == [kd |-> "", w |-> NoW, ack |-> 0, ops |-> {}, sb |-> 0, reps |-> {}, h |-> NONE, wr |-> FALSE,
       ran |-> {}, vs |-> View(Z), pn |-> 0, pst |-> 0, pr |-> ""]

EntryOf(R, w) == IF \E e \in R.E : e.w = w THEN CHOOSE e \in R.E : e.w = w ELSE [w |-> NoW]
HasE(R, w) == \E e \in R.E : e.w = w
HeldT(R, n) == {x \in R.T : x.n = n}
HeldU(R, n) == {x \in R.U : x.n = n}
HeldK(R, n) == {x \in R.K : x.n = n}

\* The judgement of one op, given the value so far: [R, rep, dec, stop].
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
        \* A cut puts the state back to its default (g 0 here), adds 1 to c and holds its name in K.
        R9 == IF o.kind = "cut"
              THEN [R EXCEPT !.g = 0, !.c = @ + 1, !.K = @ \cup {[n |-> o.n, st |-> o.st, f |-> "took", tm |-> o.tm]},
                             !.fx = @ \cup {fxe}]
              ELSE [R EXCEPT !.g = IF verdict = "took" THEN @ + o.tm ELSE @, !.fx = @ \cup {fxe}]
    IN
    IF stopped THEN say("undecided", TRUE)
    \* rule 1: decided before, by this writer
    ELSE IF HasE(R, w) /\ o.seq <= E.lo
         THEN say(IF \E f \in E.fs : f.seq = o.seq THEN (CHOOSE f \in E.fs : f.seq = o.seq).f ELSE "took", FALSE)
    \* rule 2: a name held
    ELSE IF held # {}
         THEN say(IF (CHOOSE x \in held : TRUE).tm = o.tm THEN (CHOOSE x \in held : TRUE).f ELSE "Spent", FALSE)
    \* rules 3 and 4: the horizon (hk for a cut's name)
    ELSE IF o.kind \in {"timed", "cut"} /\ o.st <= H THEN say("forgotten", TRUE)
    ELSE IF Writerly(o) /\ ~HasE(R, w) /\ o.st <= R.h THEN say("forgotten", TRUE)
    \* rule 6: ahead
    ELSE IF o.kind # "untimed" /\ o.st > MaxOf({clk, H}) + Ahead THEN say("ahead", TRUE)
    \* rule 7: a hopeful op judged on a view from before a cut is turned away
    ELSE IF o.kind = "hopeful" /\ o.vc # R.c /\ FixViewCut
         THEN [R |-> [R EXCEPT !.fx = @ \cup {[fxe EXCEPT !.e = "C"]}], rep |-> "C", dec |-> TRUE, stop |-> FALSE]
    \* rule 10: the untimed room (checked here, before the effect, which is the same for a room of counts)
    ELSE IF o.kind = "untimed" /\ Cardinality(R.U) >= UntimedRoom /\ FixUntimedRoom
         THEN say("noroom", TRUE)
    \* rules 9 and 11: judge and record
    ELSE LET RU == IF o.kind = "untimed" /\ Cardinality(R.U) >= UntimedRoom /\ UntimedRoom > 0
                   THEN [R9 EXCEPT !.U = @ \ {CHOOSE x \in @ : \A y \in @ : x.at <= y.at}]
                   ELSE R9
             R11 == CASE o.kind = "timed" -> [RU EXCEPT !.T = @ \cup {[n |-> o.n, st |-> o.st, f |-> verdict, tm |-> o.tm]}]
                      [] o.kind = "untimed" /\ UntimedRoom > 0 ->
                            [RU EXCEPT !.U = @ \cup {[n |-> o.n, at |-> clk, f |-> verdict, tm |-> o.tm]}]
                      [] OTHER -> RU
         IN took(R11, verdict)

\* The ops of a request in number order, as a sequence.
RECURSIVE Sorted(_)
Sorted(S) == IF S = {} THEN << >> ELSE LET o == CHOOSE x \in S : \A y \in S : x.seq <= y.seq
                                        IN <<o>> \o Sorted(S \ {o})

\* Judge every op in order: [R, reps, dec (numbers decided), stamps decided, fates, minted9].
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

\* Step 5: the writer's entry.
WithEntry(R, a, res) ==
    LET E == EntryOf(R, a.w)
        make == HasE(R, a.w) \/ res.m9 \/ (~FixEntryRule /\ res.dec # {})
        lo == IF res.dec = {} THEN (IF HasE(R, a.w) THEN E.lo ELSE 0) ELSE MaxOf(res.dec)
        t == MaxOf(res.st \cup (IF HasE(R, a.w) THEN {E.t} ELSE {NONE}))
        fs == {f \in (IF HasE(R, a.w) THEN E.fs ELSE {}) \cup res.fs : f.seq > a.ack}
    IN IF ~make THEN R
       ELSE [R EXCEPT !.E = {e \in @ : e.w # a.w} \cup {[w |-> a.w, lo |-> lo, t |-> t, fs |-> fs]}]

Raise(h, x) == IF FixHorizonRaise /\ x > h THEN x ELSE h

\* Step 7: age. Writer entries and timed names W old go and raise h; cut names raise hk; untimed ones
\* go and raise nothing.
AgeStep(R, w, clk) ==
    LET oldE == {e \in R.E : e.w # w /\ clk - e.t >= Win}
        oldT == {x \in R.T : clk - x.st >= Win}
        oldK == {x \in R.K : clk - x.st >= Win}
        hs == {e.t : e \in oldE} \cup {x.st : x \in oldT}
    IN [R EXCEPT !.E = @ \ oldE, !.T = @ \ oldT, !.U = {x \in @ : clk - x.at < Win},
                 !.h = IF hs = {} THEN @ ELSE Raise(@, MaxOf(hs)),
                 !.K = @ \ oldK, !.hk = IF oldK = {} THEN @ ELSE Raise(@, MaxOf({x.st : x \in oldK}))]

\* Step 8: fit. While T passes TimedRoom, drop the least stamp, other than this writer's entry.
RECURSIVE FitT(_, _)
FitT(R, w) ==
    LET items == {[k |-> "e", s |-> e.t, x |-> e] : e \in {e2 \in R.E : e2.w # w}}
                 \cup {[k |-> "t", s |-> x.st, x |-> x] : x \in R.T}
    IN IF Cardinality(R.E) + Cardinality(R.T) <= TimedRoom \/ items = {} THEN R
       ELSE LET d == CHOOSE i \in items : \A j \in items : i.s <= j.s
                R1 == IF d.k = "e" THEN [R EXCEPT !.E = @ \ {d.x}] ELSE [R EXCEPT !.T = @ \ {d.x}]
            IN FitT([R1 EXCEPT !.h = Raise(@, d.s)], w)

\* And while K holds more than KCut names, drop the least and raise hk.
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
       \* A fresh read (5.3) decides nothing and always lands, adding 1 to q.
       ELSE IF a.kd = "fresh"
            THEN LET R1 == [v EXCEPT !.q = @ + 1, !.fx = {}] IN WriteNote(R1, [a EXCEPT !.vs = View(R1)])
       \* A DidApply probe (4 step 6) decides nothing, and lands when its name is neither held nor forgotten.
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

\* The scripts. A seed makes the key; every other item is an op of its
\* server's writer: kind, name, terms (a delta on g), and a stamp for a
\* timed name (NONE: the clock when it is first sent).

I0 == [s |-> "A", kind |-> "", n |-> 0, tm |-> 0, st |-> NONE, sb |-> 0, pre |-> FALSE, wait |-> 0]
Seed(b) == [I0 EXCEPT !.kind = "seed", !.sb = b, !.pre = TRUE]
Mint(s, d) == [I0 EXCEPT !.s = s, !.kind = "minted", !.tm = d]
Timed(s, n, d, st) == [I0 EXCEPT !.s = s, !.kind = "timed", !.n = n, !.tm = d, !.st = st]
Untimed(s, n, d) == [I0 EXCEPT !.s = s, !.kind = "untimed", !.n = n, !.tm = d]
After(i, e) == [e EXCEPT !.wait = i]
\* R2. A hopeful op is an Apply on the server's session; a cut is a Reset under timed name n.
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
      \* A decided op below a minted one that meets rule 4 in the same run (cheapest's round 1, section 5).
      [] Scenario = "Entry"   -> << Seed(0), Untimed("A", 1, 1), Mint("A", 1), Mint("B", 1) >>
      [] Scenario = "Mixed"   -> << Seed(1), Mint("A", -1), Timed("A", 1, 1, NONE), Mint("A", -1),
                                   Mint("B", -1), Untimed("B", 2, 1) >>
      \* R2: A's session applies two hopeful ops while B resets the key (S10, S13).
      [] Scenario = "Cut"     -> << Seed(1), Load("A"), Hope("A", -1), Cut("B", 1), Hope("A", 1) >>
      \* R2: A peeks after B's write and again after; the table may lose the key between (A8).
      [] Scenario = "Shown"   -> << Seed(1), Mint("B", 1), After(2, Peek("A")), Peek("A") >>
      \* R2: a session beside another writer, then a peek on the same server (A8 across a session).
      [] Scenario = "Session" -> << Seed(1), Load("A"), Hope("A", -1), Mint("B", 1), Release("A"), Peek("A") >>
      \* R2: DidApply of a timed name whose send may land before or after the probe (A7).
      [] Scenario = "Probe"   -> << Seed(1), Timed("A", 1, -1, 0), DidApply("B", 1, 0) >>
Idx == DOMAIN Script

\* The servers.

\* An op in a writer's queue: its number, kind, name, terms, stamp, script item, and what the server
\* knows of it: tries in a row that erred, dirty (not clean: a request that carried it erred or decided
\* it, 3.3), heard (its fate is heard), said (the call answered).
W0 == [wid |-> NoW, nxt |-> 1, ops |-> {}, ack |-> 0, out |-> 0, seed |-> 0]

Unheard(W) == {o \in W.ops : ~o.heard}

\* ack: the highest number below which every fate is heard.
AckOf(ops) == LET open == {o.seq : o \in {x \in ops : ~x.heard}} IN
              IF open = {} THEN (IF ops = {} THEN 0 ELSE MaxOf({o.seq : o \in ops})) ELSE MinOf(open) - 1

NextOf(s) ==
    LET open == {i \in Idx : Script[i].s = s /\ i \notin started} IN
    IF open = {} THEN 0 ELSE MinOf(open)

Ready(i) ==
    /\ i # 0
    /\ ~Script[i].pre => \A j \in Idx : Script[j].pre => j \in finished
    /\ Script[i].wait # 0 => Script[i].wait \in finished

\* The variables R2 adds, which the R1 actions leave alone.
rvars == <<sv, rd, tq, bit, lastShown, back, unheld>>

S0 == [on |-> FALSE, q |-> 0, c |-> 0, g |-> 0]
RD0 == [out |-> 0, i |-> 0, kd |-> ""]

\* Every answer the model records: the script item, the answer, whether the op's fate may be unknown,
\* and for a DidApply its name, whether it came from a probe, and the effects of its name up to the
\* version its request read (A7).
Ans0 == [c |-> 0, r |-> "", unk |-> FALSE, m |-> "op", n |-> 0, pr |-> FALSE, eff |-> 0]
Rec(o, r, unk) == [Ans0 EXCEPT !.c = o.c, !.r = r, !.unk = unk]

\* Start the next script item of s: a seed is sent at once; an op joins the writer's queue.
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
    \* Apply (5.2): judged on the session's view; a refusal there sends nothing, else the op is queued
    \* with the view's cut count and laid on the view.
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

\* A read (5.3, 6): Load and Peek send a GetAsync, or a fresh read when the key left the shown table
\* and its bit is set; DidApply sends its probe, or a GetAsync without FixProbeForFalse.
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

\* Send one request: every op above ack whose fate is not heard (3.2).
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

\* What the server makes of one op's report. Returns [o, say, rec]. A hopeful op's fate observer
\* says took, turned away (R, F or C), or unknown (5.2).
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

\* A show of state x by server s (5.3, 6): the ghosts of A7 and A8, and the table's q.
ShowGhosts(s, x) ==
    /\ lastShown' = [lastShown EXCEPT ![s] = x.q]
    /\ back' = (back \/ x.q < lastShown[s])
    /\ unheld' = (unheld \/ ~\E j \in 0..ver[K] : View(hist[K][j]) = x)
    /\ tq' = [tq EXCEPT ![s] = IF tq[s] = NONE THEN x.q ELSE MaxOf({tq[s], x.q})]

RECURSIVE SumTm(_)
SumTm(S) == IF S = {} THEN 0 ELSE LET o == CHOOSE x \in S : TRUE IN o.tm + SumTm(S \ {o})

\* Hear the answer to the request out.
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
                     \* 3.3: an op is clean if no request that carried it erred and no run decided it.
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
                     \* 6, after "ok": turn away every queued hopeful op judged at an older c (S10). Only after
                     \* "ok": a cancel's note may come from a rerun after the landing that took the op, whose
                     \* report the rerun replaced (RecCut in queue c6: an op that took, turned away).
                     old == IF a = "err" \/ (a # "ok" /\ FixTurnOk) THEN {}
                            ELSE {o \in ops1 : ~o.heard /\ o.kind = "hopeful" /\ o.vc < nt.vs.c}
                     turned == {[o EXCEPT !.heard = TRUE, !.said = TRUE] : o \in old}
                     ops2 == (ops1 \ old) \cup turned
                     said == {x.n.rec : x \in {y \in res : y.n.say}} \cup {Rec(o, "Turned", FALSE) : o \in {x \in old : ~x.said}}
                     \* 6, after "ok": the session takes the returned state if its q is higher, with the still
                     \* queued hopeful ops laid on top.
                     adopt == sv[s].on /\ a = "ok" /\ nt.vs.q > sv[s].q
                     queued == {o \in ops2 : ~o.heard /\ o.kind = "hopeful"}
                 IN /\ ws' = [ws EXCEPT ![s].out = 0, ![s].ops = ops2, ![s].ack = AckOf(ops2)]
                    /\ ans' = ans \cup said
                    /\ finished' = finished \cup {r.c : r \in said}
                    /\ hc' = IF a # "err" /\ nt.h > hc[s] THEN [hc EXCEPT ![s] = nt.h] ELSE hc
                    /\ IF adopt
                       THEN /\ sv' = [sv EXCEPT ![s] = [on |-> TRUE, q |-> nt.vs.q, c |-> nt.vs.c,
                                                         g |-> nt.vs.g + SumTm(queued)]]
                            /\ ShowGhosts(s, nt.vs)
                       ELSE UNCHANGED <<sv, tq, lastShown, back, unheld>>
                    /\ UNCHANGED started
    /\ UNCHANGED <<tk, rj, rd, bit>>

\* Hear the answer to the read out (5.3, 6).
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
                \* The table: a GetAsync below its q is not shown; a key absent from it with its bit set
                \* is shown only from a landed write (StartRead sent a fresh read then).
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
            \* No answer to show: read again.
            THEN /\ started' = started \ {i}
                 /\ UNCHANGED <<finished, ans, sv, tq, lastShown, back, unheld>>
            ELSE IF e.kind = "didapply"
            THEN /\ ans' = ans \cup {[Ans0 EXCEPT !.c = i, !.r = da, !.unk = TRUE, !.m = "didapply", !.n = e.n,
                                                  !.pr = (R.kd = "probe"), !.eff = eff]}
                 /\ finished' = finished \cup {i}
                 /\ UNCHANGED <<started, sv, tq, lastShown, back, unheld>>
            ELSE /\ ShowGhosts(s, vw)
                 /\ sv' = IF e.kind = "load" THEN [sv EXCEPT ![s] = [on |-> TRUE, q |-> vw.q, c |-> vw.c, g |-> vw.g]]
                          ELSE sv
                 /\ finished' = finished \cup {i}
                 /\ UNCHANGED <<started, ans>>
    /\ UNCHANGED <<ws, tk, rj, hc, bit>>

\* The table is full of other keys: the key leaves it, never while a session on it is open, and
\* sets its bit (5.3).
Evict(s) ==
    /\ tq[s] # NONE /\ ~sv[s].on
    /\ tq' = [tq EXCEPT ![s] = NONE]
    /\ bit' = [bit EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<envVars, ws, started, finished, ans, tk, rj, hc, sv, rd, lastShown, back, unheld>>

\* The ghost observer: it reads the fx of each landing and nothing else.

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

\* A crash loses the server's queue, its writer, its session, its read and its table; its next ops
\* take a new writer id (3.1), and its next life shows afresh (A8 is per server life).
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

\* The properties.

IdOfItem(i) == IF Writerly(Script[i]) THEN <<"m", NoW, 0>> ELSE <<Script[i].kind, Script[i].n, 0>>

\* S5: a minted or timed op takes effect at most once.
AtMostOnce == \A x, y \in tk : x.id = y.id /\ x.id[1] # "untimed" => x = y
\* S6: an untimed name takes effect at most once within W, as record 9 states it: on the writing
\* clocks, those the deciding runs read. In real time two takes can be closer, by the landing delay
\* and the skew (RecEntry at W = 1: a run at clock 0 lands at tick 1 beside a run at clock 1).
UntimedOnce == \A x, y \in tk : x.id = y.id /\ x.id[1] = "untimed" /\ x # y => x.ck - y.ck >= Win \/ y.ck - x.ck >= Win
\* S7: a name takes effect with one set of terms.
OneTerms == \A x, y \in tk : x.id = y.id => x.tm = y.tm
\* S14: a writer's ops take effect in number order.
\* An op's first take counts: an untimed name may take again past W (S6), and that later take is not
\* out of order (RecEntry: a retry past W takes op 1 again after op 2 took).
InOrder == \A x, y \in tk : x.w = y.w /\ x.w # NoW /\ x.seq < y.seq => \E x2 \in tk : x2.id = x.id /\ x2.w = x.w /\ x2.v <= y.v
\* A2: true only once the call's op took, with its terms (by this call, or an earlier send of its name).
TrueTook == \A a \in ans : a.m = "op" /\ a.r = "true" =>
    \E x \in tk : x.c = a.c \/ (~Writerly(Script[a.c]) /\ x.id = IdOfItem(a.c) /\ x.tm = Script[a.c].tm)
\* A3: a definite no only if nothing this call sent took effect. For a hopeful op (S13): a fate of
\* turned away only for an op that never took.
NoMeansNever == \A a \in ans : a.m = "op" /\ a.r \in Definite => ~\E x \in tk : x.c = a.c
\* A3: Refused only if a refusal of the op's terms was written.
RulesSaidNo == \A a \in ans : a.m = "op" /\ a.r = "Refused" =>
    \E x \in rj : x.tm = Script[a.c].tm /\ (Writerly(Script[a.c]) \/ x.id = IdOfItem(a.c))
\* A5: Unresolved only when a request of the op erred or a run decided it (its fate is not known).
UnresolvedOnlyWhenUnknown == \A a \in ans : a.m = "op" /\ a.r = "Unresolved" => a.unk

\* S10 NoStaleView: a hopeful op judged on a view from before a cut never takes effect after it.
NoStaleView == \A x \in tk : x.kind = "hopeful" => x.vc = x.rc
\* A7 ReadWasHeld: every state a server shows is one the key held.
ReadWasHeld == ~unheld
\* A7 DidApplyTrue: true only for a name that took effect.
DidApplyTrue == \A a \in ans : a.m = "didapply" /\ a.r = "true" => \E x \in tk : x.id = <<"timed", a.n, 0>>
\* A7 DidApplyFalse: false only from a probe, and only when no effect of the name was in the version
\* the probe read, so false speaks for that moment.
DidApplyFalse == \A a \in ans : a.m = "didapply" /\ a.r = "false" => a.pr /\ a.eff = 0
\* A8 NeverBack: what one server shows never goes back to a state older than one it showed.
NeverBack == ~back

\* Probe: some behaviour answers every item of the script.
ScriptUnfinished == ~(Idx \subseteq finished)

\* Debug probes (not in EXPECT): an op took but its server has not heard; and its entry is gone too.
DbgUnheard == ~\E s \in Servers : \E o \in ws[s].ops :
    ~o.heard /\ o.kind = "minted" /\ \E x \in tk : x.w = ws[s].wid /\ x.seq = o.seq
DbgDropped == ~\E s \in Servers : \E o \in ws[s].ops :
    ~o.heard /\ o.kind = "minted" /\ ~HasE(Cur(K), ws[s].wid) /\ \E x \in tk : x.w = ws[s].wid /\ x.seq = o.seq
DbgDirty == ~\E s \in Servers : \E o \in ws[s].ops :
    ~o.heard /\ o.dirty /\ o.kind = "minted" /\ ~HasE(Cur(K), ws[s].wid) /\ \E x \in tk : x.w = ws[s].wid /\ x.seq = o.seq
DbgErr == ~\E s \in Servers : \E o \in ws[s].ops : o.tries > 0
=============================================================================
