----------------------------- MODULE RetryLive -----------------------------
\* A liveness pair on Env. One server writes op 1 to a key with an
\* UpdateAsync whose transform cancels when the key holds the id. When the
\* call answers an error, the server sends it again under the same id if
\* Retries is TRUE, and gives up if it is FALSE.
\*
\* Lands says the key eventually holds the id. Env's fairness makes the
\* faults stop, runs every transform that can run and lands every write
\* its server waits on that can land. With Retries it holds: at most
\* MaxFaults calls fail, and a call sent after the last fault waits until
\* it lands or cancels. Until the op lands the key has one version, so a
\* run reads the current version even under StaleRun, and its write can
\* land. So Lands needs no bound on lag or delay, and both are at MaxTime
\* + 1. Without Retries it fails: one call that fails before it takes
\* effect leaves the op unapplied for good [D11].
EXTENDS Env

\* @typeAlias: val = Set(Int);
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
RetryLive_typedefs == TRUE

CONSTANT
    \* @type: Bool;
    Retries

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq

vars == <<envVars, pc, rq>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == IF c.arg \in v THEN Cancel(c, v) ELSE Write(c, v \cup {c.arg})

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit({}, 0) /\ pc = "send" /\ rq = 0

Send ==
    /\ pc = "send"
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ pc' = "wait"

Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ pc' = IF a # "err" THEN "done" ELSE IF Retries THEN "send" ELSE "gaveup"
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq>>
    \/ CrashAll /\ UNCHANGED <<pc, rq>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq>>
    \/ Send \/ Hear

Spec == Init /\ [][Next]_vars /\ EnvFair(Tf, MsTf, FALSE) /\ WF_vars(Send) /\ WF_vars(Hear)

Lands == <>(1 \in Cur(K))
=============================================================================
