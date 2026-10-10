-------------------------------- MODULE MsCap --------------------------------
\* A toy that must fail under Env when a server takes a MemoryStore cancel
\* for no effect. It is the family "Full after a reserve landed" of
\* design rule 11, on MemoryStore, where a reserve lives. A reserve is
\* one MemoryStore UpdateAsync that refuses when the unexpired sum plus
\* the amount passes the stock. It is the MemoryStore twin of CapRun.
\*
\* One server reserves 1 against a cap of 1 with one MemoryStore
\* UpdateAsync. The transform cancels when the item holds 1 or more, and
\* writes the hold otherwise. On "ok" the server answers yes, and on "nil"
\* it answers Full. On an error it reads what its transform told it, as a
\* server that reads its upvalues after the call returns does. It answers
\* Full when the last run cancelled.
\*
\* TrueFull says a Full is true: the reserve never applied. With
\* LoseCommit the engine does not learn that the write applied, and it
\* runs the transform again while the server waits [D10, M6]. That run
\* reads the hold its own write made and cancels, the call answers "nil",
\* and the server answers Full for one fault. With MsMaybe and
\* RunAfterAnswer the call answers an error after the write applied, for
\* one fault, and a run after the error cancels in the same way [M6, M11].
\* With LoseCommit and RunAfterAnswer off no run follows the applying, the
\* last run is the one that wrote, and it holds.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
MsCap_typedefs == TRUE

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Str;
    told

vars == <<envVars, pc, rq, told>>

S == CHOOSE s \in Servers : TRUE
M == CHOOSE mk \in MKeys : TRUE

\* No datastore UpdateAsync is sent.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == IF it.v >= 1 THEN MsCancel(c, it) ELSE MsWrite(c, it.v + 1)

Init == EnvInit(0, 0) /\ pc = "send" /\ rq = 0 /\ told = "none"

\* The hold lives 1 tick from when it applies.
Send ==
    /\ pc = "send"
    /\ MsIssue(S, M, 1, 1)
    /\ rq' = NextMsReq
    /\ pc' = "wait"
    /\ UNCHANGED told

Hear ==
    /\ pc = "wait"
    /\ \E a \in MsHeard :
          /\ MsReply(rq, a)
          /\ CASE a = "ok"  -> pc' = "done" /\ told' = "yes"
               [] a = "nil" -> pc' = "done" /\ told' = "full"
               [] OTHER     -> pc' = "decide" /\ UNCHANGED told
    /\ UNCHANGED rq

\* After the error the server reads what its last run did.
Decide ==
    /\ pc = "decide"
    /\ told' = IF mreq[rq].tf = "cancel" THEN "full" ELSE "unknown"
    /\ pc' = "done"
    /\ UNCHANGED <<envVars, rq>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, told>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, told>>
    \/ Send \/ Hear \/ Decide

TrueFull == told = "full" => mreq[rq].made = 0
=============================================================================
