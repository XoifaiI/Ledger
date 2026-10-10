------------------------------ MODULE LateFair ------------------------------
\* A liveness pair on Env. It shows that Env gives no fairness to a
\* transform run after its call answered.
\*
\* One server writes op 1 to a key with an UpdateAsync. On an error it
\* waits until its transform tells it that it ran, then goes on, as a
\* server that polls an upvalue after the call returns would. On any other
\* answer it goes on at once.
\*
\* GoesOn says the server eventually goes on. FailBefore is off and
\* LateLand is on, so an error leaves the call where it was. Under
\* RunAfterAnswer an error may come before any run, and the transform may
\* run after it or never [D13]. EnvFair gives weak fairness to a run only
\* while its server waits on the call, so nothing forces that run, and
\* GoesOn fails. With RunAfterAnswer off an error comes only after a run
\* that wrote, the server sees that run, and it holds.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
LateFair_typedefs == TRUE

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq

vars == <<envVars, pc, rq>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, v + 1)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "send" /\ rq = 0

Send ==
    /\ pc = "send"
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ pc' = "wait"

Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ pc' = IF a = "err" THEN "flag" ELSE "done"
    /\ UNCHANGED rq

\* The server reads what its transform told it, and goes on once it ran.
Flag ==
    /\ pc = "flag"
    /\ TfOf(rq) # "none"
    /\ pc' = "done"
    /\ UNCHANGED <<envVars, rq>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq>>
    \/ CrashAll /\ UNCHANGED <<pc, rq>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq>>
    \/ Send \/ Hear \/ Flag

Spec == Init /\ [][Next]_vars /\ EnvFair(Tf, MsTf, FALSE) /\ WF_vars(Send) /\ WF_vars(Hear) /\ WF_vars(Flag)

GoesOn == <>(pc = "done")
=============================================================================
