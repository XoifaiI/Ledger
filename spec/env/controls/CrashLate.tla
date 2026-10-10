----------------------------- MODULE CrashLate -----------------------------
\* A toy that must fail under Env. It assumes a write whose answer never
\* came, or came as an error, cannot land after a fresh read.
\*
\* One server writes op x with an UpdateAsync. It may crash while the call
\* is out, or hear an error. Either way it then recovers: it reads the key
\* with GetAsync, and if x is not there it answers a definite no, which
\* means "not applied now and not later". After a crash the new
\* incarnation recovers. After an error the same one does. The read is
\* fresh, since StaleGet is off.
\*
\* The value is how many times x applied. TrueNo says a definite no is
\* true: x never applies. With LateLand, the write in flight lands after
\* the no, on the version its transform read [D13, D14, S2]. With LateLand
\* off, a crash or an error ends every write that had not landed, so a
\* fresh read after it is final. The configs named CrashLate put the crash
\* in and leave errors out. The configs named ErrLate leave crashes out
\* and put the errors of FailBefore and LoseAnswer in.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
CrashLate_typedefs == TRUE

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
Tf(c, v) == IF v = 0 THEN Write(c, 1) ELSE Cancel(c, v)

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
          /\ IF a = "err"
             THEN pc' = "recover" /\ UNCHANGED told
             ELSE pc' = "done" /\ told' = "yes"
    /\ UNCHANGED rq

\* The server loses its memory. Its next life only recovers.
Lost(s) == Crash(s) /\ pc' = "down" /\ UNCHANGED <<rq, told>>
LostAll == CrashAll /\ pc' = "down" /\ UNCHANGED <<rq, told>>
Back(s) == Restart(s) /\ pc' = "recover" /\ UNCHANGED <<rq, told>>

Recover ==
    /\ pc = "recover"
    /\ IssueGet(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = "reading"
    /\ UNCHANGED told

\* A read that fails leaves the answer unknown.
Decide ==
    /\ pc = "reading"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ told' = IF a # "ok" THEN "unknown" ELSE IF ReadOf(rq).v = 0 THEN "no" ELSE "yes"
    /\ pc' = "done"
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Lost(s)
    \/ LostAll
    \/ \E s \in Servers : Back(s)
    \/ Send \/ Hear \/ Recover \/ Decide

TrueNo == told = "no" => Cur(K) = 0
=============================================================================
