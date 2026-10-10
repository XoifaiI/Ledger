------------------------------- MODULE MsDown -------------------------------
\* A toy for DelayAfterCalm when MemoryStore is down for the whole
\* behaviour. MsOn is FALSE in every config, so every MemoryStore call
\* ends with an error.
\*
\* Once the faults stopped, one server sends a MemoryStore GetAsync and
\* waits for the answer, as a design does that falls back to the
\* datastore when it hears an error. The guard on calm only stages the
\* scenario, and sentAt is a ghost of the true time it sent the call.
\*
\* HeardInTime says the server heard the answer Bound ticks after it sent
\* the call. With DelayAfterCalm at Bound, time waits for the call once it
\* is Bound ticks old, until the server hears the error, and it holds.
\* With DelayAfterCalm at MaxTime + 1 there is no bound, and it fails.
\*
\* HeardAtOnce says the server heard the answer before any tick passed. No
\* platform bound gives that, and it fails under DelayAfterCalm 1. With
\* HoldHear TRUE, Hold is ENABLED of the step that hears the answer. That
\* breaks the rule of Env that Hold never names a step that conjoins
\* MsReply. Time then waits for the error, and HeardAtOnce holds with no
\* bound on delay. Env cannot stop that Hold, and this control shows what
\* the rule keeps out.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
MsDown_typedefs == TRUE

CONSTANTS
    \* @type: Int;
    Bound,
    \* @type: Bool;
    HoldHear

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    mq,
    \* @type: Int;
    sentAt

vars == <<envVars, pc, mq, sentAt>>

S == CHOOSE s \in Servers : TRUE
M == CHOOSE mk \in MKeys : TRUE

\* No datastore UpdateAsync is sent.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "send" /\ mq = 0 /\ sentAt = 0

\* The guard on calm only stages the scenario, and sentAt is a ghost.
Send ==
    /\ pc = "send"
    /\ calm
    /\ MsIssueGet(S, M, 0)
    /\ mq' = NextMsReq
    /\ sentAt' = now
    /\ pc' = "wait"

Hear ==
    /\ pc = "wait"
    /\ \E a \in MsHeard : MsReply(mq, a)
    /\ pc' = "done"
    /\ UNCHANGED <<mq, sentAt>>

\* With HoldHear, Hold names the step that hears the answer, which Env's rule forbids.
Hold == HoldHear /\ ENABLED Hear

Next ==
    \/ EnvNext(Tf, MsTf, Hold) /\ UNCHANGED <<pc, mq, sentAt>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, mq, sentAt>>
    \/ CrashAll /\ UNCHANGED <<pc, mq, sentAt>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, mq, sentAt>>
    \/ Send \/ Hear

Spec ==
    /\ Init /\ [][Next]_vars /\ EnvFair(Tf, MsTf, Hold)
    /\ WF_vars(Send) /\ WF_vars(Hear)

\* The age in ticks of the call, once it was sent.
Late(n) == pc # "send" /\ now - sentAt > n

HeardInTime == Late(Bound) => pc # "wait"
HeardAtOnce == Late(0) => pc # "wait"
=============================================================================
