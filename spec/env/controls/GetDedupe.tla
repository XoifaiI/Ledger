----------------------------- MODULE GetDedupe -----------------------------
\* A toy that must fail under Env. It decides dedupe on a GetAsync.
\*
\* One server gets op x twice, one delivery after the other. Each
\* delivery reads the key with GetAsync. If the read shows x applied, it
\* skips. Otherwise it writes x with an UpdateAsync whose transform does
\* not check again. The second delivery starts only after the first one
\* heard its answer, so no two calls race.
\*
\* The value is how many times x applied. AtMostOnce says x applied at
\* most once. With StaleGet the second read may answer version 0, so x
\* applies twice [D8, D9]. A stale read costs no fault. With StaleGet off
\* it holds. Every other fault is off, so the stale read is the one cause.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
GetDedupe_typedefs == TRUE

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    round,
    \* @type: Int;
    rq

vars == <<envVars, pc, round, rq>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* The transform applies x again whatever it reads. The check was the read.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, v + 1)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "read" /\ round = 1 /\ rq = 0

\* @type: Str;
Done == IF round = 2 THEN "done" ELSE "read"

Read ==
    /\ pc = "read"
    /\ IssueGet(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = "reading"
    /\ UNCHANGED round

\* A read that shows x applied skips. A read that fails gives this delivery up.
Look ==
    /\ pc = "reading"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ IF a = "ok" /\ ReadOf(rq).v = 0
             THEN pc' = "write" /\ UNCHANGED round
             ELSE pc' = Done /\ round' = round + 1
    /\ UNCHANGED rq

Send ==
    /\ pc = "write"
    /\ Issue(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = "wait"
    /\ UNCHANGED round

Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard : Reply(rq, a)
    /\ pc' = Done
    /\ round' = round + 1
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, round, rq>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, round, rq>>
    \/ CrashAll /\ UNCHANGED <<pc, round, rq>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, round, rq>>
    \/ Read \/ Look \/ Send \/ Hear

AtMostOnce == Cur(K) <= 1
=============================================================================
