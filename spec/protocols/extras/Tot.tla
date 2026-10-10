---------------------------------- MODULE Tot ----------------------------------
\* Tot is the totals of the extras design (section 2, with the
\* holder of section 4), over env/Env.tla (a copy sits beside it).
\*
\* WHAT IS MODELLED
\*
\* A total of S shards, the keys in Keys. A shard is a record whose state
\* is one integer s; its value here keeps s, the record's write count q
\* and the ids of the bumps it applied. A bump is a durable op on one
\* shard: a minted bump goes to its server's home shard, a bump under a
\* game name to the shard its name hashes to (2.2). Each bump is sent as
\* its own request, again after an error, and Step applies it once: the
\* record's dedupe, whose writer and horizon invariants Rec.tla checks,
\* is kept here as the set of ids applied. Every note carries the (q, s)
\* its run landed or read.
\*
\* A server keeps a local pair (q, s) per shard, with at, its clock when
\* it took the pair. It merges pairs by q (2.4): from a landed note of its
\* own bump, a GetAsync of a shard, or the summary item t in MemoryStore.
\* A refresh (section 4) sends an UpdateAsync of t whose transform merges
\* the server's pairs into the item by q and names the server as holder.
\* Who refreshes and when is liveness, so any server may refresh at any
\* time, and any server may read a shard or the item at any time. A Total
\* answers the sum of its local pairs once every shard has one (2.4 steps
\* 1, 2 and 4 all end so), and never adds a bump of its own.
\*
\* WHAT IS LEFT OUT, AND WHY
\*
\* The cap ShardMax (R never arises with the scripts' small amounts), the
\* pacing (liveness), MaxAge and the lapse rule (liveness), the tidy (a
\* record step 7 drop, Rec), and copies (Follow and Peek with MaxAge, a
\* model of their own).
\*
\* PROPERTIES
\*   A9 TotalExact: a total is the sum of a set of bumps that took effect
\*   before it answered, holding every bump before some earlier moment.
\*   Amounts are powers of 2, so a sum names its set. S5 AtMostOnce for
\*   bumps. A2 TrueTook for bumps.
EXTENDS Env, TLC

CONSTANTS
    Scenario,      \* the script to run, a string
    Ntry,          \* errors in a row before a bump answers Unresolved (it is still sent again)
    FixNoOwn,      \* a Total never lays this server's own bumps over its pairs (B27, B46)
    FixMergeQ,     \* pairs merge by q; else by the clock of whoever took the pair (B46)
    FixNameHash    \* a game-named bump goes to Hash(name) mod S; else to a shard the server picks

VARIABLES
    bw,        \* bw[s]: server s's bumps: [i, id, k, amt, st, heard, said, tries]
    bout,      \* bout[s]: [r, i], the bump request out (r = 0: none)
    lp,        \* lp[s][k]: server s's local pair for shard k: [q, s, at], q = -1 for none
    rd,        \* rd[s]: the read out: [r, kd, k] (kd "get" of shard k, "ms" of the item, "fr" a refresh)
    started,   \* script items started
    finished,  \* script items answered
    ans,       \* answers. Ghost.
    bk,        \* every bump that took: [id, amt, ev]. Ghost.
    ev         \* landings so far, the global order of events. Ghost.

vars == <<envVars, bw, bout, lp, rd, started, finished, ans, bk, ev>>

NONE == -100
Shards == Keys
S == Cardinality(Shards)
MI == "t"

\* A shard, and Step for a bump (record 4, 2.1: bump(a) gives s + a).

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

\* The summary item t (2.4, 4): a pair per shard, merged by q, and holder.

NoPair == [q |-> -1, s |-> 0, at |-> NONE]
I0 == [pr |-> [k \in Shards |-> NoPair], hd |-> ""]

Merge(old, new) ==
    IF FixMergeQ THEN (IF new.q > old.q THEN new ELSE old)
    ELSE (IF new.q >= 0 /\ (old.q < 0 \/ new.at > old.at) THEN new ELSE old)

MsTf(c, it) ==
    LET cur == IF it.has THEN it.v ELSE I0
    IN MsWrite(c, [pr |-> [k \in Shards |-> Merge(cur.pr[k], c.arg.pr[k])], hd |-> c.srv])

\* The scripts.

E0 == [s |-> "A", m |-> "", n |-> 0, amt |-> 0]
Bump(s, amt) == [E0 EXCEPT !.s = s, !.m = "bump", !.amt = amt]
NBump(s, n, amt) == [E0 EXCEPT !.s = s, !.m = "bump", !.n = n, !.amt = amt]
Total(s) == [E0 EXCEPT !.s = s, !.m = "total"]

Script ==
    CASE Scenario = "Two"  -> << Bump("A", 1), Bump("B", 2), Total("A"), Bump("A", 4), Total("B") >>
      [] Scenario = "Name" -> << NBump("A", 1, 1), NBump("B", 1, 1), Bump("B", 2), Total("A"), Total("B") >>
Idx == DOMAIN Script

\* The home shard of a server, and the shard of a game name (2.2).
Order == CHOOSE f \in [1..S -> Shards] : \A i, j \in 1..S : i # j => f[i] # f[j]
Home(s) == IF s = "A" \/ S = 1 THEN Order[1] ELSE Order[2]
NameShard(s, n) == IF FixNameHash THEN Order[(n % S) + 1] ELSE Home(s)

\* The servers.

B0 == [r |-> 0, i |-> 0]
RD0 == [r |-> 0, kd |-> "", k |-> ""]

NextOf(s) == LET open == {i \in Idx : Script[i].s = s /\ i \notin started} IN
             IF open = {} THEN 0 ELSE CHOOSE i \in open : \A j \in open : i <= j

Complete(s) == \A k \in Shards : lp[s][k].q >= 0
RECURSIVE SumOf(_, _)
SumOf(s, K) == IF K = {} THEN 0 ELSE LET k == CHOOSE x \in K : TRUE IN lp[s][k].s + SumOf(s, K \ {k})
RECURSIVE SumB(_)
SumB(B) == IF B = {} THEN 0 ELSE LET b == CHOOSE x \in B : TRUE IN b.amt + SumB(B \ {b})

\* B27, B46: the control lays over the pairs each own bump stamped after its shard's pair was taken.
Laid(s) == {b \in bw[s] : lp[s][b.k].at # NONE /\ b.st > lp[s][b.k].at}
TotalOf(s) == SumOf(s, Shards) + (IF FixNoOwn THEN 0 ELSE SumB(Laid(s)))

TakePair(s, k, p) == [lp EXCEPT ![s][k] = Merge(@, [q |-> p.q, s |-> p.s, at |-> Clock(s)])]

\* Start the next item: a bump joins the server's bumps; a total starts.
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
    /\ UNCHANGED <<envVars, bout, lp, rd, finished, ans, bk, ev>>

\* Send a bump not yet heard (again after an error).
SendBump(s) ==
    \E b \in bw[s] :
       /\ ~b.heard /\ bout[s].r = 0
       /\ Issue(s, b.k, [A0 EXCEPT !.kd = "bump", !.id = b.id, !.amt = b.amt])
       /\ bout' = [bout EXCEPT ![s] = [r |-> NextReq, i |-> b.i]]
       /\ UNCHANGED <<bw, lp, rd, started, finished, ans, bk, ev>>

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
    /\ UNCHANGED <<rd, started, bk, ev>>

\* Read a shard with GetAsync, the summary item with MemoryStore GetAsync, or refresh the item.
ReadShard(s) ==
    \E k \in Shards :
       /\ rd[s].r = 0
       /\ IssueGet(s, k, [A0 EXCEPT !.kd = "get"])
       /\ rd' = [rd EXCEPT ![s] = [r |-> NextReq, kd |-> "get", k |-> k]]
       /\ UNCHANGED <<bw, bout, lp, started, finished, ans, bk, ev>>

ReadItem(s) ==
    /\ rd[s].r = 0
    /\ MsIssueGet(s, MI, [pr |-> [k \in Shards |-> NoPair]])
    /\ rd' = [rd EXCEPT ![s] = [r |-> NextMsReq, kd |-> "ms", k |-> ""]]
    /\ UNCHANGED <<bw, bout, lp, started, finished, ans, bk, ev>>

Refresh(s) ==
    /\ rd[s].r = 0
    /\ MsIssue(s, MI, [pr |-> lp[s]], MaxExpiry)
    /\ rd' = [rd EXCEPT ![s] = [r |-> NextMsReq, kd |-> "fr", k |-> ""]]
    /\ UNCHANGED <<bw, bout, lp, started, finished, ans, bk, ev>>

HearRead(s) ==
    LET R == rd[s] IN
    /\ R.r # 0
    /\ IF R.kd = "get"
       THEN \E a \in Heard :
              /\ Reply(R.r, a)
              \* A shard no bump made yet reads absent: its sum is 0 at q 0, a state it held.
              /\ lp' = IF a = "ok"
                       THEN TakePair(s, R.k, [q |-> ReadOf(R.r).v.q, s |-> ReadOf(R.r).v.s]) ELSE lp
       ELSE \E a \in MsHeard :
              /\ MsReply(R.r, a)
              /\ lp' = IF R.kd = "ms" /\ a = "ok" /\ mreq[R.r].seen.has
                       THEN [lp EXCEPT ![s] = [k \in Shards |-> Merge(@[k], mreq[R.r].seen.v.pr[k])]]
                       ELSE lp
    /\ rd' = [rd EXCEPT ![s] = RD0]
    /\ UNCHANGED <<bw, bout, started, finished, ans, bk, ev>>

\* A Total answers once every shard has a pair.
Answer(s) ==
    \E i \in started :
       /\ Script[i].s = s /\ Script[i].m = "total" /\ i \notin finished
       /\ up[s] /\ Complete(s)
       /\ ans' = ans \cup {[c |-> i, m |-> "total", r |-> "ok", v |-> TotalOf(s), ev |-> ev]}
       /\ finished' = finished \cup {i}
       /\ UNCHANGED <<envVars, bw, bout, lp, rd, started, bk, ev>>

\* The ghost observer: each landing's bump, in the order of landings.

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
    /\ started = {} /\ finished = {} /\ ans = {} /\ bk = {} /\ ev = 0

EnvStep == EnvNext(Tf, MsTf, FALSE) /\ Obs /\ UNCHANGED <<bw, bout, lp, rd, started, finished, ans>>

\* A crash loses the server's bumps and pairs; a bump never sent is lost with it (S13's "lost").
Next ==
    \/ EnvStep
    \/ \E s \in Servers : /\ Crash(s)
                          /\ bw' = [bw EXCEPT ![s] = {}]
                          /\ bout' = [bout EXCEPT ![s] = B0]
                          /\ lp' = [lp EXCEPT ![s] = [k \in Shards |-> NoPair]]
                          /\ rd' = [rd EXCEPT ![s] = RD0]
                          /\ finished' = finished \cup {b.i : b \in {x \in bw[s] : ~x.said}}
                                                  \cup {i \in started : Script[i].s = s /\ Script[i].m = "total"}
                          /\ UNCHANGED <<started, ans, bk, ev>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<bw, bout, lp, rd, started, finished, ans, bk, ev>>
    \/ \E s \in Servers : Start(s) \/ SendBump(s) \/ HearBump(s) \/ ReadShard(s) \/ ReadItem(s)
                          \/ Refresh(s) \/ HearRead(s) \/ Answer(s)

Spec == Init /\ [][Next]_vars

\* The properties.

\* A9, as the property list writes it, with ev for the moment.
TotalExact == \A a \in ans : a.m = "total" =>
    \E B \in SUBSET bk, t \in 0..a.ev :
        /\ {b \in bk : b.ev <= t} \subseteq B
        /\ \A b \in B : b.ev <= a.ev
        /\ a.v = SumB(B)
\* S5 for bumps: a bump takes effect once.
AtMostOnce == \A x, y \in bk : x.id = y.id => x = y
\* A2 for bumps: true only once the bump took.
TrueTook == \A a \in ans : a.m = "bump" /\ a.r = "true" =>
    \E b \in bk : b.id = (IF Script[a.c].n = 0 THEN <<"m", Script[a.c].s, a.c>> ELSE <<"n", "", Script[a.c].n>>)

\* Probe: some behaviour answers every item.
ScriptUnfinished == ~(Idx \subseteq finished)
=============================================================================
