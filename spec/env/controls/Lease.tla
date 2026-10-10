------------------------------- MODULE Lease --------------------------------
\* A toy lease under one MemoryStore key. It must hold under Env with
\* every MemoryStore fault but MsVanish and MsOutage, and with clocks that
\* step, and it must fail with any of its three fixes taken out.
\*
\* A server takes the lease with a MemoryStore UpdateAsync whose expiry is
\* Ttl and whose transform writes an item that names the server and the
\* round, only when no live item is there. It believes it holds the lease
\* only after an "ok", and only while its own clock is before a limit.
\* With FromAnswer FALSE, the fix, the limit counts from its clock when it
\* sent the call. With FromAnswer TRUE it counts from its clock when the
\* answer came. The limit is that clock plus Ttl less Margin. While it
\* holds the lease it may release it, and it stops believing when it sends
\* the release. With SafeRelease TRUE, the fix, the release is an
\* UpdateAsync with expiry 0 whose transform writes only when the item
\* names this server and this round, so the item it writes is gone at once
\* [M4]. With SafeRelease FALSE it is a plain RemoveAsync, which is a
\* blind write. Once its lease has run out by its own clock, a server lets
\* it go without a call. Each server takes the lease at most Rounds times.
\*
\* Exclusive says no two servers believe they hold the lease at once.
\* Ticks may fall between a write applying and its answer, and nothing
\* bounds when a write applies. So with FromAnswer TRUE it fails: the item
\* applies, a tick passes, the answer comes, the item expires, and another
\* server takes the lease while the first still believes it holds it. With
\* SafeRelease FALSE it fails without any fault: a release sent while the
\* lease stood applies after it ran out and another server took the lease,
\* and takes that server's item off [M11]. A server measures the lease on
\* its own clock, and under ClockSteps that clock steps within MaxSkew at
\* no fault [C2]. So a duration on it may be 2 * MaxSkew ticks longer in
\* true time. Margin is the third fix. With Margin below 2 * MaxSkew and
\* ClockSteps on it fails at no fault: the holder's clock steps back and
\* it believes past the expiry. With all three fixes it holds, with
\* MsMaybe, MsFail, MsStale, RunAfterAnswer and ClockSteps on. The item
\* names the round, so no stale read and no late write of an earlier round
\* can pass for the current one. MsVanish and MsOutage are off, since an
\* item that vanishes early, alone or in an outage, breaks every lease
\* [M5, M7, M8]. So the exclusion rests on MaxSkew, a bound, and on no
\* item vanishing. That is why a lease in Ledger is positive evidence
\* only, and carries no safety [T16].
\*
\* EndsAfterAnswer says an item that names a server is gone Ttl ticks
\* after that server last heard an answer to a take, while it has no take
\* out. Without MsMaybe it holds, since a write applies before its answer.
\* With MsMaybe it fails: a take that answered an error applies later and
\* lives Ttl from then [M4, M11]. So a lease whose server heard an error
\* blocks others for Ttl after it applies, and nothing bounds when that
\* is. heardAt is a ghost of the true time of that answer.
EXTENDS Env, TLC

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = { s: Str, n: Int };
Lease_typedefs == TRUE

CONSTANTS
    \* @type: Int;
    Ttl,
    \* @type: Int;
    Rounds,
    \* @type: Int;
    Margin,
    \* @type: Bool;
    FromAnswer,
    \* @type: Bool;
    SafeRelease

VARIABLES
    \* @type: Str -> Str;
    pc,
    \* @type: Str -> Int;
    start,
    \* @type: Str -> Int;
    until,
    \* @type: Str -> Int;
    rounds,
    \* @type: Str -> Int;
    mq,
    \* @type: Str -> Int;
    heardAt

vars == <<envVars, pc, start, until, rounds, mq, heardAt>>

M == CHOOSE m \in MKeys : TRUE

