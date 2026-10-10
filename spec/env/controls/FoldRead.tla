------------------------------ MODULE FoldRead ------------------------------
\* A toy that must fail under Env. It folds into its view what a transform
\* that wrote read, when the write was not heard to land.
\*
\* One server pushes to one key twice, one push after the other. Each push
\* is an UpdateAsync whose transform adds 1 to the value, so the value
\* counts the pushes that landed. The server shows one number for the key.
\* On "ok" it shows what the push wrote. On an error after a run that
\* wrote, it shows seen, the value that run read, since it takes a run
\* that writes to read the current version. On any other answer it shows
\* what it showed before.
\*
\* NeverBack is A8: the number the server shows never goes down. With
\* StaleRun a run may read an older version whether it then writes or
\* cancels [D7]. Only the landing checks that read. So the second push may
\* read version 0 after the first landed, fail to land, and answer an
\* error, and the server shows 0 after it showed 1. FailBefore gives that
\* error, one fault. With StaleRun off every run reads the current
\* version, which is at least the one the server showed, and it holds.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
FoldRead_typedefs == TRUE

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Int;
    pushes,
    \* @type: Int;
    shown

vars == <<envVars, pc, rq, pushes, shown>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, v + 1)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "send" /\ rq = 0 /\ pushes = 0 /\ shown = 0

Send ==
    /\ pc = "send"
    /\ pushes < 2
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ pushes' = pushes + 1
    /\ pc' = "wait"
    /\ UNCHANGED shown

\* The server reads res, tf and seen, which its transform told it.
Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ shown' = CASE a = "ok" -> req[rq].res
                        [] a = "err" /\ req[rq].tf = "write" -> req[rq].seen
                        [] OTHER -> shown
    /\ pc' = "send"
    /\ UNCHANGED <<rq, pushes>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, pushes, shown>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, pushes, shown>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, pushes, shown>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, pushes, shown>>
    \/ Send \/ Hear

NeverBack == [][shown' >= shown]_vars
=============================================================================
