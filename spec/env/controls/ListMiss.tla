------------------------------ MODULE ListMiss ------------------------------
\* A toy that must fail under Env when a listing misses a key. It takes a
\* key the listing did not return for a key nobody wrote.
\*
\* One server writes a key with an UpdateAsync. Once it hears "ok", and
\* when Removes is TRUE, it removes the key with a RemoveAsync and waits
\* for "ok". Then it lists the keys with ListKeysAsync, page by page,
\* until the listing ends. Ex says the listing passes excludeDeleted. If
\* the key was not on any page, it answers that the key was never written.
\* A page that fails ends the walk with no answer.
\*
\* TrueGone says that answer is true. With StaleList the listing may end
\* without the key, although it was written before the listing began
\* [D20], so it fails. With StaleList off and nothing removed, a listing
\* returns every key written before it began, so it holds. With the key
\* removed and excludeDeleted passed, the listing leaves the removed key
\* out, so it fails with StaleList off. That is the design that finds
\* removed keys by listing with excludeDeleted. Without excludeDeleted a
\* removed key stays listed, so it holds.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
ListMiss_typedefs == TRUE

CONSTANTS
    \* @type: Bool;
    Removes,
    \* @type: Bool;
    Ex

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Set(Str);
    listed,
    \* @type: Str;
    told

vars == <<envVars, pc, rq, listed, told>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, 1)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "send" /\ rq = 0 /\ listed = {} /\ told = "none"

Send ==
    /\ pc = "send"
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ pc' = "wait"
    /\ UNCHANGED <<listed, told>>

Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ pc' = IF a # "ok" THEN "done" ELSE IF Removes THEN "remove" ELSE "list"
    /\ UNCHANGED <<rq, listed, told>>

\* RemoveAsync writes z, which is 0 here.
Remove ==
    /\ pc = "remove"
    /\ IssueSet(S, K, 0, 0)
    /\ rq' = NextReq
    /\ pc' = "removing"
    /\ UNCHANGED <<listed, told>>

Removed ==
    /\ pc = "removing"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ pc' = IF a = "ok" THEN "list" ELSE "done"
    /\ UNCHANGED <<rq, listed, told>>

Begin ==
    /\ pc = "list"
    /\ ListStart(S, Ex)
    /\ pc' = "page"
    /\ UNCHANGED <<rq, listed, told>>

Ask ==
    /\ pc = "page"
    /\ ListAsk(S)
    /\ pc' = "paging"
    /\ UNCHANGED <<rq, listed, told>>

Page ==
    /\ pc = "paging"
    /\ \E k \in Keys, a \in ListHeard :
          /\ ListPage(S, k, a)
          /\ CASE a = "ok" -> listed' = listed \cup {k} /\ pc' = "page" /\ UNCHANGED told
               [] a = "end" -> /\ pc' = "done"
                               /\ told' = IF K \in listed THEN "written" ELSE "gone"
                               /\ UNCHANGED listed
               [] OTHER -> pc' = "done" /\ UNCHANGED <<listed, told>>
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, listed, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, listed, told>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, listed, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, listed, told>>
    \/ Send \/ Hear \/ Remove \/ Removed \/ Begin \/ Ask \/ Page

TrueGone == told = "gone" => K \notin Written
=============================================================================
