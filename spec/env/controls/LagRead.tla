------------------------------ MODULE LagRead -------------------------------
\* A toy that must fail under Env when a design takes a read lag shorter
\* than LagAfterCalm. It checks the bound on lag in ticks, as bounded
\* liveness.
\*
\* Once the faults stopped, one server writes op 1 to a key with an
\* UpdateAsync. When it hears "ok" it waits Wait ticks by its own clock,
\* then sends a GetAsync of the key. It answers "fresh" when the read
\* shows its op and "stale" when it does not. The guard on calm only
\* stages the scenario. MaxSkew is 0, so the server's clock reads true
\* time.
\*
\* SeesOwn says the read shows the op: a design that trusts a read Wait
\* ticks after a write. StaleGet is on. Once calm, a read sees a version
\* that stopped being current less than LagAfterCalm ticks before the
\* read. The read comes at or after the send. The old version stopped
\* being current when the write landed, at or before the "ok". So with
\* LagAfterCalm at most Wait the read is current and SeesOwn holds. With
\* LagAfterCalm above Wait the read may still show the old version, and
\* SeesOwn fails. Roblox's read cache alone makes a read lag 4 seconds
\* with no fault [D8], so a design that needs a lag bound names
\* LagAfterCalm at 4 seconds or more.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
LagRead_typedefs == TRUE

CONSTANT
    \* @type: Int;
    Wait

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Int;
    okAt,
    \* @type: Str;
    told

vars == <<envVars, pc, rq, okAt, told>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, 1)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "send" /\ rq = 0 /\ okAt = 0 /\ told = "none"

\* The guard on calm only stages the scenario.
Send ==
    /\ pc = "send"
    /\ calm
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ pc' = "wait"
    /\ UNCHANGED <<okAt, told>>

Hear ==
    /\ pc = "wait"
    /\ Reply(rq, "ok")
    /\ okAt' = Clock(S)
    /\ pc' = "pause"
    /\ UNCHANGED <<rq, told>>

Look ==
    /\ pc = "pause"
    /\ Clock(S) >= okAt + Wait
    /\ IssueGet(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = "reading"
    /\ UNCHANGED <<okAt, told>>

Judge ==
    /\ pc = "reading"
    /\ Reply(rq, "ok")
    /\ told' = IF ReadOf(rq).v = 1 THEN "fresh" ELSE "stale"
    /\ pc' = "done"
    /\ UNCHANGED <<rq, okAt>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, okAt, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, okAt, told>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, okAt, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, okAt, told>>
    \/ Send \/ Hear \/ Look \/ Judge

SeesOwn == told # "stale"
=============================================================================
