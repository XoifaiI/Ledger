---- MODULE Hot ----
EXTENDS Env, TLC

CONSTANTS
    Scenario,
    S0, S1,
    Ntry,
    HoldSlack,
    SerialMode,
    OpenMode,
    RemoveSend,
    RemoveLate,
    SealAge,
    FixWalkStop,
    FixMissingStop,
    FixSealHold,
    FixExpiryCheck,
    FixReleaseWrite,
    FixCreditSealed,
    FixOpenOnly,
    FixCloseEmpty,
    FixRemoveAge,
    FixCreditFinal,
    FixSerialRun

VARIABLES
    wk,
    vw,
    started,
    finished,
    ans,
    tk,
    ends,
    ss,
    mk,
    cred

vars == <<envVars, wk, vw, started, finished, ans, tk, ends, ss, mk, cred>>

NONE == -100
Parts == Keys
Order == CHOOSE f \in [0..(Cardinality(Parts) - 1) -> Parts] : \A i, j \in DOMAIN f : i # j => f[i] # f[j]
M == Cardinality(Parts)
PartAt(x, j) == Order[(x + j) % M]
StockOf(k) == IF k = Order[0] THEN S0 ELSE S1
TotalStock == IF M = 1 THEN S0 ELSE S0 + S1
LoOf(k) == IF k = Order[0] THEN 0 ELSE S0

Z == [ex |-> FALSE, u |-> 0, sold |-> 0, sealed |-> FALSE, closed |-> FALSE, holds |-> {}, T |-> {},
      h |-> NONE, q |-> 0, fx |-> {}, past |-> {}, expd |-> {}, topen |-> 0, xs |-> 0, ret |-> {}]
A0 == [kd |-> "", ky |-> "", x |-> 0, k |-> 0, st |-> 0, id |-> 0, dur |-> 0, r |-> "", w |-> FALSE,
       em |-> FALSE, to |-> 0]

MakePart(k, st) == [Z EXCEPT !.ex = TRUE, !.u = StockOf(k), !.q = 1, !.topen = st, !.xs = LoOf(k)]

RECURSIVE HeldSum(_)
HeldSum(H) == IF H = {} THEN 0 ELSE LET e == CHOOSE y \in H : TRUE IN e.k + HeldSum(H \ {e})
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

RECURSIVE Draw(_, _)
Draw(R, k) ==
    IF k = 0 THEN [R |-> R, S |-> {}]
    ELSE LET one == IF R.ret # {} THEN [R |-> [R EXCEPT !.ret = @ \ {Min(R.ret)}], s |-> Min(R.ret)]
                    ELSE [R |-> [R EXCEPT !.xs = @ + 1], s |-> R.xs]
             rest == Draw(one.R, k - 1)
         IN [R |-> rest.R, S |-> rest.S \cup {one.s}]

EndOf(k) == LoOf(k) + StockOf(k)
RunAt(f, k) == f..(f + k - 1)
NoRun(R) == [ok |-> FALSE, R |-> R, S |-> {}]
FromRet(R, k) ==
    LET firsts == {f \in R.ret : RunAt(f, k) \subseteq R.ret}
    IN IF firsts = {} THEN NoRun(R)
       ELSE [ok |-> TRUE, R |-> [R EXCEPT !.ret = @ \ RunAt(Min(firsts), k)], S |-> RunAt(Min(firsts), k)]
FromXs(R, k, e) ==
    IF R.xs + k > e THEN NoRun(R) ELSE [ok |-> TRUE, R |-> [R EXCEPT !.xs = @ + k], S |-> RunAt(R.xs, k)]
TakeRun(R, k, e) ==
    IF ~SerialMode THEN [ok |-> TRUE, R |-> R, S |-> {}]
    ELSE IF ~FixSerialRun THEN [ok |-> TRUE, R |-> Draw(R, k).R, S |-> Draw(R, k).S]
    ELSE IF FromRet(R, k).ok THEN FromRet(R, k) ELSE FromXs(R, k, e)
HoldRun(R, k, e) ==
    IF ~SerialMode THEN [ok |-> TRUE, R |-> R, S |-> {}]
    ELSE IF FromXs(R, k, e).ok THEN FromXs(R, k, e) ELSE FromRet(R, k)

Expire(R, clk) ==
    LET cand == IF FixExpiryCheck THEN R.holds ELSE {e \in R.past : e.id \notin R.expd}
        gone == {e \in cand : clk > e.end + HoldSlack}
    IN [R EXCEPT !.holds = {e \in @ : e.id \notin {g.id : g \in gone}}, !.u = @ + HeldSum(gone),
                 !.ret = @ \cup UNION {e.sr : e \in gone}, !.expd = @ \cup {e.id : e \in gone},
                 !.fx = @ \cup {[e |-> "end", id |-> e.id, how |-> "expire", k |-> e.k] : e \in gone}]

