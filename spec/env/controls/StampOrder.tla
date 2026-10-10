----------------------------- MODULE StampOrder -----------------------------
\* A toy that must fail under Env when it orders writes by UpdatedTime.
\*
\* One server writes 1 to a key, then 2, each after the last answered
\* "ok". After each write it reads the key with GetAsync, which is fresh
\* since StaleGet is off, and keeps the stamp of the version it read. It
\* then judges which write is newer by the larger stamp, as a design does
\* that judges a marker's age or orders two writes by their stamps. A tie
\* judges nothing.
\*
\* NewestKept says the server never judges write 1 the newer. With KeyInfo
\* a stamp is any tick, not rising [D17, C3], so write 2 may carry the
\* smaller stamp and it fails. With KeyInfo off every stamp is 0 and no
\* judgement is made, so it holds.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
StampOrder_typedefs == TRUE

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Int;
    first,
    \* @type: Str;
    told

vars == <<envVars, pc, rq, first, told>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* Writes its argument.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, c.arg)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "w1" /\ rq = 0 /\ first = 0 /\ told = "none"

\* @type: (Str, Int, Str) => Bool;
Send(at, x, next) ==
    /\ pc = at
    /\ Issue(S, K, x)
    /\ rq' = NextReq
    /\ pc' = next
    /\ UNCHANGED <<first, told>>

\* @type: (Str, Str) => Bool;
Hear(at, next) ==
    /\ pc = at
    /\ Reply(rq, "ok")
    /\ pc' = next
    /\ UNCHANGED <<rq, first, told>>

\* @type: (Str, Str) => Bool;
Ask(at, next) ==
    /\ pc = at
    /\ IssueGet(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = next
    /\ UNCHANGED <<first, told>>

ReadOne ==
    /\ pc = "g1"
    /\ Reply(rq, "ok")
    /\ first' = ReadOf(rq).u
    /\ pc' = "w2"
    /\ UNCHANGED <<rq, told>>

ReadTwo ==
    /\ pc = "g2"
    /\ Reply(rq, "ok")
    /\ told' = CASE ReadOf(rq).u < first -> "first"
                 [] ReadOf(rq).u > first -> "second"
                 [] OTHER -> "tie"
    /\ pc' = "done"
    /\ UNCHANGED <<rq, first>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, first, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, first, told>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, first, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, first, told>>
    \/ Send("w1", 1, "h1") \/ Hear("h1", "r1") \/ Ask("r1", "g1") \/ ReadOne
    \/ Send("w2", 2, "h2") \/ Hear("h2", "r2") \/ Ask("r2", "g2") \/ ReadTwo

NewestKept == told # "first"
=============================================================================
