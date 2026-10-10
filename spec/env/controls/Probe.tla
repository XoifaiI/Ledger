------------------------------- MODULE Probe -------------------------------
\* Probe drives every action of Env with no protocol behind it. Any server
\* may send any call, hear any answer Env allows, read, list, crash alone
\* or with every other server, and send any MemoryStore call. A GetAsync
\* and each page of a listing are calls in steps: a send, a read and an
\* answer. Probe checks that Env keeps EnvHolds with every fault on,
\* spread over eight configs, and it is the model Apalache type checks and
\* runs with every switch on at once. A value is a record, so the check
\* also shows that a protocol's own value type replaces Env's default. A
\* server sends a blind write to a key only when it has none out there,
\* which is the rule EnvSetsApart states. The transform of argument 0
\* cancels on an empty key and writes back what it read on any other. No
\* transform writes z, which is the rule EnvNoZWrite states. The transform
\* of argument 2 keeps a note of the value it read, so a note that carries
\* across runs is driven too. With Again, a server may send a call again
\* with the closure of an earlier one, so a note that retries share is
\* driven. The MemoryStore transform of argument 0 cancels on a missing
\* item and throws on an item, argument 2 writes whatever it reads and
\* notes whether it saw an item, and argument 1 writes only on a missing
\* item. Ttls is the set of expiries a MemoryStore UpdateAsync may carry,
\* and an expiry of 0 makes the write a removal. Args is the set of
\* arguments a call may carry. Lists is the set of excludeDeleted values a
\* listing may pass, so servers list only when it is not empty. Gets says
\* a server may send a GetAsync, and Listers is the set of servers that
\* may list. Each config names its own, to keep the model small enough to
\* finish. Hold is FALSE, as a safety check passes it. DelayLive drives a
\* Hold. Every send spends from its server's budget, and ProbeBudget.cfg
\* turns Budgets on, so the refills, the drops and a restart's budget are
\* driven. An expiry in Ttls past MaxExpiry drives the error of M4, and
\* ProbeMemory.cfg turns MsEvict on.
EXTENDS Env

\* @typeAlias: val = { n: Int };
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
Probe_typedefs == TRUE

CONSTANTS
    \* @type: Set(Int);
    Args,
    \* @type: Set(Bool);
    Lists,
    \* @type: Bool;
    Again,
    \* @type: Set(Int);
    Ttls,
    \* @type: Bool;
    Gets,
    \* @type: Set(Str);
    Listers

Zero == [n |-> 0]

\* Argument 0 cancels on an empty key, and on any other key it writes back the value it read,
\* which lands a version that changes nothing. Argument 2 writes and notes what it read. Any
\* other argument adds itself. No argument writes z, as the rule EnvNoZWrite checks says.
\* @type: ($ctx, { n: Int }) => $out;
Tf(c, v) ==
    CASE c.arg = 0 -> IF v.n = 0 THEN Cancel(c, v) ELSE Write(c, v)
      [] c.arg = 2 -> WriteNote([n |-> v.n + 2], v.n)
      [] OTHER -> Write(c, [n |-> v.n + c.arg])

\* Argument 0 cancels on a missing item and throws on an item, as a transform that cannot decode
\* what it read. Argument 2 writes 2 whatever it reads, and notes whether it saw an item. Any other
\* argument writes 1 when no item is there, and cancels when one is.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) ==
    CASE c.arg = 0 -> IF it.has THEN MsThrow(c) ELSE MsCancel(c, it)
      [] c.arg = 2 -> MsWriteNote(2, IF it.has THEN 1 ELSE 0)
      [] OTHER -> IF it.has THEN MsCancel(c, it) ELSE MsWrite(c, 1)

Init == EnvInit(Zero, 0)

Step ==
    \/ \E s \in Servers, k \in Keys, a \in Args : Issue(s, k, a)
    \/ Again /\ \E s \in Servers, r \in DOMAIN req, a \in Args : IssueAgain(s, r, a)
    \/ \E s \in Servers, k \in Keys : ~SetOut(s, k) /\ IssueSet(s, k, 0, Zero)
    \/ \E r \in DOMAIN req, a \in Heard : Reply(r, a)
    \/ Gets /\ \E s \in Servers, k \in Keys : IssueGet(s, k, 0)
    \/ \E s \in Listers, ex \in Lists : ListStart(s, ex)
    \/ \E s \in Listers : ListAsk(s)
    \/ \E s \in Listers, k \in Keys, a \in ListHeard : ListPage(s, k, a)
    \/ \E s \in Servers, mk \in MKeys, a \in Args, t \in Ttls : MsIssue(s, mk, a, t)
    \/ \E s \in Servers, mk \in MKeys : MsIssueSet(s, mk, 0, Item(1, 1)) \/ MsIssueSet(s, mk, 0, NoItem)
    \/ \E s \in Servers, mk \in MKeys : MsIssueGet(s, mk, 0)
    \/ \E r \in DOMAIN mreq, a \in MsHeard : MsReply(r, a)

Next ==
    \/ EnvNext(Tf, MsTf, FALSE)
    \/ \E s \in Servers : Crash(s)
    \/ CrashAll
    \/ \E s \in Servers : Restart(s)
    \/ Step

\* Constants for Apalache, which cannot read model values from a TLC config.
ConstInit ==
    /\ Servers = {"s1", "s2"}
    /\ Keys = {"k1"}
    /\ MKeys = {"m1"}
    /\ MaxReqs = 2
    /\ MaxMsReqs = 2
    /\ MaxTime = 1
    /\ MaxSkew = 1
    /\ MaxFaults = 2
    /\ FailBefore = TRUE /\ LoseAnswer = TRUE /\ LoseCommit = TRUE /\ LateLand = TRUE
    /\ DsSplit = TRUE /\ DsOutage = TRUE /\ Reverts = TRUE
    /\ Crashes = TRUE /\ Shutdowns = TRUE /\ ClockJumps = TRUE /\ ClockSteps = TRUE
    /\ MsFail = TRUE /\ MsMaybe = TRUE /\ MsVanish = TRUE /\ MsOutage = TRUE /\ MsSplit = TRUE
    /\ StaleGet = TRUE /\ StaleRun = TRUE /\ StaleList = TRUE /\ MsStale = TRUE
    /\ RunAfterAnswer = TRUE /\ KeyInfo = TRUE /\ MsOn = TRUE
    /\ LagAfterCalm = 1 /\ DelayAfterCalm = 1 /\ SkewAfterCalm = 0
    /\ MsEvict = TRUE /\ Budgets = TRUE /\ MaxBudget = 1 /\ BudgetAfterCalm = 1 /\ LifeAfterCalm = 1
    /\ MaxExpiry = 1
    /\ Args = {0, 1, 2} /\ Lists = {FALSE, TRUE} /\ Again = TRUE /\ Ttls = {0, 1, 2} /\ Gets = TRUE
    /\ Listers = Servers
=============================================================================
