---- MODULE Tot ----
EXTENDS Env, TLC

CONSTANTS
    Scenario,
    Ntry,
    FixNoOwn,
    FixMergeQ,
    FixNameHash,
    Reps

VARIABLES
    bw,
    bout,
    lp,
    rd,
    nf,
    hl,
    started,
    finished,
    ans,
    bk,
    ev

vars == <<envVars, bw, bout, lp, rd, nf, hl, started, finished, ans, bk, ev>>

NONE == -100
Shards == Keys
S == Cardinality(Shards)
ItemKey(r) == IF r = 0 THEN "t" ELSE "u"

Z == [ex |-> FALSE, q |-> 0, s |-> 0, done |-> {}, fx |-> {}]
A0 == [kd |-> "", id |-> <<"", "", 0>>, amt |-> 0, vs |-> [q |-> -1, s |-> 0], r |-> ""]

Step(c, v) ==
    LET a == c.arg
        V == IF v.ex THEN v ELSE [Z EXCEPT !.ex = TRUE]
    IN IF a.id \in V.done THEN CancelNote(v, [a EXCEPT !.r = "took", !.vs = [q |-> V.q, s |-> V.s]])
       ELSE LET R == [V EXCEPT !.s = @ + a.amt, !.q = @ + 1, !.done = @ \cup {a.id},
                               !.fx = {[id |-> a.id, amt |-> a.amt]}]
            IN WriteNote(R, [a EXCEPT !.r = "took", !.vs = [q |-> R.q, s |-> R.s]])

Tf(c, v) == Step(c, v)

NoPair == [q |-> -1, s |-> 0, at |-> NONE]
I0 == [pr |-> [k \in Shards |-> NoPair], hd |-> "", n |-> 0]

Merge(old, new) ==
    IF FixMergeQ THEN (IF new.q > old.q THEN new ELSE old)
    ELSE (IF new.q >= 0 /\ (old.q < 0 \/ new.at > old.at) THEN new ELSE old)

MsTf(c, it) ==
    LET cur == IF it.has THEN it.v ELSE I0
    IN MsWrite(c, [pr |-> [k \in Shards |-> Merge(cur.pr[k], c.arg.pr[k])], hd |-> c.srv, n |-> Max(cur.n, c.arg.n)])

E0 == [s |-> "A", m |-> "", n |-> 0, amt |-> 0]
Bump(s, amt) == [E0 EXCEPT !.s = s, !.m = "bump", !.amt = amt]
NBump(s, n, amt) == [E0 EXCEPT !.s = s, !.m = "bump", !.n = n, !.amt = amt]
Total(s) == [E0 EXCEPT !.s = s, !.m = "total"]

Script ==
    CASE Scenario = "Two"  -> << Bump("A", 1), Bump("B", 2), Total("A"), Bump("A", 4), Total("B") >>
      [] Scenario = "Name" -> << NBump("A", 1, 1), NBump("B", 1, 1), Bump("B", 2), Total("A"), Total("B") >>
Idx == DOMAIN Script

Order == CHOOSE f \in [1..S -> Shards] : \A i, j \in 1..S : i # j => f[i] # f[j]
Home(s) == IF s = "A" \/ S = 1 THEN Order[1] ELSE Order[2]
NameShard(s, n) == IF FixNameHash THEN Order[(n % S) + 1] ELSE Home(s)

B0 == [r |-> 0, i |-> 0]
RD0 == [r |-> 0, kd |-> "", k |-> "", rep |-> 0, n |-> 1]
HomeRep(s) == (IF s = "A" THEN 0 ELSE 1) % nf[s]
Cold == "z"
Refreshers == Servers
Readers == Servers
Min(a, b) == IF a <= b THEN a ELSE b
HL0 == [leased |-> FALSE, n |-> 1, said |-> 1]
InitCount == 1

NextOf(s) == LET open == {i \in Idx : Script[i].s = s /\ i \notin started} IN
             IF open = {} THEN 0 ELSE CHOOSE i \in open : \A j \in open : i <= j

