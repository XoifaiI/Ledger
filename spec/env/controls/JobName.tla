------------------------------ MODULE JobName ------------------------------
\* A toy that must fail under Env when a server names itself by s instead
\* of by its life. A restarted server is a new process with a new job id
\* [S1], and a design names each lease holder by that id.
\*
\* One server takes a lease in MemoryStore. Its transform writes the
\* server's name when no live item is there or the item already names it,
\* and cancels otherwise. On "ok" the server says the lease is its own,
\* and on "nil" that another holds it. The item lives Ttl ticks from when
\* it applies. The server may crash after it took the lease. Its next life
\* takes the lease again. ByLife says the name is Job(s). With ByLife
\* FALSE the name is s alone, as a protocol that cannot read a name for
\* its life would write it. leftAt is a ghost of the tick until which the
\* item the last life wrote lives.
\*
\* WaitsOld says a life says the lease is its own only once no item an
\* earlier life wrote is live. With ByLife FALSE the next life reads an
\* item that names s, takes it as its own at once, and it fails. On Roblox
\* that life has a new job id and reads the lease as held. With ByLife
\* TRUE the next life reads an item that names another life and cancels,
\* and it holds. Crashes is the one fault.
\*
\* With Peek TRUE the transform breaks the rule of Env that a server step
\* tests a life name only for equality. It reads the parts of the name it
\* finds. When the name is of its own server and of an earlier life, it
\* takes the lease as its own at once, since it knows that life is dead.
\* WaitsOld fails. On Roblox a job id is an opaque GUID, so no life can
\* make that test. Env cannot stop the read, and this control shows what
\* the rule keeps out.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = <<Str, Int>>;
JobName_typedefs == TRUE

CONSTANTS
    \* @type: Bool;
    ByLife,
    \* @type: Int;
    Ttl,
    \* @type: Bool;
    Peek

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    mq,
    \* @type: Str;
    told,
    \* @type: Int;
    leftAt

vars == <<envVars, pc, mq, told, leftAt>>

S == CHOOSE s \in Servers : TRUE
M == CHOOSE mk \in MKeys : TRUE

\* The name a take writes: the life of s, or s alone.
\* @type: Str => <<Str, Int>>;
Me(s) == IF ByLife THEN Job(s) ELSE <<s, 0>>

\* No datastore UpdateAsync is sent.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* An earlier life of this server holds the item. Only a design that reads the parts of a name,
\* which Env's rule forbids, can make this test.
\* @type: ($ctx, <<Str, Int>>) => Bool;
OwnDead(c, v) == Peek /\ v[1] = c.srv /\ v[2] < Job(c.srv)[2]

\* Take the lease when no live item is there or the item names this server.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) ==
    IF it.has /\ it.v # Me(c.srv) /\ ~OwnDead(c, it.v) THEN MsCancel(c, it) ELSE MsWrite(c, Me(c.srv))

\* A missing item shows a name no life has.
Init == EnvInit(0, <<S, -1>>) /\ pc = "take" /\ mq = 0 /\ told = "none" /\ leftAt = -1

Take ==
    /\ pc = "take"
    /\ MsIssue(S, M, 1, Ttl)
    /\ mq' = NextMsReq
    /\ pc' = "wait"
    /\ UNCHANGED <<told, leftAt>>

Hear ==
    /\ pc = "wait"
    /\ \E a \in MsHeard :
          /\ MsReply(mq, a)
          /\ told' = CASE a = "ok" -> "mine" [] a = "nil" -> "held" [] OTHER -> "unknown"
    /\ pc' = "done"
    /\ UNCHANGED <<mq, leftAt>>

\* The server loses its memory. leftAt is a ghost that reads the truth: the tick the item this
\* life wrote expires, if it is live.
Lost(s) ==
    /\ Crash(s)
    /\ pc' = "down"
    /\ told' = "none"
    /\ leftAt' = IF Live(ms[M]) THEN ms[M].exp ELSE leftAt
    /\ UNCHANGED mq

Back(s) == Restart(s) /\ pc' = "take" /\ UNCHANGED <<mq, told, leftAt>>

\* One server, so every server crashing at once is the same crash.
LostAll ==
    /\ CrashAll
    /\ pc' = "down"
    /\ told' = "none"
    /\ leftAt' = IF Live(ms[M]) THEN ms[M].exp ELSE leftAt
    /\ UNCHANGED mq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, mq, told, leftAt>>
    \/ \E s \in Servers : Lost(s) \/ Back(s)
    \/ LostAll
    \/ Take \/ Hear

WaitsOld == told = "mine" => now >= leftAt
=============================================================================
