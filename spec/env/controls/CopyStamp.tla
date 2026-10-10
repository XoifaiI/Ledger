----------------------------- MODULE CopyStamp ------------------------------
\* A toy that must fail under Env when a server orders its own write by
\* the stamp its answer carries. The server keeps a copy of a key with the
\* stamp of the state it holds. After a write of its own it keeps the
\* copy's state when the stamp of its write's answer is not above the
\* copy's.
\*
\* One server writes op 1 to a key with an UpdateAsync and waits for "ok".
\* It then reads the key with a GetAsync, fresh since StaleGet is off, and
\* keeps a copy: the value and its stamp. Then it writes op 2 with an
\* UpdateAsync. On "ok" it reads u, the stamp of the version its write
\* made [D17]. With ByStamp TRUE it takes the value its write made into
\* the copy only when u is above the copy's stamp. With ByStamp FALSE it
\* always takes it, which is the fix.
\*
\* OwnKept says that once the second write answered "ok", the copy holds a
\* state no older than that write. With KeyInfo a stamp is any tick and
\* need not rise [D17], so the answer's stamp may be at or below the
\* copy's. Then the copy keeps the older state, and it fails. With ByStamp
\* FALSE it holds.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
CopyStamp_typedefs == TRUE

CONSTANT
    \* @type: Bool;
    ByStamp

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Int;
    copyV,
    \* @type: Int;
    copyU

vars == <<envVars, pc, rq, copyV, copyU>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, v + 1)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "w1" /\ rq = 0 /\ copyV = 0 /\ copyU = NoStamp

\* @type: (Str, Str) => Bool;
Send(at, next) ==
    /\ pc = at
    /\ Issue(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = next
    /\ UNCHANGED <<copyV, copyU>>

HearOne ==
    /\ pc = "h1"
    /\ Reply(rq, "ok")
    /\ pc' = "read"
    /\ UNCHANGED <<rq, copyV, copyU>>

Ask ==
    /\ pc = "read"
    /\ IssueGet(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = "reading"
    /\ UNCHANGED <<copyV, copyU>>

Copy ==
    /\ pc = "reading"
    /\ Reply(rq, "ok")
    /\ copyV' = ReadOf(rq).v
    /\ copyU' = ReadOf(rq).u
    /\ pc' = "w2"
    /\ UNCHANGED rq

\* On "ok" the server reads res, the value its write made, and u, its stamp.
HearTwo ==
    /\ pc = "h2"
    /\ Reply(rq, "ok")
    /\ IF ByStamp /\ req[rq].u <= copyU
       THEN UNCHANGED <<copyV, copyU>>
       ELSE copyV' = req[rq].res /\ copyU' = req[rq].u
    /\ pc' = "done"
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, copyV, copyU>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, copyV, copyU>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, copyV, copyU>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, copyV, copyU>>
    \/ Send("w1", "h1") \/ HearOne \/ Ask \/ Copy \/ Send("w2", "h2") \/ HearTwo

OwnKept == pc = "done" => copyV >= 2
=============================================================================