Complete(s) == \A k \in Shards : lp[s][k].q >= 0
RECURSIVE SumOf(_, _)
SumOf(s, K) == IF K = {} THEN 0 ELSE LET k == CHOOSE x \in K : TRUE IN lp[s][k].s + SumOf(s, K \ {k})
RECURSIVE SumB(_)
SumB(B) == IF B = {} THEN 0 ELSE LET b == CHOOSE x \in B : TRUE IN b.amt + SumB(B \ {b})

Laid(s) == {b \in bw[s] : lp[s][b.k].at # NONE /\ b.st > lp[s][b.k].at}
TotalOf(s) == SumOf(s, Shards) + (IF FixNoOwn THEN 0 ELSE SumB(Laid(s)))

TakePair(s, k, p) == [lp EXCEPT ![s][k] = Merge(@, [q |-> p.q, s |-> p.s, at |-> Clock(s)])]

Start(s) ==
    LET i == NextOf(s)
        e == Script[i]
        k == IF e.n = 0 THEN Home(s) ELSE NameShard(s, e.n)
        id == IF e.n = 0 THEN <<"m", s, i>> ELSE <<"n", "", e.n>>
    IN
    /\ i # 0 /\ up[s]
    /\ started' = started \cup {i}
    /\ IF e.m = "bump"
       THEN bw' = [bw EXCEPT ![s] = @ \cup {[i |-> i, id |-> id, k |-> k, amt |-> e.amt, st |-> Clock(s),
                                              heard |-> FALSE, said |-> FALSE, tries |-> 0]}]
       ELSE UNCHANGED bw
    /\ UNCHANGED <<envVars, bout, lp, rd, nf, hl, finished, ans, bk, ev>>

SendBump(s) ==
    \E b \in bw[s] :
       /\ ~b.heard /\ bout[s].r = 0
       /\ Issue(s, b.k, [A0 EXCEPT !.kd = "bump", !.id = b.id, !.amt = b.amt])
       /\ bout' = [bout EXCEPT ![s] = [r |-> NextReq, i |-> b.i]]
       /\ UNCHANGED <<bw, lp, rd, nf, hl, started, finished, ans, bk, ev>>

HearBump(s) ==
    LET r == bout[s].r
        b == CHOOSE x \in bw[s] : x.i = bout[s].i
    IN
    /\ r # 0
    /\ \E a \in Heard :
         /\ Reply(r, a)
         /\ bout' = [bout EXCEPT ![s] = B0]
         /\ IF a = "err"
            THEN LET b2 == [b EXCEPT !.tries = @ + 1]
                     say == b2.tries >= Ntry /\ ~b.said
                 IN /\ bw' = [bw EXCEPT ![s] = (@ \ {b}) \cup {[b2 EXCEPT !.said = @ \/ say]}]
                    /\ ans' = IF say THEN ans \cup {[c |-> b.i, m |-> "bump", r |-> "Unresolved", v |-> 0, ev |-> ev]}
                              ELSE ans
                    /\ finished' = IF say THEN finished \cup {b.i} ELSE finished
                    /\ UNCHANGED lp
            ELSE /\ bw' = [bw EXCEPT ![s] = (@ \ {b}) \cup {[b EXCEPT !.heard = TRUE, !.said = TRUE]}]
                 /\ ans' = IF b.said THEN ans ELSE ans \cup {[c |-> b.i, m |-> "bump", r |-> "true", v |-> 0, ev |-> ev]}
                 /\ finished' = finished \cup {b.i}
                 /\ lp' = TakePair(s, b.k, NoteOf(r).vs)
    /\ UNCHANGED <<rd, nf, hl, started, bk, ev>>

Idle(s) == rd[s].r = 0 /\ rd[s].kd = ""

ReadShard(s) ==
    \E k \in Shards :
       /\ Idle(s)
       /\ IssueGet(s, k, [A0 EXCEPT !.kd = "get"])
       /\ rd' = [rd EXCEPT ![s] = [RD0 EXCEPT !.r = NextReq, !.kd = "get", !.k = k]]
       /\ UNCHANGED <<bw, bout, lp, nf, hl, started, finished, ans, bk, ev>>