Seal(R) == IF ~OpenMode /\ R.u = 0 /\ (R.holds = {} \/ ~FixSealHold) THEN [R EXCEPT !.sealed = TRUE] ELSE R
Put(R, n) == WriteNote(Seal([R EXCEPT !.q = @ + 1]), n)

NameOf(a, k) == IF a.kd \in {"take", "fence"} THEN <<"x", a.x, k>> ELSE <<a.kd, a.id, k>>

Step(c, v) ==
    LET a == c.arg
        clk == Clock(c.srv)
        nm == NameOf(a, a.ky)
        V == IF ~v.ex /\ ~FixOpenOnly /\ a.kd # "open" THEN MakePart(a.ky, a.st) ELSE v
        R == Expire([V EXCEPT !.fx = IF ~v.ex THEN {[e |-> "made"]} ELSE {}], clk)
        held == {e \in R.T : e.n = nm}
        rec(f) == [n |-> nm, f |-> f, st |-> a.st]
        say(R1, f) == Put([R1 EXCEPT !.T = @ \cup {rec(f)}], [a EXCEPT !.r = f])
        hs == {e \in R.holds : e.id = a.id}
        e1 == CHOOSE y \in hs : TRUE
        endIt(how) == [e |-> "end", id |-> a.id, how |-> how, k |-> e1.k]
        takeOK == ~R.closed /\ ~R.sealed /\ R.u >= a.k
        noWhy == IF R.closed THEN "closed" ELSE IF R.sealed THEN "sealed"
                 ELSE IF R.u + HeldSum(R.holds) >= a.k THEN "held" ELSE "free"
        dr == TakeRun(R, a.k, EndOf(a.ky))
        hr == HoldRun(R, a.k, EndOf(a.ky))
        sold(S) == {[e |-> "ser", s |-> x, n |-> nm] : x \in S}
        empty == R.u = 0 /\ R.holds = {} /\ R.ret = {}
    IN
    IF a.kd = "open"
    THEN IF v.ex THEN CancelNote(v, [a EXCEPT !.r = "took"])
         ELSE WriteNote([MakePart(a.ky, a.st) EXCEPT !.fx = {[e |-> "made"]}], [a EXCEPT !.r = "took"])
    ELSE IF ~V.ex THEN CancelNote(v, [a EXCEPT !.r = "missing"])
    ELSE IF held # {} THEN CancelNote(v, [a EXCEPT !.r = (CHOOSE e \in held : TRUE).f, !.em = empty, !.to = R.topen])
    ELSE IF a.kd = "take" /\ a.st <= R.h THEN CancelNote(v, [a EXCEPT !.r = "forgotten"])
    ELSE CASE a.kd = "take" ->
              IF ~takeOK THEN say(R, noWhy)
              ELSE IF ~dr.ok THEN say(R, "free")
              ELSE say([dr.R EXCEPT !.u = @ - a.k, !.sold = @ + a.k,
                                    !.fx = @ \cup {[e |-> "took", x |-> a.x, k |-> a.k]} \cup sold(dr.S)], "took")
         [] a.kd = "fence" -> say(R, "fenced")
         [] a.kd = "hold" ->
              IF ~takeOK THEN say(R, noWhy)
              ELSE IF ~hr.ok THEN say(R, "free")
              ELSE LET h == [id |-> a.id, k |-> a.k, end |-> clk + a.dur, sr |-> hr.S] IN
                   say([hr.R EXCEPT !.u = @ - a.k, !.holds = @ \cup {h}, !.past = @ \cup {h}], "took")
         [] a.kd = "confirm" ->
              IF hs # {}
              THEN say([R EXCEPT !.holds = @ \ hs, !.sold = @ + e1.k,
                                 !.fx = @ \cup {endIt("confirm")} \cup sold(e1.sr)], "took")
              ELSE IF takeOK /\ dr.ok THEN say([dr.R EXCEPT !.u = @ - a.k, !.sold = @ + a.k, !.fx = @ \cup sold(dr.S)], "took")
              ELSE say(R, "gone")
         [] a.kd = "release" ->
              IF hs # {}
              THEN say([R EXCEPT !.holds = @ \ hs, !.u = @ + e1.k, !.ret = @ \cup e1.sr,
                                 !.fx = @ \cup {endIt("release")}], "took")
              ELSE IF FixReleaseWrite THEN say(R, "took")
              ELSE CancelNote(v, [a EXCEPT !.r = "took"])
         [] a.kd = "credit" ->
              IF (R.closed \/ R.sealed) /\ FixCreditSealed THEN say(R, "sealed")
              ELSE say([R EXCEPT !.u = @ + a.k, !.fx = @ \cup {[e |-> "credit", k |-> a.k]}], "took")
         [] a.kd = "close" ->
              Put([R EXCEPT !.closed = TRUE, !.T = @ \cup {rec("took")}], [a EXCEPT !.r = "took", !.em = empty, !.to = R.topen])

