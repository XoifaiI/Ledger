----------------------------- MODULE DelayLive ------------------------------
\* A toy that must fail under Env when a design takes a call, or a chain
\* of calls, to finish in a bound Env was not given. It checks
\* DelayAfterCalm and Hold in ticks, as bounded liveness.
\*
\* Once the faults stopped, one server writes op 1 to a key with an
\* UpdateAsync and waits for the answer. When it hears it, it writes op 2
\* with a second UpdateAsync and waits for that answer. With ReadTwo the
\* second call is a GetAsync of the key instead. The guard on calm only
\* stages the scenario, and sentAt is a ghost of the true time it sent the
\* first call.
\*
\* InTime says the key holds op 1 Bound ticks after the first call was
\* sent. HeardInTime says the server heard the first answer by then.
\* ChainInTime says it heard both answers 2 * Bound ticks after it sent
\* the first call, which is L1 for an operation of two calls. ReadFree
\* says it heard both answers Bound ticks after it sent the first call, as
\* a chain whose read costs no tick. EnvFair makes Run and Serve weakly
\* fair, and weak fairness says nothing about ticks. So with
\* DelayAfterCalm at MaxTime + 1, which is no bound, Tick may fire Bound +
\* 1 times before the transform runs, and InTime fails. With
\* DelayAfterCalm at Bound, time waits for a call once it is Bound ticks
\* old, until its server hears the answer, so InTime and HeardInTime hold.
\* The send of the second call is a step of the server, and Env bounds no
\* such step. With Holds FALSE, Hold is FALSE, ticks pass between the
\* first answer and the second send, and ChainInTime fails. With Holds
\* TRUE, Hold is TRUE while that send is enabled, time waits for it, and
\* ChainInTime holds. A GetAsync is a call like any other, with a send, a
\* read and an answer, so it too takes up to DelayAfterCalm ticks. With
\* ReadTwo, ChainInTime holds and ReadFree fails. A bounded liveness check
\* over ages in ticks, such as L1, names DelayAfterCalm for every call it
\* counts, a read among them, and names Hold for the steps of its own it
\* counts in ticks.
\*
\* Time can also stop for ever. With MaxReqs 1 no call is left for the
\* second send. A Hold that names the server's state stays TRUE, Tick
\* waits for a send that cannot run, and ChainInTime passes although the
\* chain never finishes. EnvTimeMoves fails there, so every config here
\* checks it under Spec, which is EnvFair with weak fairness on the
\* server's steps. With HoldEnabled, Hold is ENABLED of the second send.
\* It turns FALSE when MaxReqs disables that send, time moves on, and
\* ChainInTime reports the unfinished chain.
\*
\* A call that stays overdue stops time for ever too. With HearsTwo FALSE
\* the server has no step that hears the answer to its second call. Once
\* that call is DelayAfterCalm ticks old, Tick waits for an answer that no
\* step hears. ChainInTime passes although the chain never finishes, and
\* EnvTimeMoves fails.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
DelayLive_typedefs == TRUE

CONSTANTS
    \* @type: Int;
    Bound,
    \* @type: Bool;
    Holds,
    \* @type: Bool;
    ReadTwo,
    \* @type: Bool;
    HoldEnabled,
    \* @type: Bool;
    HearsTwo

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Int;
    sentAt

vars == <<envVars, pc, rq, sentAt>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* Argument n writes n.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, c.arg)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "send" /\ rq = 0 /\ sentAt = 0

\* The guard on calm only stages the scenario, and sentAt is a ghost.
Send ==
    /\ pc = "send"
    /\ calm
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ sentAt' = now
    /\ pc' = "wait"

Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard : Reply(rq, a)
    /\ pc' = "two"
    /\ UNCHANGED <<rq, sentAt>>

SendTwo ==
    /\ pc = "two"
    /\ IF ReadTwo THEN IssueGet(S, K, 0) ELSE Issue(S, K, 2)
    /\ rq' = NextReq
    /\ pc' = "waitTwo"
    /\ UNCHANGED sentAt

\* With HearsTwo FALSE the server has no step that hears the answer to its second call.
HearTwo ==
    /\ HearsTwo
    /\ pc = "waitTwo"
    /\ \E a \in Heard : Reply(rq, a)
    /\ pc' = "done"
    /\ UNCHANGED <<rq, sentAt>>

\* Time waits while the server's send of its second call is enabled. With HoldEnabled, Hold is
\* ENABLED of that send, so it turns FALSE when Env's guard on MaxReqs disables it. Without it,
\* Hold names the server's state alone.
Hold == Holds /\ IF HoldEnabled THEN ENABLED SendTwo ELSE pc = "two"

Next ==
    \/ EnvNext(Tf, MsTf, Hold) /\ UNCHANGED <<pc, rq, sentAt>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, sentAt>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, sentAt>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, sentAt>>
    \/ Send \/ Hear \/ SendTwo \/ HearTwo

Spec ==
    /\ Init /\ [][Next]_vars /\ EnvFair(Tf, MsTf, Hold)
    /\ WF_vars(Send) /\ WF_vars(Hear) /\ WF_vars(SendTwo) /\ WF_vars(HearTwo)

\* The age in ticks of the operation, once it started.
Late(n) == pc # "send" /\ now - sentAt > n

InTime == Late(Bound) => Cur(K) # 0
HeardInTime == Late(Bound) => pc # "wait"
ChainInTime == Late(2 * Bound) => pc = "done"
ReadFree == Late(Bound) => pc = "done"
=============================================================================
