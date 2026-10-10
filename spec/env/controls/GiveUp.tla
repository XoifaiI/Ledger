------------------------------- MODULE GiveUp -------------------------------
\* A toy that shows a run of errors from one cause costs one fault, and
\* that each error of the run may still hide an effect.
\*
\* One server writes op 1 with an UpdateAsync whose transform cancels when
\* the key holds the id. On an error it sends the op again under the same
\* id, up to Tries calls in all. After the last error it gives up, and
\* giving up is a definite no: "not applied now and not later".
\*
\* NeverGivesUp says the server never gives up. A violation shows the path
\* that gives up is reached. With MaxFaults 1 and errors one fault each,
\* at most one call fails, so the path is out of reach and it holds. With
\* DsSplit, one fault cuts the server off the datastore, and every call
\* after that answers an error at no cost, as a server does after its 30
\* seconds of shutdown [S3] or behind a full queue [D23]. With DsOutage
\* one fault does the same for every server [D11]. Either one reaches the
\* path.
\*
\* TrueNo says the no of a server that gave up is true: the key never
\* holds the id. An error to a cut server stands for every outcome the
\* switches allow, at no more cost. With DsSplit and LateLand at MaxFaults
\* 1, a call whose transform ran may still land after the server gave up
\* [D13]. With DsSplit and LoseAnswer at MaxFaults 1, a call may have
\* landed and lost its answer [D10]. Either breaks TrueNo. With both off,
\* an error to a cut server means no effect, and TrueNo holds.
EXTENDS Env

\* @typeAlias: val = Set(Int);
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
GiveUp_typedefs == TRUE

CONSTANT
    \* @type: Int;
    Tries

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Int;
    tries

vars == <<envVars, pc, rq, tries>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == IF c.arg \in v THEN Cancel(c, v) ELSE Write(c, v \cup {c.arg})

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit({}, 0) /\ pc = "send" /\ rq = 0 /\ tries = 0

Send ==
    /\ pc = "send"
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ tries' = tries + 1
    /\ pc' = "wait"

Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ pc' = IF a # "err" THEN "done" ELSE IF tries < Tries THEN "send" ELSE "gaveup"
    /\ UNCHANGED <<rq, tries>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, tries>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, tries>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, tries>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, tries>>
    \/ Send \/ Hear

NeverGivesUp == pc # "gaveup"
TrueNo == pc = "gaveup" => 1 \notin Cur(K)
=============================================================================
