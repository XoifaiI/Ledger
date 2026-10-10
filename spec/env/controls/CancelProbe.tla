---------------------------- MODULE CancelProbe ----------------------------
\* A toy that must fail under Env. It takes a decision from a transform
\* that cancelled.
\*
\* One server writes op x with an UpdateAsync. The transform adds x when
\* the key does not hold it and cancels when it does. When the call
\* answers an error, the server probes: it sends a second UpdateAsync
\* whose transform always cancels, and reads seen, the value that
\* transform read. If the probe saw no x, the server answers a definite
\* no, which means "not applied now and not later". Any other outcome
\* answers yes or unknown.
\*
\* The value is how many times x applied. TrueNo says a definite no is
\* true: x never applies. LoseAnswer and FailBefore make the first call
\* answer an error after it landed or before. With StaleRun the probe may
\* read version 0 after x landed, so the no is false [D7]. With StaleRun
\* off, a probe after an error reads the current version, and since
\* LateLand is off nothing lands after the error, so the no is true.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
CancelProbe_typedefs == TRUE

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

\* Argument 1 applies x once. Argument 0 is the probe, which always cancels.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == IF c.arg = 1 /\ v = 0 THEN Write(c, v + 1) ELSE Cancel(c, v)

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
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ IF a = "err"
             THEN pc' = "probe" /\ UNCHANGED told
             ELSE pc' = "done" /\ told' = "yes"
    /\ UNCHANGED rq

Probe ==
    /\ pc = "probe"
    /\ Issue(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = "probing"
    /\ UNCHANGED told

\* After a "nil" the server reads seen, the value its transform read.
Learn ==
    /\ pc = "probing"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ told' = IF a = "nil"
                     THEN (IF req[rq].seen > 0 THEN "yes" ELSE "no")
                     ELSE "unknown"
    /\ pc' = "done"
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, told>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, told>>
    \/ Send \/ Hear \/ Probe \/ Learn

TrueNo == told = "no" => Cur(K) = 0
=============================================================================
