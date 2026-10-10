------------------------------ MODULE WipeAll -------------------------------
\* A toy that must fail under Env when a design counts on MemoryStore to
\* lose at most one item for one fault.
\*
\* One server writes an item under each of two MemoryStore keys with a
\* SetAsync, one after the other, and waits for "ok" on each. Each item
\* lives longer than the model's time. It gives up if a write answers an
\* error. Then it reads each key with a GetAsync, again after each failed
\* read, and answers "lost" when both reads show no item.
\*
\* SomeKept says the server never answers "lost". With MsVanish and
\* MaxFaults 1 one item may vanish and the other stays, so it holds. With
\* MsOutage an outage may lose every item at once, for one fault, since
\* MemoryStore is not durable and nothing says an item outlives an outage
\* [M5, M8]. So it fails.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
WipeAll_typedefs == TRUE

CONSTANTS
    \* @type: Str;
    M1,
    \* @type: Str;
    M2,
    \* @type: Int;
    Ttl

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    mq,
    \* @type: Int;
    found,
    \* @type: Str;
    told

vars == <<envVars, pc, mq, found, told>>

S == CHOOSE s \in Servers : TRUE

\* No datastore call is made.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "put1" /\ mq = 0 /\ found = 0 /\ told = "none"

\* @type: (Str, Str, Str) => Bool;
Put(at, mk, next) ==
    /\ pc = at
    /\ MsIssueSet(S, mk, 0, Item(1, Ttl))
    /\ mq' = NextMsReq
    /\ pc' = next
    /\ UNCHANGED <<found, told>>

\* @type: (Str, Str) => Bool;
PutHeard(at, next) ==
    /\ pc = at
    /\ \E a \in MsHeard :
          /\ MsReply(mq, a)
          /\ pc' = IF a = "ok" THEN next ELSE "done"
    /\ UNCHANGED <<mq, found, told>>

\* @type: (Str, Str, Str) => Bool;
Look(at, mk, next) ==
    /\ pc = at
    /\ MsIssueGet(S, mk, 0)
    /\ mq' = NextMsReq
    /\ pc' = next
    /\ UNCHANGED <<found, told>>

\* On "ok" the server reads seen, the item its read handed back. It reads again after an error.
\* @type: (Str, Str, Str) => Bool;
Looked(at, back, next) ==
    /\ pc = at
    /\ \E a \in MsHeard :
          /\ MsReply(mq, a)
          /\ IF a = "ok"
             THEN /\ pc' = next
                  /\ found' = found + (IF mreq[mq].seen.has THEN 1 ELSE 0)
                  /\ told' = IF next = "done" /\ found' = 0 THEN "lost" ELSE told
             ELSE pc' = back /\ UNCHANGED <<found, told>>
    /\ UNCHANGED mq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, mq, found, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, mq, found, told>>
    \/ CrashAll /\ UNCHANGED <<pc, mq, found, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, mq, found, told>>
    \/ Put("put1", M1, "wait1") \/ PutHeard("wait1", "put2")
    \/ Put("put2", M2, "wait2") \/ PutHeard("wait2", "get1")
    \/ Look("get1", M1, "read1") \/ Looked("read1", "get1", "get2")
    \/ Look("get2", M2, "read2") \/ Looked("read2", "get2", "done")

SomeKept == told # "lost"
=============================================================================
