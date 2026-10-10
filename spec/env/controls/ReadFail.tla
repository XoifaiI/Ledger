------------------------------ MODULE ReadFail ------------------------------
\* A toy that must fail under Env when a GetAsync fails. It takes a failed
\* read for an empty key.
\*
\* One server writes op x with an UpdateAsync. Whatever it hears, it then
\* reads the key with GetAsync to learn whether x applied. A read that
\* shows x answers yes, and one that does not answers no. A read that
\* fails also answers no, as if the key held nothing.
\*
\* TrueNo says a no is true: x did not apply. With FailBefore the write
\* lands and answers "ok", then the read fails [D11], and the no is false.
\* With FailBefore off every read answers, and StaleGet is off, so it
\* holds.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
ReadFail_typedefs == TRUE

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Str;
    told

vars == <<envVars, pc, rq, told>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == IF v = 0 THEN Write(c, 1) ELSE Cancel(c, v)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "send" /\ rq = 0 /\ told = "none"

Send ==
    /\ pc = "send"
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ pc' = "wait"
    /\ UNCHANGED told

Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard : Reply(rq, a)
    /\ pc' = "check"
    /\ UNCHANGED <<rq, told>>

Check ==
    /\ pc = "check"
    /\ IssueGet(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = "reading"
    /\ UNCHANGED told

\* A read that fails answers no, as if the key held nothing.
Decide ==
    /\ pc = "reading"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ told' = IF a = "ok" /\ ReadOf(rq).v # 0 THEN "yes" ELSE "no"
    /\ pc' = "done"
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, told>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, told>>
    \/ Send \/ Hear \/ Check \/ Decide

TrueNo == told = "no" => Cur(K) = 0
=============================================================================
