------------------------------ MODULE ZWrite --------------------------------
\* A toy that must fail under Env when a protocol's own reducer computes
\* z. z means no value. On Roblox a transform that returns the default
\* record, or the number 0, writes a version, and GetAsync answers that
\* value with key info [D6, D17]. Env reads a version that holds z as a
\* removed key, so a protocol whose transform can return z breaks the rule
\* EnvNoZWrite states.
\*
\* One server keeps a counter in one key. It adds 1 with an UpdateAsync,
\* and once it hears "ok" it adds -1 with a second one. The value type is
\* Int. Z is the value the key starts at, and a transform reads Z as 0. An
\* earlier Env took a write of z for a cancel, so with Z = 0 the second
\* call answered "nil" and the key kept 1, while on Roblox the key holds 0
\* with an UpdatedTime.
\*
\* TakeLands says the second call, once it answers, answered "ok" and the
\* key holds 0. With Z = 0 the second run writes z, and EnvNoZWrite fails
\* in that state. With Z = 9, which no run of this counter computes, the
\* write lands, and TakeLands and EnvHolds hold.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
ZWrite_typedefs == TRUE

CONSTANTS
    \* @type: Int;
    Z

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Str;
    heard

vars == <<envVars, pc, rq, heard>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* The counter reads Z as 0 and adds the argument.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, (IF v = Z THEN 0 ELSE v) + c.arg)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(Z, 0) /\ pc = "add" /\ rq = 0 /\ heard = "none"

Add ==
    /\ pc = "add"
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ pc' = "adding"
    /\ UNCHANGED heard

Added ==
    /\ pc = "adding"
    /\ \E a \in Heard : Reply(rq, a) /\ pc' = IF a = "ok" THEN "take" ELSE "done"
    /\ UNCHANGED <<rq, heard>>

Take ==
    /\ pc = "take"
    /\ Issue(S, K, -1)
    /\ rq' = NextReq
    /\ pc' = "taking"
    /\ UNCHANGED heard

Taken ==
    /\ pc = "taking"
    /\ \E a \in Heard : Reply(rq, a) /\ heard' = a
    /\ pc' = "done"
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, heard>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, heard>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, heard>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, heard>>
    \/ Add \/ Added \/ Take \/ Taken

TakeLands == heard # "none" => heard = "ok" /\ Cur(K) = 0
=============================================================================
