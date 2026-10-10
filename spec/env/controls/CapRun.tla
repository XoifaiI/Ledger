------------------------------- MODULE CapRun -------------------------------
\* A toy that must fail under Env when a server takes a cancel for no
\* effect. It is the family "Full after a reserve landed" of design rule
\* 11, from one call.
\*
\* One server adds 1 to a counter with an UpdateAsync. The transform
\* cancels when the counter is at its cap of 1, and writes the add
\* otherwise. On "ok" the server answers yes, and on "nil" it answers
\* Full. On an error it later reads what its transform told it, as a
\* server that reads its upvalues after the call returns does. It answers
\* Full when the last run cancelled.
\*
\* TrueFull says a Full is true: the add never took effect. With
\* RunAfterAnswer the engine may go on after an error whose write had
\* landed, since it cannot tell that the write committed [D10, D12, D13].
\* Its next run reads the version its own write made, finds the cap and
\* cancels. So the server answers Full for an add that took effect, and it
\* fails. LoseAnswer gives the error, one fault. That run writes nothing,
\* so it needs no late landing, and it fails with LateLand off as well.
\* With LoseCommit the engine does not learn that the write landed, and it
\* runs the transform again while the server still waits. That run cancels
\* in the same way, the call answers "nil" with no error, and the server
\* answers Full, for one fault. With RunAfterAnswer and LoseCommit off no
\* run follows the landing, the last run is the one that wrote, and it
\* holds.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
CapRun_typedefs == TRUE

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

\* @type: ($ctx, $val) => $out;
Tf(c, v) == IF v >= 1 THEN Cancel(c, v) ELSE Write(c, v + 1)

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
          /\ CASE a = "ok"  -> pc' = "done" /\ told' = "yes"
               [] a = "nil" -> pc' = "done" /\ told' = "full"
               [] OTHER     -> pc' = "decide" /\ UNCHANGED told
    /\ UNCHANGED rq

\* After the error the server reads what its last run did.
Decide ==
    /\ pc = "decide"
    /\ told' = IF TfOf(rq) = "cancel" THEN "full" ELSE "unknown"
    /\ pc' = "done"
    /\ UNCHANGED <<envVars, rq>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, told>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, told>>
    \/ Send \/ Hear \/ Decide

TrueFull == told = "full" => Cur(K) = 0
=============================================================================