Tf(c, v) == Step(c, v)
MsTf(c, it) == MsCancel(c, it)

OpenLateOK ==
    RemoveLate = NONE \/
    \A r \in DOMAIN req' :
        (req'[r].arg.kd = "open" /\ req'[r].made # {} /\ (r \notin DOMAIN req \/ req[r].made # req'[r].made))
            => now - req'[r].at <= RemoveLate

E0 == [s |-> "A", m |-> "", x |-> 0, k |-> 0, id |-> 0, dur |-> 0, pre |-> FALSE, wait |-> 0, p |-> 0]
Open(s) == [E0 EXCEPT !.s = s, !.m = "open", !.pre = TRUE]
Take(s, x, k) == [E0 EXCEPT !.s = s, !.m = "take", !.x = x, !.k = k]
Hold(s, id, k, dur) == [E0 EXCEPT !.s = s, !.m = "hold", !.id = id, !.k = k, !.dur = dur]
Confirm(s, id, k) == [E0 EXCEPT !.s = s, !.m = "confirm", !.id = id, !.k = k]
Release(s, id) == [E0 EXCEPT !.s = s, !.m = "release", !.id = id]
Credit(s, id, p, k) == [E0 EXCEPT !.s = s, !.m = "credit", !.id = id, !.p = p, !.k = k]
Close(s) == [E0 EXCEPT !.s = s, !.m = "close"]
After(e, i) == [e EXCEPT !.wait = i]

Script ==
    CASE Scenario = "Walk" -> << Open("A"), Take("A", 2, 1), Take("B", 2, 1), Take("B", 1, 2) >>
      [] Scenario = "Hold" -> << Open("A"), Hold("A", 1, 2, 2), Take("B", 2, 1), Take("B", 3, 1), Release("A", 1) >>
      [] Scenario = "Confirm" -> << Open("A"), Hold("A", 1, 1, 0), Confirm("B", 1, 1), Release("A", 1) >>
      [] Scenario = "Serial" -> << Open("A"), Hold("A", 1, 1, 0), Take("B", 2, 1), Confirm("B", 1, 1),
                                   Release("A", 1) >>
      [] Scenario = "SerialRun" -> << Open("A"), Hold("A", 1, 1, 0), After(Take("B", 2, 1), 2),
                                      After(Hold("A", 2, 1, 0), 3), Release("A", 1), Release("A", 2),
                                      After(Take("B", 4, 2), 6), Take("B", 6, 2) >>
      [] Scenario = "Credit" -> << Open("A"), Take("A", 2, 2), Take("A", 1, 1), Take("B", 3, 1),
                                   After(Credit("B", 9, 0, 1), 4) >>
      [] Scenario = "Close" -> << Open("A"), Take("A", 2, 2), After(Close("B"), 2) >>
      [] Scenario = "CreditClose" -> << Open("A"), Take("A", 2, 2), Credit("A", 9, 0, 1), After(Close("B"), 2) >>
      [] Scenario = "CreditEarly" -> << Open("A"), Credit("A", 9, 0, 1), Take("A", 2, 2), Take("B", 3, 1),
                                        Take("B", 5, 1) >>
Idx == DOMAIN Script

W0 == [i |-> 0, x |-> 0, j |-> 0, r |-> 0, tries |-> 0, st |-> 0, ph |-> ""]

NextOf(s) == LET open == {i \in Idx : Script[i].s = s /\ i \notin started} IN
             IF open = {} THEN 0 ELSE CHOOSE i \in open : \A j \in open : i <= j
Ready(i) == /\ i # 0
            /\ ~Script[i].pre => \A j \in Idx : Script[j].pre => j \in finished
            /\ Script[i].wait # 0 => Script[i].wait \in finished

ReqOf(s) ==
    LET w == wk[s]
        e == Script[w.i]
        p == PartAt(w.x, w.j)
    IN CASE e.m \in {"open", "close"} -> [k |-> Order[w.j], a |-> [A0 EXCEPT !.kd = e.m, !.st = w.st]]
         [] e.m = "take" -> [k |-> p, a |-> [A0 EXCEPT !.kd = IF p \in vw[s] THEN "fence" ELSE "take",
                                                        !.x = w.x, !.k = e.k, !.st = w.st]]
         [] e.m = "credit" -> [k |-> Order[e.p], a |-> [A0 EXCEPT !.kd = "credit", !.id = e.id, !.k = e.k, !.st = w.st]]
         [] OTHER        -> [k |-> Order[0], a |-> [A0 EXCEPT !.kd = e.m, !.id = e.id, !.k = e.k, !.dur = e.dur,
                                                                   !.st = w.st]]

Begin(s) ==
    LET i == NextOf(s) IN
    /\ Ready(i) /\ up[s] /\ wk[s].i = 0
    /\ wk' = [wk EXCEPT ![s] = [W0 EXCEPT !.i = i, !.x = Script[i].x, !.st = Clock(s)]]
    /\ started' = started \cup {i}
    /\ UNCHANGED <<envVars, vw, finished, ans, tk, ends, ss, mk, cred>>

Say(s, w, r) ==
    /\ ans' = ans \cup {[c |-> w.i, m |-> Script[w.i].m, x |-> w.x, id |-> Script[w.i].id, r |-> r]}
    /\ finished' = finished \cup {w.i}
    /\ wk' = [wk EXCEPT ![s] = W0]

Go(s, w) == wk' = [wk EXCEPT ![s] = w] /\ UNCHANGED <<ans, finished>>

SendOp(s) ==
    LET w == wk[s]
        e == Script[w.i]
    IN
    /\ w.i # 0 /\ w.r = 0
    /\ IF e.m = "open" /\ Clock(s) - w.st > RemoveSend
       THEN Say(s, w, "Unresolved") /\ UNCHANGED envVars
       ELSE IF e.m = "credit" /\ ~OpenMode /\ FixCreditFinal
       THEN Say(s, w, "throw") /\ UNCHANGED envVars
       ELSE /\ IF w.ph = "rm" THEN IssueSet(s, Order[w.j], [A0 EXCEPT !.kd = "rm"], hist[Order[w.j]][0])
               ELSE Issue(s, ReqOf(s).k, [ReqOf(s).a EXCEPT !.ky = ReqOf(s).k])
            /\ wk' = [wk EXCEPT ![s].r = NextReq]
            /\ UNCHANGED <<ans, finished>>
    /\ UNCHANGED <<vw, started, tk, ends, ss, mk, cred>>

Nos == {"fenced", "sealed", "closed", "free", "held"}

Hear(s) ==
    LET w == wk[s]
        e == Script[w.i]
        p == PartAt(w.x, w.j)
    IN
    /\ w.r # 0
    /\ \E a \in Heard :
         /\ Reply(w.r, a)
         /\ LET nt == NoteOf(w.r)
                rep == nt.r
                w2 == [w EXCEPT !.r = 0]
                last == w.j + 1 >= M
                next == [w2 EXCEPT !.j = @ + 1, !.tries = 0, !.ph = ""]
                seal == a # "err" /\ e.m = "take" /\ rep \in {"sealed", "closed"}
                vw2 == IF seal THEN vw[s] \cup {p} ELSE vw[s]
                old == Clock(s) - nt.to >= SealAge \/ ~FixRemoveAge
            IN
            /\ vw' = [vw EXCEPT ![s] = vw2]
            /\ IF w.ph = "rm"
               THEN IF last THEN Say(s, w, "true") ELSE Go(s, next)
               ELSE IF a = "err"
               THEN IF w.tries + 1 < Ntry THEN Go(s, [w2 EXCEPT !.tries = @ + 1])
                    ELSE IF e.m = "take" /\ ~FixWalkStop /\ ~last THEN Go(s, next)
                    ELSE Say(s, w, "Unresolved")
               ELSE IF e.m = "open"
               THEN IF last THEN Say(s, w, "true") ELSE Go(s, next)
               ELSE IF e.m = "close"
               THEN IF rep = "took" /\ (nt.em \/ ~FixCloseEmpty) /\ old THEN Go(s, [w2 EXCEPT !.ph = "rm"])
                    ELSE IF last THEN Say(s, w, "true") ELSE Go(s, next)
               ELSE IF e.m = "take"
               THEN CASE rep = "took" -> Say(s, w, "true")
                      [] rep \in Nos -> IF ~last THEN Go(s, next)
                                        ELSE Say(s, w, IF \A j \in 0..(M - 1) : PartAt(w.x, j) \in vw2
                                                       THEN "SoldOut" ELSE "Short")
                      [] rep = "missing" -> IF FixMissingStop \/ last THEN Say(s, w, "Missing") ELSE Go(s, next)
                      [] OTHER -> Say(s, w, "Unresolved")
               ELSE Say(s, w, IF rep = "took" THEN "true" ELSE rep)
    /\ UNCHANGED <<started, tk, ends, ss, mk, cred>>

Obs ==
    IF \A k \in Keys : ver'[k] = ver[k] THEN UNCHANGED <<tk, ends, ss, mk, cred>>
    ELSE LET k == CHOOSE y \in Keys : ver'[y] # ver[y]
             was == hist[k][ver[k]]
             V == hist'[k][ver'[k]]
             fx == IF V.ex THEN V.fx ELSE {}
             RECURSIVE CSum(_)
             CSum(F) == IF F = {} THEN 0 ELSE LET f == CHOOSE g \in F : TRUE IN f.k + CSum(F \ {f})
         IN /\ tk' = tk \cup {[x |-> f.x, k |-> k, n |-> f.k, v |-> ver'[k]] : f \in {g \in fx : g.e = "took"}}
            /\ ends' = ends \cup {[id |-> f.id, how |-> f.how, v |-> ver'[k], p |-> k] : f \in {g \in fx : g.e = "end"}}
            /\ ss' = ss \cup {[s |-> f.s, n |-> f.n] : f \in {g \in fx : g.e = "ser"}}
            /\ mk' = [mk EXCEPT ![k] = [made |-> @.made + (IF V.ex /\ ~was.ex THEN 1 ELSE 0),
                                        gone |-> IF ~V.ex /\ was.ex THEN was.sold ELSE @.gone]]
            /\ cred' = cred + CSum({g \in fx : g.e = "credit"})

