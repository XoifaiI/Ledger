------------------------------ MODULE MsDedupe ------------------------------
\* A toy that must fail under Env. It keeps dedupe in MemoryStore.
\*
\* One server gets op x twice, one delivery after the other. Each delivery
\* reads a MemoryStore item for x with a GetAsync. If the read shows the
\* item, it skips. Otherwise it writes x to the key with an UpdateAsync
\* whose transform does not check, then writes the item with a SetAsync
\* whose time to live is longer than the model's time. A delivery ends
\* once the item write answers. A MemoryStore call that fails counts as a
\* miss, so the delivery does the work.
\*
\* The value is how many times x applied. AtMostOnce says x applied at
\* most once. With MsVanish the item may vanish before its expiry, so the
\* second delivery applies x again [M7]. With MsStale the second read may
\* see the key as it was before the item was written, and that costs no
\* fault [M12]. With MsVanish, MsStale, MsFail and MsMaybe off and
\* MemoryStore up, it holds.
\*
\* With AfterCalm the first read waits for calm. The guard reads calm. It
\* only stages the scenario, and no design reads calm. Then MsVanish, a
\* fault, cannot take the item, since no fault happens once calm, and the
\* toy holds. MsEvict takes it at no fault, after calm as well, and the
\* second delivery applies x again [M7]. LifeAfterCalm holds MsEvict off
\* until the item lived that many ticks since calm. With Ttl past
\* MaxExpiry the item write answers "err" at no fault, each time, and
\* nothing is written, so the second delivery applies x again [M4].
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
MsDedupe_typedefs == TRUE

CONSTANTS
    \* @type: Int;
    Ttl,
    \* @type: Bool;
    AfterCalm

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    round,
    \* @type: Int;
    rq,
    \* @type: Int;
    mq

vars == <<envVars, pc, round, rq, mq>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE
M == CHOOSE m \in MKeys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, v + 1)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "check" /\ round = 1 /\ rq = 0 /\ mq = 0

\* @type: Str;
Done == IF round = 2 THEN "done" ELSE "check"

Check ==
    /\ pc = "check"
    /\ AfterCalm => calm
    /\ MsIssueGet(S, M, 0)
    /\ mq' = NextMsReq
    /\ pc' = "checking"
    /\ UNCHANGED <<round, rq>>

\* On "ok" the server reads seen, the item its read handed back.
Checked ==
    /\ pc = "checking"
    /\ \E a \in MsHeard :
          /\ MsReply(mq, a)
          /\ IF a = "ok" /\ mreq[mq].seen.has
             THEN pc' = Done /\ round' = round + 1
             ELSE pc' = "write" /\ UNCHANGED round
    /\ UNCHANGED <<rq, mq>>

Send ==
    /\ pc = "write"
    /\ Issue(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = "wait"
    /\ UNCHANGED <<round, mq>>

Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard : Reply(rq, a)
    /\ pc' = "mark"
    /\ UNCHANGED <<round, rq, mq>>

Mark ==
    /\ pc = "mark"
    /\ MsIssueSet(S, M, 0, Item(1, Ttl))
    /\ mq' = NextMsReq
    /\ pc' = "marking"
    /\ UNCHANGED <<round, rq>>

Marked ==
    /\ pc = "marking"
    /\ \E a \in MsHeard : MsReply(mq, a)
    /\ pc' = Done
    /\ round' = round + 1
    /\ UNCHANGED <<rq, mq>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, round, rq, mq>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, round, rq, mq>>
    \/ CrashAll /\ UNCHANGED <<pc, round, rq, mq>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, round, rq, mq>>
    \/ Check \/ Checked \/ Send \/ Hear \/ Mark \/ Marked

AtMostOnce == Cur(K) <= 1
=============================================================================