SendItemGet(s, r) ==
    /\ MsIssueGet(s, ItemKey(r), [pr |-> [k \in Shards |-> NoPair]])
    /\ rd' = [rd EXCEPT ![s] = [RD0 EXCEPT !.r = NextMsReq, !.kd = "ms", !.rep = r]]
    /\ UNCHANGED <<bw, bout, lp, nf, hl, started, finished, ans, bk, ev>>

ReadItem(s) == s \in Readers /\ Idle(s) /\ SendItemGet(s, HomeRep(s))
ReadZero(s) == rd[s].r = 0 /\ rd[s].kd = "ms0" /\ SendItemGet(s, 0)

SendUpdate(s, r, n) ==
    /\ MsIssue(s, ItemKey(r), [pr |-> lp[s], n |-> n], MaxExpiry)
    /\ rd' = [rd EXCEPT ![s] = [RD0 EXCEPT !.r = NextMsReq, !.kd = "fr", !.rep = r, !.n = n]]
    /\ UNCHANGED <<bw, bout, lp, nf, hl, started, finished, ans, bk, ev>>

Refresh(s) == s \in Refreshers /\ Idle(s) /\ SendUpdate(s, IF hl[s].leased THEN hl[s].n - 1 ELSE 0, hl[s].n)
RefreshZero(s) == rd[s].r = 0 /\ rd[s].kd = "fr0" /\ SendUpdate(s, 0, rd[s].n)

HearRead(s) ==
    LET R == rd[s] IN
    /\ R.r # 0
    /\ IF R.kd = "get"
       THEN \E a \in Heard :
              /\ Reply(R.r, a)
              /\ lp' = IF a = "ok"
                       THEN TakePair(s, R.k, [q |-> ReadOf(R.r).v.q, s |-> ReadOf(R.r).v.s]) ELSE lp
              /\ rd' = [rd EXCEPT ![s] = RD0]
              /\ UNCHANGED <<nf, hl>>
       ELSE \E a \in MsHeard :
              /\ MsReply(R.r, a)
              /\ LET it == mreq[R.r].seen
                     merged == mreq[R.r].res.v
                     found == R.kd = "ms" /\ a = "ok" /\ it.has
                     zero == R.kd = "fr" /\ R.rep = 0
                     H == hl[s]
                 IN /\ lp' = IF found THEN [lp EXCEPT ![s] = [k \in Shards |-> Merge(@[k], it.v.pr[k])]] ELSE lp
                    /\ nf' = IF found THEN [nf EXCEPT ![s] = Max(it.v.n, 1)] ELSE nf
                    /\ hl' = [hl EXCEPT ![s] =
                               IF zero /\ a = "ok" THEN [leased |-> TRUE, n |-> Max(H.n, merged.n), said |-> merged.n]
                               ELSE IF zero /\ a = "nil" THEN [H EXCEPT !.leased = FALSE]
                               ELSE IF R.kd = "frc" /\ a = "ok"
                                    THEN (IF H.leased /\ H.n = H.said THEN [H EXCEPT !.n = Min(2 * H.n, Reps)] ELSE H)
                               ELSE IF R.kd = "frc" THEN [H EXCEPT !.leased = FALSE]
                               ELSE H]
                    /\ rd' = [rd EXCEPT ![s] =
                               IF R.kd = "ms" /\ a = "ok" /\ ~it.has /\ R.rep # 0 THEN [RD0 EXCEPT !.kd = "ms0"]
                               ELSE IF R.kd = "ms" /\ a = "err" THEN [RD0 EXCEPT !.kd = "mscold"]
                               ELSE IF R.kd = "fr" /\ R.rep # 0 THEN [RD0 EXCEPT !.kd = "fr0", !.n = R.n]
                               ELSE IF zero /\ a = "err" THEN [RD0 EXCEPT !.kd = "frcold"]
                               ELSE RD0]
    /\ UNCHANGED <<bw, bout, started, finished, ans, bk, ev>>

ColdSend(s) ==
    /\ rd[s].r = 0 /\ rd[s].kd \in {"mscold", "frcold"}
    /\ MsIssueGet(s, Cold, [pr |-> [k \in Shards |-> NoPair]])
    /\ rd' = [rd EXCEPT ![s] = [RD0 EXCEPT !.r = NextMsReq, !.kd = IF rd[s].kd = "frcold" THEN "frc" ELSE "msc"]]
    /\ UNCHANGED <<bw, bout, lp, nf, hl, started, finished, ans, bk, ev>>

