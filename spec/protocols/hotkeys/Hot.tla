---------------------------------- MODULE Hot ----------------------------------
\* Hot is the split quantity of the hot keys design (section 2),
\* over env/Env.tla (a copy sits beside it): parts, the walk, the seal,
\* holds (H1), and serial numbers, credits, Open and Close with removal
\* (H2).
\*
\* WHAT IS MODELLED
\*
\* The parts of one final quantity are the keys in Keys, must exist: only
\* an open op makes one, with its share of the stock and t_open (2.1), and
\* every other op on no key reports missing. A part's value keeps the free
\* units u, sold, sealed and closed, the holds [id, k, end, sr], the timed
\* room T of names with their fates and its horizon h, t_open, and in
\* serial mode the next serial xs and the returned serials ret (2.2). Every
\* op carries a name: a take or a fence its sub name x.p, any other op its
\* kind and id; a name held in T reports its stored fate and changes
\* nothing (the record's dedupe, which Rec.tla checks with the horizon).
\* Every write first expires holds whose end its clock has passed by
\* HoldSlack, their units back to u and their serials to ret. Then its op,
\* as 2.3 has it: take (refusals written with their reason), fence, hold,
\* confirm (the hold if it stands, else a take of its units, else gone),
\* release (always writes), credit (a sealed or closed part refuses),
\* close. A take or confirm issues serials from ret first, then xs. In
\* final mode a write that leaves u = 0 and no hold seals the part;
\* nothing clears it. OpenMode makes the quantity open: no seal, and
\* credits make units. In final mode a credit call (Deposit) throws at the
\* call and sends nothing (FixCreditFinal; a design rule: a final
\* stock is exactly N, ever); the one credit final mode sends, the
\* receiving leg of a move of u, is a two-leg Tx that Tx.tla checks.
\*
\* The walk (2.4): a Take under a game name x tries the parts in x's order
\* under sub names. Rule W: step j goes out only once every earlier part
\* holds a definite no, a written refusal or a fence that reported fenced;
\* a part the server's view shows sealed or closed is fenced, not tried.
\* Any other report stops the walk: true, missing (Missing), forgotten, or
\* errors past Ntry (Unresolved: the call tries no other part). Past the
\* last part: SoldOut if every part is known sealed or closed, else Short.
\*
\* Open and Close (2.5, design rule 31): Open sends open to every part in
\* turn under one stamp t_open, only while its clock reads at most
\* RemoveSend past it, and an open request lands at most RemoveLate after
\* it was sent (the platform bound of cuts 3.4, here on the open). Close
\* sends close to every part; a part whose note shows it empty is removed
\* with one RemoveAsync once the clock reads SealAge past t_open.
\*
\* LEFT OUT: moves and gathers (two-leg Tx, whose S1 Tx.tla checks), the
\* decider value's slot (Tx), drawn walks and SoldOut from memory, open
\* mode beyond one scenario (a credit beside Close), rates and bytes.
\*
\* PROPERTIES
\*   Units: stock plus credits = free, held and sold units over the parts,
\*   a part not made owing its share and a removed one its sold units.
\*   MadeOnce: no part is made twice. OnePart: at most one sub name of a
\*   call takes effect. SubOnce: a sub name takes effect once (S5).
\*   SerialOnce: no serial is sold twice. SoldOutTrue: after SoldOut no
\*   part holds a free or held unit and the name took nowhere.
\*   HoldEndsOnce. ReleaseTrue: Release true only when no hold under its
\*   id stands after it. UnitsWithinStock: in final mode the free, held
\*   and sold units never pass the stock (2.2's unit invariant has no
\*   credit term; W11). It implies that the units sold never pass it.
EXTENDS Env, TLC

CONSTANTS
    Scenario,        \* the script to run, a string
    S0, S1,          \* the shares of stock of the first part in the order and of the other (2.1)
    Ntry,            \* errors in a row before a step answers Unresolved
    HoldSlack,       \* 2 * Sigma, in ticks
    SerialMode,      \* the quantity has serial numbers
    OpenMode,        \* the quantity is in open mode: no seal, and a credit makes units (2.1)
    RemoveSend,      \* Open sends open only while its clock reads at most this past t_open
    RemoveLate,      \* an open request lands at most this long after it was sent (NONE: any time)
    SealAge,         \* a part is removed only once t_open is this old on the remover's clock
    FixWalkStop,     \* after Unresolved on a part the call tries no other (2.4); else it goes on
    FixMissingStop,  \* missing stops the walk (design rule 31); else it counts as a definite no
    FixSealHold,     \* a part seals only with no hold standing (2.3); else holds do not count
    FixExpiryCheck,  \* an expiry returns a hold's units only if the hold stands (2.3)
    FixReleaseWrite, \* release always writes (2.3); else it cancels when it reads no hold
    FixCreditSealed, \* a sealed or closed part refuses a credit (2.3)
    FixOpenOnly,     \* only open makes a part (design rule 31); else any op on no key makes it
    FixCloseEmpty,   \* Close removes only a part whose close note showed it empty (2.5)
    FixRemoveAge,    \* Close removes a part only once t_open is SealAge old (2.5)
    FixCreditFinal   \* in final mode a credit call (Deposit) throws at the call and sends nothing (2.3, 2.5)

VARIABLES
    wk,        \* wk[s]: the call server s works: [i, x, j, r, tries, st, ph]
    vw,        \* vw[s]: the parts server s saw sealed or closed (2.8's view; such facts stay true)
    started,   \* script items started
    finished,  \* script items answered
    ans,       \* answers. Ghost.
    tk,        \* sub names that took: [x, k, n, v]. Ghost.
    ends,      \* hold ends: [id, how, v, p]. Ghost.
    ss,        \* serials sold: [s, n]. Ghost.
    mk,        \* mk[k]: [made (times the part was made), gone (its sold units when removed)]. Ghost.
    cred       \* units credited. Ghost.

vars == <<envVars, wk, vw, started, finished, ans, tk, ends, ss, mk, cred>>

NONE == -100
Parts == Keys
Order == CHOOSE f \in [0..(Cardinality(Parts) - 1) -> Parts] : \A i, j \in DOMAIN f : i # j => f[i] # f[j]
M == Cardinality(Parts)
\* A game name's order: (x + j) mod m, the same on every server (2.4).
PartAt(x, j) == Order[(x + j) % M]
StockOf(k) == IF k = Order[0] THEN S0 ELSE S1
TotalStock == IF M = 1 THEN S0 ELSE S0 + S1
\* The serial range of a part: the first part [0, S0), the other [S0, S0 + S1) (2.1).
LoOf(k) == IF k = Order[0] THEN 0 ELSE S0

\* A part, and Step for its ops (2.3).

\* past: every hold the part ever placed, and expd the ids an expiry ended (for the expiry control).
Z == [ex |-> FALSE, u |-> 0, sold |-> 0, sealed |-> FALSE, closed |-> FALSE, holds |-> {}, T |-> {},
      h |-> NONE, q |-> 0, fx |-> {}, past |-> {}, expd |-> {}, topen |-> 0, xs |-> 0, ret |-> {}]
A0 == [kd |-> "", ky |-> "", x |-> 0, k |-> 0, st |-> 0, id |-> 0, dur |-> 0, r |-> "", w |-> FALSE,
       em |-> FALSE, to |-> 0]

MakePart(k, st) == [Z EXCEPT !.ex = TRUE, !.u = StockOf(k), !.q = 1, !.topen = st, !.xs = LoOf(k)]

RECURSIVE HeldSum(_)
HeldSum(H) == IF H = {} THEN 0 ELSE LET e == CHOOSE y \in H : TRUE IN e.k + HeldSum(H \ {e})
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

\* Draw k serials: from ret first, smallest first, then from xs (2.7). None outside serial mode.
RECURSIVE Draw(_, _)
Draw(R, k) ==
    IF k = 0 \/ ~SerialMode THEN [R |-> R, S |-> {}]
    ELSE LET one == IF R.ret # {} THEN [R |-> [R EXCEPT !.ret = @ \ {Min(R.ret)}], s |-> Min(R.ret)]
                    ELSE [R |-> [R EXCEPT !.xs = @ + 1], s |-> R.xs]
             rest == Draw(one.R, k - 1)
         IN [R |-> rest.R, S |-> rest.S \cup {one.s}]

\* Expire every hold whose end the clock has passed by HoldSlack: its units back to u, its serials to
\* ret (2.3). The control expires by the part's memory of holds placed, whether the hold stands or not.
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
        \* The control lets any op make a missing part, as "create on first write" did.
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
        dr == Draw(R, a.k)
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
              ELSE say([dr.R EXCEPT !.u = @ - a.k, !.sold = @ + a.k,
                                    !.fx = @ \cup {[e |-> "took", x |-> a.x, k |-> a.k]} \cup sold(dr.S)], "took")
         [] a.kd = "fence" -> say(R, "fenced")
         [] a.kd = "hold" ->
              IF ~takeOK THEN say(R, noWhy)
              ELSE LET h == [id |-> a.id, k |-> a.k, end |-> clk + a.dur, sr |-> dr.S] IN
                   say([dr.R EXCEPT !.u = @ - a.k, !.holds = @ \cup {h}, !.past = @ \cup {h}], "took")
         [] a.kd = "confirm" ->
              IF hs # {}
              THEN say([R EXCEPT !.holds = @ \ hs, !.sold = @ + e1.k,
                                 !.fx = @ \cup {endIt("confirm")} \cup sold(e1.sr)], "took")
              ELSE IF takeOK THEN say([dr.R EXCEPT !.u = @ - a.k, !.sold = @ + a.k, !.fx = @ \cup sold(dr.S)], "took")
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

\* Cuts 3.4's platform bound, here on an open request's landing (hot keys 2.11, design rule 31).
OpenLateOK ==
    RemoveLate = NONE \/
    \A r \in DOMAIN req' :
        \* Every landing of the request, a second one by a run after its answer too (HotCloseLate first
        \* bounded only the first, and a rerun made a removed part again).
        (req'[r].arg.kd = "open" /\ req'[r].made # {} /\ (r \notin DOMAIN req \/ req[r].made # req'[r].made))
            => now - req'[r].at <= RemoveLate

\* The scripts.

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
    \* A game-named take of 1 retried from a second server, and a take of 2 under another name.
    CASE Scenario = "Walk" -> << Open("A"), Take("A", 2, 1), Take("B", 2, 1), Take("B", 1, 2) >>
      \* A hold of 2 on the first part; takes that empty the other part and meet the hold; a release.
      [] Scenario = "Hold" -> << Open("A"), Hold("A", 1, 2, 2), Take("B", 2, 1), Take("B", 3, 1), Release("A", 1) >>
      \* A hold, its confirm from another server, and a release after it.
      [] Scenario = "Confirm" -> << Open("A"), Hold("A", 1, 1, 0), Confirm("B", 1, 1), Release("A", 1) >>
      \* Serial mode: a hold, a take beside it, the hold's confirm, and a release after it.
      [] Scenario = "Serial" -> << Open("A"), Hold("A", 1, 1, 0), Take("B", 2, 1), Confirm("B", 1, 1),
                                   Release("A", 1) >>
      \* Both parts sold out, SoldOut, then a credit to the first part.
      [] Scenario = "Credit" -> << Open("A"), Take("A", 2, 2), Take("A", 1, 1), Take("B", 3, 1),
                                   After(Credit("B", 9, 0, 1), 4) >>
      \* The first part sold out, the second not; Close once the take answered.
      [] Scenario = "Close" -> << Open("A"), Take("A", 2, 2), After(Close("B"), 2) >>
      \* Open mode: the first part sold empty, a credit to it, and Close beside the credit.
      [] Scenario = "CreditClose" -> << Open("A"), Take("A", 2, 2), Credit("A", 9, 0, 1), After(Close("B"), 2) >>
      \* A credit to an unsealed part of the final quantity, then takes that ask 4 of the stock of 3.
      [] Scenario = "CreditEarly" -> << Open("A"), Credit("A", 9, 0, 1), Take("A", 2, 2), Take("B", 3, 1),
                                        Take("B", 5, 1) >>
Idx == DOMAIN Script

\* The servers.

W0 == [i |-> 0, x |-> 0, j |-> 0, r |-> 0, tries |-> 0, st |-> 0, ph |-> ""]

NextOf(s) == LET open == {i \in Idx : Script[i].s = s /\ i \notin started} IN
             IF open = {} THEN 0 ELSE CHOOSE i \in open : \A j \in open : i <= j
Ready(i) == /\ i # 0
            /\ ~Script[i].pre => \A j \in Idx : Script[j].pre => j \in finished
            /\ Script[i].wait # 0 => Script[i].wait \in finished

\* The request a call sends next. Open and Close: part j. A take: step j of its walk, a fence of a
\* part the server's view shows sealed or closed, else a try. A credit: its part. A hold op: part 0.
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

\* Send the call's next request. Open sends only within RemoveSend of t_open, and answers Unresolved
\* past it. A removal is one RemoveAsync of the part (Close, 2.5).
SendOp(s) ==
    LET w == wk[s]
        e == Script[w.i]
    IN
    /\ w.i # 0 /\ w.r = 0
    /\ IF e.m = "open" /\ Clock(s) - w.st > RemoveSend
       THEN Say(s, w, "Unresolved") /\ UNCHANGED envVars
       \* A final quantity's Deposit throws (A11) before it sends (2.5, a design rule).
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
               \* The removal: whatever its answer, go on to the next part.
               THEN IF last THEN Say(s, w, "true") ELSE Go(s, next)
               ELSE IF a = "err"
               THEN IF w.tries + 1 < Ntry THEN Go(s, [w2 EXCEPT !.tries = @ + 1])
                    ELSE IF e.m = "take" /\ ~FixWalkStop /\ ~last THEN Go(s, next)
                    ELSE Say(s, w, "Unresolved")
               ELSE IF e.m = "open"
               THEN IF last THEN Say(s, w, "true") ELSE Go(s, next)
               \* Close: remove a part whose note showed it empty, once t_open is SealAge old.
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

\* The ghost observer.

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

\* The properties.

Cur2(k) == hist[k][ver[k]]
RECURSIVE UnitsOf(_)
UnitsOf(P) == IF P = {} THEN 0
              ELSE LET k == CHOOSE p \in P : TRUE
                       V == Cur2(k)
                   IN (IF V.ex THEN V.u + HeldSum(V.holds) + V.sold
                       ELSE IF mk[k].made = 0 THEN StockOf(k) ELSE mk[k].gone) + UnitsOf(P \ {k})
\* S1 on units: stock and credits are the free, held and sold units; a part not made yet owes its
\* share, and a removed part its sold units (a removal destroys only bookkeeping, 2.11).
Units == UnitsOf(Parts) = TotalStock + cred
\* No part is made twice (design rule 31).
MadeOnce == \A k \in Parts : mk[k].made <= 1
\* 2.4: at most one sub name of a call takes effect.
OnePart == \A a, b \in tk : a.x = b.x => a.k = b.k
\* S5 for sub names.
SubOnce == \A a, b \in tk : a.x = b.x /\ a.k = b.k => a = b
\* 2.7: no serial sold twice.
SerialOnce == \A a, b \in ss : a.s = b.s => a = b
\* 2.5: SoldOut only when every part holds no free or held unit, and the name took nowhere.
SoldOutTrue == \A a \in ans : a.r = "SoldOut" =>
    /\ \A k \in Parts : Cur2(k).ex => Cur2(k).u = 0 /\ Cur2(k).holds = {}
    /\ ~\E t \in tk : t.x = a.x
\* 2.6: a hold ends at most once.
HoldEndsOnce == \A a, b \in ends : a.id = b.id => a = b
\* 2.5: Release true only when no hold under its id stands after its landing.
ReleaseTrue == \A a \in ans : a.m = "release" /\ a.r = "true" =>
    ~\E k \in Parts : \E e \in Cur2(k).holds : e.id = a.id

\* 2.2's final unit invariant, which has no credit term, and W11: in final mode the free, held and sold
\* units never pass the stock (a design rule: a final stock is exactly N, ever). The units sold
\* are a term of UnitsOf, so they never pass it either.
UnitsWithinStock == OpenMode \/ UnitsOf(Parts) <= TotalStock

ScriptUnfinished == ~(Idx \subseteq finished)
=============================================================================
