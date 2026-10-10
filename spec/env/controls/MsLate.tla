------------------------------- MODULE MsLate -------------------------------
\* A toy that must fail under Env. It takes a MemoryStore write whose
\* answer never came, or came as an error, for one that never applied.
\*
\* One server writes an item with a MemoryStore SetAsync. On "ok" it
\* answers yes. On an error, or after a crash in its next incarnation, it
\* reads the key with a GetAsync, again after each failed read, and
\* answers a definite no if the read shows no item: "not applied now and
\* not later". The item lives longer than the model's time, and no item
\* vanishes, so a read that shows no item means the write had not applied
\* by then.
\*
\* TrueNo says the no is true: the write never applies. With MsMaybe, the
\* write may apply after the no. After a crash that costs the crash alone,
\* one fault [S2, M11]. After the server loses MemoryStore it costs the
\* cut alone, since each error to a cut server stands for every outcome
\* MsMaybe allows [M9]. With MsMaybe off, a write applies only while its
\* server waits on it and reaches MemoryStore, so it holds with crashes
\* and cuts on.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
MsLate_typedefs == TRUE

CONSTANT
    \* @type: Int;
    Ttl

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    mq,
    \* @type: Str;
    told

vars == <<envVars, pc, mq, told>>

S == CHOOSE s \in Servers : TRUE
M == CHOOSE m \in MKeys : TRUE

\* No datastore call is made.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "write" /\ mq = 0 /\ told = "none"

Put ==
    /\ pc = "write"
    /\ MsIssueSet(S, M, 0, Item(1, Ttl))
    /\ mq' = NextMsReq
    /\ pc' = "wait"
    /\ UNCHANGED told

Hear ==
    /\ pc = "wait"
    /\ \E a \in MsHeard :
          /\ MsReply(mq, a)
          /\ IF a = "ok" THEN pc' = "done" /\ told' = "yes" ELSE pc' = "check" /\ UNCHANGED told
    /\ UNCHANGED mq

\* The server loses its memory. Its next life only checks.
Lost(s) == Crash(s) /\ pc' = "down" /\ UNCHANGED <<mq, told>>
Back(s) == Restart(s) /\ pc' = "check" /\ UNCHANGED <<mq, told>>
LostAll == CrashAll /\ pc' = "down" /\ UNCHANGED <<mq, told>>

Check ==
    /\ pc = "check"
    /\ MsIssueGet(S, M, 0)
    /\ mq' = NextMsReq
    /\ pc' = "checking"
    /\ UNCHANGED told

\* On "ok" the server reads seen, the item its read handed back.
Checked ==
    /\ pc = "checking"
    /\ \E a \in MsHeard :
          /\ MsReply(mq, a)
          /\ IF a = "ok"
             THEN pc' = "done" /\ told' = IF mreq[mq].seen.has THEN "yes" ELSE "no"
             ELSE pc' = "check" /\ UNCHANGED told
    /\ UNCHANGED mq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, mq, told>>
    \/ \E s \in Servers : Lost(s) \/ Back(s)
    \/ LostAll
    \/ Put \/ Hear \/ Check \/ Checked

\* The write applied at some step. For the invariant only.
Applied == \E r \in DOMAIN mreq : mreq[r].kind = "set" /\ mreq[r].ph = "applied"

TrueNo == told = "no" => ~Applied
=============================================================================
