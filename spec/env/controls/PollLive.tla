------------------------------ MODULE PollLive ------------------------------
\* A liveness pair on Env. It shows that a read catches up only under a
\* named bound on lag.
\*
\* One server writes op 1 to a key with an UpdateAsync. Once it hears the
\* answer, and once the faults stopped, it polls the key with GetAsync
\* until a read shows the op. The guard on calm only stages the scenario.
\* Each poll is a call, so MaxReqs bounds the polls, and a server whose
\* every poll showed nothing stops.
\*
\* Sees says the server eventually sees its op. StaleGet is on, and a
\* stale read costs no fault. With LagAfterCalm at MaxTime + 1 there is no
\* bound, and every read may be stale, since Roblox bounds no lag [D8], so
\* Sees fails. With LagAfterCalm 0 a read after Heal reads the current
\* version, so the first poll sees the op and it holds. No fault is on.
\* MaxTime is 0, so no tick passes. A lag above 0 needs ticks after the
\* write, and MaxTime cuts them, so a temporal check of such a lag fails
\* at the time bound. LagRead checks a lag above 0 as a bound on ticks
\* instead.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
PollLive_typedefs == TRUE

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq

vars == <<envVars, pc, rq>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == IF v = 1 THEN Cancel(c, v) ELSE Write(c, 1)

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
    /\ \E a \in {"ok", "nil"} : Reply(rq, a)
    /\ pc' = "poll"
    /\ UNCHANGED rq

\* The guard on calm only stages the scenario.
Poll ==
    /\ pc = "poll"
    /\ calm
    /\ IssueGet(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = "polling"

Look ==
    /\ pc = "polling"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ pc' = IF a = "ok" /\ ReadOf(rq).v = 1 THEN "saw" ELSE "poll"
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq>>
    \/ CrashAll /\ UNCHANGED <<pc, rq>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq>>
    \/ Send \/ Hear \/ Poll \/ Look

Spec ==
    /\ Init /\ [][Next]_vars /\ EnvFair(Tf, MsTf, FALSE)
    /\ WF_vars(Send) /\ WF_vars(Hear) /\ WF_vars(Poll) /\ WF_vars(Look)

Sees == <>(pc = "saw")
=============================================================================
