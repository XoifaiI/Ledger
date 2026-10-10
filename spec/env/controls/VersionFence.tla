---------------------------- MODULE VersionFence ----------------------------
\* A toy that must fail under Env. It takes version order alone as a fence
\* against a write that answered an error.
\*
\* One server sends op x to one key with an UpdateAsync. Its transform
\* adds x when the key does not hold it. When the call answers an error,
\* the server sends a second UpdateAsync, the fence, whose transform adds
\* a mark and always writes. When the fence lands and its run read a value
\* with no x, the server answers a definite no for x: "not applied now and
\* not later". It reasons that x's write, if still out, read an older
\* version, and a landed write moved the version past it [D14]. Mark is
\* the fix: x's transform also cancels when the key holds the mark, as T03
\* step 4 asks.
\*
\* TrueNo says the no is true: the key never holds x. With RunAfterAnswer
\* off no run follows an answer, so x's write can land only on the version
\* it read, and the fence ends it, and TrueNo holds. With RunAfterAnswer
\* on, x's transform runs again after the error, on the version the fence
\* wrote, and its write lands with LateLand [D13]. Then TrueNo fails
\* without Mark and holds with it. FailBefore or LateLand gives the error,
\* one fault.
EXTENDS Env

\* @typeAlias: val = Set(Int);
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
VersionFence_typedefs == TRUE

CONSTANT
    \* @type: Bool;
    Mark

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

\* Argument 1 is x, and 2 is the fence, whose mark is 2 in the value.
\* @type: ($ctx, $val) => $out;
Tf(c, v) ==
    IF c.arg = 1
    THEN IF 1 \in v \/ (Mark /\ 2 \in v) THEN Cancel(c, v) ELSE Write(c, v \cup {1})
    ELSE Write(c, v \cup {2})

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit({}, 0) /\ pc = "send" /\ rq = 0 /\ told = "none"

Send ==
    /\ pc = "send"
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ pc' = "wait"
    /\ UNCHANGED told

\* On "nil" the server reads seen, the value its transform read.
Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ CASE a = "ok" -> pc' = "done" /\ told' = "yes"
               [] a = "nil" -> pc' = "done" /\ told' = IF 1 \in req[rq].seen THEN "yes" ELSE "unknown"
               [] OTHER -> pc' = "fence" /\ UNCHANGED told
    /\ UNCHANGED rq

Fence ==
    /\ pc = "fence"
    /\ Issue(S, K, 2)
    /\ rq' = NextReq
    /\ pc' = "fencing"
    /\ UNCHANGED told

\* On "ok" the server reads seen, the value the landing run read.
Fenced ==
    /\ pc = "fencing"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ told' = IF a = "ok" THEN (IF 1 \in req[rq].seen THEN "yes" ELSE "no") ELSE "unknown"
    /\ pc' = "done"
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, told>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, told>>
    \/ Send \/ Hear \/ Fence \/ Fenced

TrueNo == told = "no" => 1 \notin Cur(K)
=============================================================================
