------------------------------ MODULE Evidence ------------------------------
\* A toy that must fail under Env when a MemoryStore read fails or is
\* stale. It answers Busy from a lease it did not see stand.
\*
\* The writer takes a lease under one MemoryStore key with an UpdateAsync
\* whose expiry is Ttl and whose transform writes an item when no live
\* item is there. If it hears "ok" and Drop is TRUE, it removes the item
\* with a RemoveAsync. With Drop FALSE it keeps the lease until it
\* expires, as a design does that holds a lease on after its work is done.
\* The reader reads the key once with a GetAsync. On "ok" it answers Busy
\* when the read showed a live item, and free when it did not. When the
\* read fails, it answers Busy too, unless Positive is TRUE. Positive is
\* the fix: it makes a lease positive evidence only, so a failed read
\* means go on.
\*
\* TrueBusy says a Busy is true: at the moment the read read the key, the
\* item it saw was live, and it is the item as it reads now. That is the
\* lease standing at some moment during the call, as A10 asks of a hold
\* answer. cur is the ghost that says the read saw the key as it reads
\* now. Each of MsFail [M6], MsOutage [M8], MsSplit [M9] and MsOn FALSE
\* makes the read fail, so each one alone breaks TrueBusy with Positive
\* FALSE. With all four off and Positive FALSE it holds. With Positive
\* TRUE it still fails with MsStale on, at no fault [M12], in two ways.
\* The writer removes its item, and a read sees the item from before the
\* removal. Or the writer keeps its item, and a read sees it as it was
\* before it expired. With Positive TRUE and MsStale off TrueBusy cannot
\* fail: a read that answers "ok" then saw the item as it reads now, so a
\* Busy from it is true by the definition of TrueBusy, and an error
\* answers free. So that pass shows only that positive evidence leaves
\* freshness as the one cause of a false Busy. The other MemoryStore
\* faults are on there only to show they add no path.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
Evidence_typedefs == TRUE

CONSTANTS
    \* @type: Bool;
    Positive,
    \* @type: Bool;
    Drop,
    \* @type: Int;
    Ttl,
    \* @type: Str;
    Writer,
    \* @type: Str;
    Reader

VARIABLES
    \* @type: Str;
    wpc,
    \* @type: Int;
    wq,
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Str;
    told

vars == <<envVars, wpc, wq, pc, rq, told>>

M == CHOOSE m \in MKeys : TRUE

\* No datastore call is made.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* The writer's take: write the lease when no live item is there.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == IF it.has THEN MsCancel(c, it) ELSE MsWrite(c, 1)

Init == EnvInit(0, 0) /\ wpc = "take" /\ wq = 0 /\ pc = "read" /\ rq = 0 /\ told = "none"

Take ==
    /\ wpc = "take"
    /\ MsIssue(Writer, M, 1, Ttl)
    /\ wq' = NextMsReq
    /\ wpc' = "taking"
    /\ UNCHANGED <<pc, rq, told>>

Taken ==
    /\ wpc = "taking"
    /\ \E a \in MsHeard :
          /\ MsReply(wq, a)
          /\ wpc' = IF a = "ok" /\ Drop THEN "drop" ELSE "done"
    /\ UNCHANGED <<wq, pc, rq, told>>

Remove ==
    /\ wpc = "drop"
    /\ MsIssueSet(Writer, M, 0, NoItem)
    /\ wq' = NextMsReq
    /\ wpc' = "dropping"
    /\ UNCHANGED <<pc, rq, told>>

Removed ==
    /\ wpc = "dropping"
    /\ \E a \in MsHeard : MsReply(wq, a)
    /\ wpc' = "done"
    /\ UNCHANGED <<wq, pc, rq, told>>

Read ==
    /\ pc = "read"
    /\ MsIssueGet(Reader, M, 0)
    /\ rq' = NextMsReq
    /\ pc' = "reading"
    /\ UNCHANGED <<wpc, wq, told>>

\* On "ok" the reader reads seen, the item its read handed back.
Answer ==
    /\ pc = "reading"
    /\ \E a \in MsHeard :
          /\ MsReply(rq, a)
          /\ told' = IF a = "ok"
                     THEN (IF mreq[rq].seen.has THEN "busy" ELSE "free")
                     ELSE (IF Positive THEN "free" ELSE "busy")
    /\ pc' = "done"
    /\ UNCHANGED <<wpc, wq, rq>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<wpc, wq, pc, rq, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<wpc, wq, pc, rq, told>>
    \/ CrashAll /\ UNCHANGED <<wpc, wq, pc, rq, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<wpc, wq, pc, rq, told>>
    \/ Take \/ Taken \/ Remove \/ Removed \/ Read \/ Answer

TrueBusy == told = "busy" => mreq[rq].cur /\ mreq[rq].seen.has
=============================================================================
