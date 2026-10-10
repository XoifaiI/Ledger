------------------------------ MODULE AllDown ------------------------------
\* A toy that must fail under Env when a design keeps work in the memory
\* of its servers and needs one of them to remember it. A publish or an
\* empty game closes every server at once, and each loses its memory [S1,
\* S3].
\*
\* Each of two servers holds a piece of unfinished work in its memory. A
\* server that crashes forgets its piece, and its next life starts with
\* none. SomeRemembers says some server still holds its piece. With
\* Shutdowns, one fault crashes every live server, and it fails at
\* MaxFaults 1. With Crashes alone, one fault crashes one server, the
\* other keeps its piece, and it holds at MaxFaults 1. A model with N
\* servers would need N faults to lose every server's memory without
\* Shutdowns.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
AllDown_typedefs == TRUE

VARIABLES
    \* @type: Str -> Bool;
    held

vars == <<envVars, held>>

\* No datastore UpdateAsync is sent.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ held = [s \in Servers |-> TRUE]

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED held
    \/ \E s \in Servers : Crash(s) /\ held' = [held EXCEPT ![s] = FALSE]
    \/ CrashAll /\ held' = [s \in Servers |-> FALSE]
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED held

SomeRemembers == \E s \in Servers : held[s]
=============================================================================
