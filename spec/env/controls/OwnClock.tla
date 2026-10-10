------------------------------ MODULE OwnClock ------------------------------
\* A toy that must fail under Env when a clock steps back. It orders two
\* events of one server by that server's own clock.
\*
\* One server stamps event 1 with its clock, then stamps event 2. Event 2
\* comes after event 1 in true time. OwnOrder says the second stamp is not
\* below the first. Without ClockJumps and ClockSteps a clock reads now
\* plus a fixed skew, and now only rises, so it holds. With ClockJumps the
\* clock may step back inside MaxSkew between the two stamps at the cost
\* of a fault [C2], so it fails. With ClockSteps it steps back at no
\* fault, and it fails with MaxFaults 0. Crashes are off, so no restart
\* picks a new skew.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
OwnClock_typedefs == TRUE

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    first,
    \* @type: Int;
    second

vars == <<envVars, pc, first, second>>

S == CHOOSE s \in Servers : TRUE

\* No datastore call is made.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "one" /\ first = 0 /\ second = 0

One ==
    /\ pc = "one"
    /\ first' = Clock(S)
    /\ pc' = "two"
    /\ UNCHANGED <<envVars, second>>

Two ==
    /\ pc = "two"
    /\ second' = Clock(S)
    /\ pc' = "done"
    /\ UNCHANGED <<envVars, first>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, first, second>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, first, second>>
    \/ CrashAll /\ UNCHANGED <<pc, first, second>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, first, second>>
    \/ One \/ Two

OwnOrder == pc = "done" => second >= first
=============================================================================