Init ==
    /\ EnvInit(Z, 0)
    /\ wk = [s \in Servers |-> W0]
    /\ vw = [s \in Servers |-> {}]
    /\ started = {} /\ finished = {} /\ ans = {} /\ tk = {} /\ ends = {} /\ ss = {}
    /\ mk = [k \in Keys |-> [made |-> 0, gone |-> 0]]
    /\ cred = 0

EnvStep == EnvNext(Tf, MsTf, FALSE) /\ OpenLateOK /\ Obs /\ UNCHANGED <<wk, vw, started, finished, ans>>

Next ==
    \/ EnvStep
    \/ \E s \in Servers : /\ Crash(s)
                          /\ wk' = [wk EXCEPT ![s] = W0]
                          /\ vw' = [vw EXCEPT ![s] = {}]
                          /\ finished' = finished \cup (IF wk[s].i # 0 THEN {wk[s].i} ELSE {})
                          /\ UNCHANGED <<started, ans, tk, ends, ss, mk, cred>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<wk, vw, started, finished, ans, tk, ends, ss, mk, cred>>
    \/ \E s \in Servers : Begin(s) \/ SendOp(s) \/ Hear(s)

Spec == Init /\ [][Next]_vars

Cur2(k) == hist[k][ver[k]]
RECURSIVE UnitsOf(_)
UnitsOf(P) == IF P = {} THEN 0
              ELSE LET k == CHOOSE p \in P : TRUE
                       V == Cur2(k)
                   IN (IF V.ex THEN V.u + HeldSum(V.holds) + V.sold
                       ELSE IF mk[k].made = 0 THEN StockOf(k) ELSE mk[k].gone) + UnitsOf(P \ {k})
Units == UnitsOf(Parts) = TotalStock + cred
MadeOnce == \A k \in Parts : mk[k].made <= 1
OnePart == \A a, b \in tk : a.x = b.x => a.k = b.k
SubOnce == \A a, b \in tk : a.x = b.x /\ a.k = b.k => a = b
SerialOnce == \A a, b \in ss : a.s = b.s => a = b
SerialRun == \A n \in {a.n : a \in ss} :
    LET S == {a.s : a \in {b \in ss : b.n = n}} IN S = RunAt(Min(S), Cardinality(S))
SoldOutTrue == \A a \in ans : a.r = "SoldOut" =>
    /\ \A k \in Parts : Cur2(k).ex => Cur2(k).u = 0 /\ Cur2(k).holds = {}
    /\ ~\E t \in tk : t.x = a.x
HoldEndsOnce == \A a, b \in ends : a.id = b.id => a = b
ReleaseTrue == \A a \in ans : a.m = "release" /\ a.r = "true" =>
    ~\E k \in Parts : \E e \in Cur2(k).holds : e.id = a.id

UnitsWithinStock == OpenMode \/ UnitsOf(Parts) <= TotalStock

ScriptUnfinished == ~(Idx \subseteq finished)
====
