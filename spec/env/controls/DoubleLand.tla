----------------------------- MODULE DoubleLand -----------------------------
\* A toy that shows a write landing on top of a call that landed twice.
\* One server sends call A to a key with an UpdateAsync. It hears any
\* answer, and then it sends call B to the same key and hears its answer.
\* Each transform adds its argument to the value it read. Env lets A land
\* a second version under LoseCommit, or under RunAfterAnswer after an
\* error. NoLandOnDouble says B never lands once A made two versions. It
\* must fail, since B's landing on top of a double landing is the
\* behaviour LoseCommit and RunAfterAnswer exist to show. An Env that
\* caps the versions of a key at MaxReqs lets A's second landing take the
\* last version, and B then never lands, so NoLandOnDouble passes. With
\* LoseCommit and RunAfterAnswer off, A lands once and NoLandOnDouble
\* holds, so the switches are the cause. Each of these three configs also
\* checks EnvHolds, EnvVersLeft among them.
\*
\* The capped configs put that earlier Env back. They set MaxVers to
\* CappedVers, which is MaxReqs. A's second landing then takes the last
\* version, B runs and never lands, and NoLandOnDouble holds. EnvVersLeft
\* fails, since B waits in phase "ran" on a key with no version left. So
\* EnvVersLeft reports the cut.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
DoubleLand_typedefs == TRUE

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq

vars == <<envVars, pc, rq>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* Argument n adds n to the value it read.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, v + c.arg)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "a" /\ rq = 0

SendA ==
    /\ pc = "a"
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ pc' = "waitA"

HearA ==
    /\ pc = "waitA"
    /\ \E a \in Heard : Reply(rq, a)
    /\ pc' = "b"
    /\ UNCHANGED rq

SendB ==
    /\ pc = "b"
    /\ Issue(S, K, 2)
    /\ rq' = NextReq
    /\ pc' = "waitB"

HearB ==
    /\ pc = "waitB"
    /\ \E a \in Heard : Reply(rq, a)
    /\ pc' = "done"
    /\ UNCHANGED rq

\* The cap on the versions of a key in an earlier Env. Only the capped configs use it, in place
\* of MaxVers.
CappedVers == MaxReqs

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq>>
    \/ CrashAll /\ UNCHANGED <<pc, rq>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq>>
    \/ SendA \/ HearA \/ SendB \/ HearB

NoLandOnDouble ==
    Len(req) = 2 /\ Cardinality(req[1].made) = 2 => req[2].made = {}
=============================================================================