\* No datastore call is made.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* An argument n above 0 takes the lease for round n when no live item is there. An argument -n
\* releases it when the item names this server and round n: the call carries expiry 0, so the item
\* it writes is gone at once.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) ==
    IF c.arg > 0
    THEN IF it.has THEN MsCancel(c, it) ELSE MsWrite(c, [s |-> c.srv, n |-> c.arg])
    ELSE IF it.has /\ it.v = [s |-> c.srv, n |-> -c.arg] THEN MsWrite(c, it.v) ELSE MsCancel(c, it)

Init ==
    /\ EnvInit(0, [s |-> "none", n |-> 0])
    /\ pc = [s \in Servers |-> "idle"]
    /\ start = [s \in Servers |-> 0]
    /\ until = [s \in Servers |-> 0]
    /\ rounds = [s \in Servers |-> 0]
    /\ mq = [s \in Servers |-> 0]
    /\ heardAt = [s \in Servers |-> 0]

\* @type: Str => Bool;
Holds(s) == pc[s] = "held" /\ Clock(s) < until[s]

Take(s) ==
    /\ pc[s] = "idle"
    /\ rounds[s] < Rounds
    /\ MsIssue(s, M, rounds[s] + 1, Ttl)
    /\ mq' = [mq EXCEPT ![s] = NextMsReq]
    /\ start' = [start EXCEPT ![s] = Clock(s)]
    /\ rounds' = [rounds EXCEPT ![s] = @ + 1]
    /\ pc' = [pc EXCEPT ![s] = "taking"]
    /\ UNCHANGED <<until, heardAt>>

Taken(s) ==
    /\ pc[s] = "taking"
    /\ \E a \in MsHeard :
          /\ MsReply(mq[s], a)
          /\ pc' = [pc EXCEPT ![s] = IF a = "ok" THEN "held" ELSE "idle"]
    /\ until' = [until EXCEPT ![s] = (IF FromAnswer THEN Clock(s) ELSE start[s]) + Ttl - Margin]
    /\ heardAt' = [heardAt EXCEPT ![s] = now]
    /\ UNCHANGED <<start, rounds, mq>>

Release(s) ==
    /\ Holds(s)
    /\ IF SafeRelease
       THEN MsIssue(s, M, -rounds[s], 0)
       ELSE MsIssueSet(s, M, -rounds[s], NoItem)
    /\ mq' = [mq EXCEPT ![s] = NextMsReq]
    /\ pc' = [pc EXCEPT ![s] = "releasing"]
    /\ UNCHANGED <<start, until, rounds, heardAt>>

Released(s) ==
    /\ pc[s] = "releasing"
    /\ \E a \in MsHeard : MsReply(mq[s], a)
    /\ pc' = [pc EXCEPT ![s] = "idle"]
    /\ UNCHANGED <<start, until, rounds, mq, heardAt>>

\* The lease ran out by the server's own clock.
Lapse(s) ==
    /\ pc[s] = "held"
    /\ ~(Clock(s) < until[s])
    /\ pc' = [pc EXCEPT ![s] = "idle"]
    /\ UNCHANGED <<envVars, start, until, rounds, mq, heardAt>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, start, until, rounds, mq, heardAt>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, start, until, rounds, mq, heardAt>>
    \/ CrashAll /\ UNCHANGED <<pc, start, until, rounds, mq, heardAt>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, start, until, rounds, mq, heardAt>>
    \/ \E s \in Servers : Take(s) \/ Taken(s) \/ Release(s) \/ Released(s) \/ Lapse(s)

\* The servers are alike, so a safety config may treat them as a symmetry set.
Perms == Permutations(Servers)

Exclusive == \A s1, s2 \in Servers : s1 # s2 => ~(Holds(s1) /\ Holds(s2))

EndsAfterAnswer ==
    \A s \in Servers :
        (MsView(M).has /\ MsView(M).v.s = s /\ pc[s] # "taking") => now < heardAt[s] + Ttl
=============================================================================
