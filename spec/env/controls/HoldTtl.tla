------------------------------ MODULE HoldTtl -------------------------------
\* A toy that must fail under Env when a hold outlives the MemoryStore
\* item it lives in.
\*
\* One server reserves a hold that lasts Long ticks, counted from when it
\* sends its first call. With TwoCalls TRUE it uses two calls. An
\* UpdateAsync with expiry Book writes the hold. Once that answers "ok", a
\* second UpdateAsync with expiry Long rewrites the item to live as long
\* as the hold, and the server answers "held" whatever the second call
\* answers, since nothing read that answer. With TwoCalls FALSE, the fix,
\* one UpdateAsync with expiry Long writes the hold, and the server
\* answers "held" on "ok". An expiry is fixed when a call is sent [M4,
\* M10], so no run of a transform can push it out from what it read. Book
\* is below Long. sentAt is a ghost of the true time the first call was
\* sent.
\*
\* HoldKept says that while a hold the server answered "held" for has not
\* ended, its item is there. With TwoCalls and MsFail the second call
\* fails, the item expires at Book, and it fails. With one call it holds
\* with MsFail on.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
HoldTtl_typedefs == TRUE

CONSTANTS
    \* @type: Bool;
    TwoCalls,
    \* @type: Int;
    Book,
    \* @type: Int;
    Long

ASSUME Book < Long

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    mq,
    \* @type: Int;
    sentAt,
    \* @type: Str;
    told

vars == <<envVars, pc, mq, sentAt, told>>

S == CHOOSE s \in Servers : TRUE
M == CHOOSE m \in MKeys : TRUE

\* No datastore call is made.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* Each call writes the hold, whatever it reads.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsWrite(c, 1)

Init == EnvInit(0, 0) /\ pc = "reserve" /\ mq = 0 /\ sentAt = 0 /\ told = "none"

Reserve ==
    /\ pc = "reserve"
    /\ MsIssue(S, M, 1, IF TwoCalls THEN Book ELSE Long)
    /\ mq' = NextMsReq
    /\ sentAt' = now
    /\ pc' = "wait"
    /\ UNCHANGED told

Heard1 ==
    /\ pc = "wait"
    /\ \E a \in MsHeard :
          /\ MsReply(mq, a)
          /\ IF a # "ok"
             THEN pc' = "done" /\ told' = "unresolved"
             ELSE IF TwoCalls
                  THEN pc' = "extend" /\ UNCHANGED told
                  ELSE pc' = "done" /\ told' = "held"
    /\ UNCHANGED <<mq, sentAt>>

Extend ==
    /\ pc = "extend"
    /\ MsIssue(S, M, 2, Long)
    /\ mq' = NextMsReq
    /\ pc' = "extending"
    /\ UNCHANGED <<sentAt, told>>

\* The server reads nothing of the second answer.
Heard2 ==
    /\ pc = "extending"
    /\ \E a \in MsHeard : MsReply(mq, a)
    /\ pc' = "done"
    /\ told' = "held"
    /\ UNCHANGED <<mq, sentAt>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, mq, sentAt, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, mq, sentAt, told>>
    \/ CrashAll /\ UNCHANGED <<pc, mq, sentAt, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, mq, sentAt, told>>
    \/ Reserve \/ Heard1 \/ Extend \/ Heard2

HoldKept == told = "held" /\ now < sentAt + Long => MsView(M).has
=============================================================================