Answer(s) ==
    \E i \in started :
       /\ Script[i].s = s /\ Script[i].m = "total" /\ i \notin finished
       /\ up[s] /\ Complete(s)
       /\ ans' = ans \cup {[c |-> i, m |-> "total", r |-> "ok", v |-> TotalOf(s), ev |-> ev]}
       /\ finished' = finished \cup {i}
       /\ UNCHANGED <<envVars, bw, bout, lp, rd, nf, hl, started, bk, ev>>

Obs ==
    IF \A k \in Keys : ver'[k] = ver[k] THEN UNCHANGED <<bk, ev>>
    ELSE LET k == CHOOSE x \in Keys : ver'[x] # ver[x] IN
         /\ ev' = ev + 1
         /\ bk' = bk \cup {[id |-> f.id, amt |-> f.amt, ev |-> ev + 1] : f \in hist'[k][ver'[k]].fx}

Init ==
    /\ EnvInit(Z, I0)
    /\ bw = [s \in Servers |-> {}]
    /\ bout = [s \in Servers |-> B0]
    /\ lp = [s \in Servers |-> [k \in Shards |-> NoPair]]
    /\ rd = [s \in Servers |-> RD0]
    /\ nf = [s \in Servers |-> 1]
    /\ hl = [s \in Servers |-> [HL0 EXCEPT !.n = InitCount]]
    /\ started = {} /\ finished = {} /\ ans = {} /\ bk = {} /\ ev = 0

EnvStep == EnvNext(Tf, MsTf, FALSE) /\ Obs /\ UNCHANGED <<bw, bout, lp, rd, nf, hl, started, finished, ans>>

Next ==
    \/ EnvStep
    \/ \E s \in Servers : /\ Crash(s)
                          /\ bw' = [bw EXCEPT ![s] = {}]
                          /\ bout' = [bout EXCEPT ![s] = B0]
                          /\ lp' = [lp EXCEPT ![s] = [k \in Shards |-> NoPair]]
                          /\ rd' = [rd EXCEPT ![s] = RD0]
                          /\ nf' = [nf EXCEPT ![s] = 1]
                          /\ hl' = [hl EXCEPT ![s] = HL0]
                          /\ finished' = finished \cup {b.i : b \in {x \in bw[s] : ~x.said}}
                                                  \cup {i \in started : Script[i].s = s /\ Script[i].m = "total"}
                          /\ UNCHANGED <<started, ans, bk, ev>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<bw, bout, lp, rd, nf, hl, started, finished, ans, bk, ev>>
    \/ \E s \in Servers : Start(s) \/ SendBump(s) \/ HearBump(s) \/ ReadShard(s) \/ ReadItem(s) \/ ReadZero(s)
                          \/ Refresh(s) \/ RefreshZero(s) \/ ColdSend(s) \/ HearRead(s) \/ Answer(s)

Spec == Init /\ [][Next]_vars

TotalExact == \A a \in ans : a.m = "total" =>
    \E B \in SUBSET bk, t \in 0..a.ev :
        /\ {b \in bk : b.ev <= t} \subseteq B
        /\ \A b \in B : b.ev <= a.ev
        /\ a.v = SumB(B)
AtMostOnce == \A x, y \in bk : x.id = y.id => x = y
TrueTook == \A a \in ans : a.m = "bump" /\ a.r = "true" =>
    \E b \in bk : b.id = (IF Script[a.c].n = 0 THEN <<"m", Script[a.c].s, a.c>> ELSE <<"n", "", Script[a.c].n>>)

ScriptUnfinished == ~(Idx \subseteq finished)
ReadFromReplica == ~\E r \in DOMAIN mreq : mreq[r].key = "u" /\ mreq[r].kind = "get" /\ mreq[r].ph = "read" /\ mreq[r].seen.has
FallsBack == ~\E s \in Servers : rd[s].kd = "ms0"
TotGrown == \A s \in Servers : hl[s].n < 2
====
