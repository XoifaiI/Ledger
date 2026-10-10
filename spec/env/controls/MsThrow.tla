------------------------------ MODULE MsThrow -------------------------------
\* A toy that shows a MemoryStore transform that throws gives its server
\* an error, at no fault, and keeps a change its call applied before. On
\* Roblox the call raises TransformCallbackFailed, unlike a datastore
\* transform [M10]. A transform may run under a guard that throws on a
\* throw or a yield.
\*
\* One server sends MemoryStore UpdateAsync calls to one key, one after
\* another, up to MaxMsReqs. The transform writes 1 when no item is there.
\* When an item is there, it throws with Throws, as a transform that
\* cannot decode what it read, and it cancels without.
\*
\* NeverErr says the server never hears "err". With every fault off and
\* Throws, the second call throws and answers "err", so NeverErr fails at
\* no fault. ErrMeansNone says a call that answered "err" left no item.
\* Under LoseCommit a run may follow the applying, and with Throws it
\* throws, so the call answers "err" while its item stays, and
\* ErrMeansNone fails. Without Throws that run cancels, the call answers
\* "nil", and both hold.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
MsThrow_typedefs == TRUE

CONSTANTS
    \* @type: Bool;
    Throws,
    \* @type: Int;
    Ttl

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    mq,
    \* @type: Bool;
    errSeen,
    \* @type: Bool;
    errKept

vars == <<envVars, pc, mq, errSeen, errKept>>

S == CHOOSE s \in Servers : TRUE
M == CHOOSE m \in MKeys : TRUE

\* No datastore call is made.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* @type: ($ctx, $view) => $mout;
MsTf(c, it) ==
    IF ~it.has THEN MsWrite(c, 1)
    ELSE IF Throws THEN MsThrow(c) ELSE MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "send" /\ mq = 0 /\ errSeen = FALSE /\ errKept = FALSE

Send ==
    /\ pc = "send"
    /\ MsIssue(S, M, 1, Ttl)
    /\ mq' = NextMsReq
    /\ pc' = "wait"
    /\ UNCHANGED <<errSeen, errKept>>

Hear ==
    /\ pc = "wait"
    /\ \E a \in MsHeard :
          /\ MsReply(mq, a)
          /\ errSeen' = (errSeen \/ a = "err")
          /\ errKept' = (errKept \/ (a = "err" /\ MsView(M).has))
    /\ pc' = "send"
    /\ UNCHANGED mq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, mq, errSeen, errKept>>
    \/ Send \/ Hear

NeverErr == ~errSeen
ErrMeansNone == ~errKept
=============================================================================
