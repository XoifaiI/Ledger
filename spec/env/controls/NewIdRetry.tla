----------------------------- MODULE NewIdRetry -----------------------------
\* A toy that must fail under Env. It treats a failed call as not applied
\* and retries under a new id.
\*
\* One server makes one deposit. It writes the deposit under id 1 with an
\* UpdateAsync whose transform adds the id when the key does not hold it.
\* When the call answers an error, the server takes that to mean nothing
\* happened and sends the deposit again under id 2. The dedupe in the
\* transform cannot catch it, since the ids differ.
\*
\* The value is the set of ids applied. OneDeposit says at most one id
\* applied. With LoseAnswer, id 1 lands and its answer is lost, so both
\* ids apply [D10]. With LoseAnswer and LateLand off, an error means the
\* call failed before any effect [D11], and the retry is safe.
EXTENDS Env

\* @typeAlias: val = Set(Int);
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
NewIdRetry_typedefs == TRUE

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Int;
    id

vars == <<envVars, pc, rq, id>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == IF c.arg \in v THEN Cancel(c, v) ELSE Write(c, v \cup {c.arg})

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit({}, 0) /\ pc = "send" /\ rq = 0 /\ id = 1

Send ==
    /\ pc = "send"
    /\ Issue(S, K, id)
    /\ rq' = NextReq
    /\ pc' = "wait"
    /\ UNCHANGED id

Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ IF a = "err" /\ id = 1
             THEN pc' = "send" /\ id' = 2
             ELSE pc' = "done" /\ UNCHANGED id
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, id>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, id>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, id>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, id>>
    \/ Send \/ Hear

OneDeposit == Cardinality(Cur(K)) <= 1
=============================================================================
