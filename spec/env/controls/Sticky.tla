------------------------------- MODULE Sticky -------------------------------
\* A toy that must fail under Env when a transform keeps a value across
\* its runs without a reset.
\*
\* Two servers each try to create one key with an UpdateAsync. The
\* transform writes its server's name when the key is empty and cancels
\* when it is not. It keeps a flag, made, in its note, as a transform
\* keeps a flag in an upvalue. The server reads the flag once the call
\* answers "ok" or "nil", and answers made when it is set. Reset is the
\* fix: each run starts the flag at FALSE. Without Reset a run starts from
\* what the last run left.
\*
\* TrueMade says a server that answered made is the one whose name the key
\* holds. Without Reset it fails: server 1's first run sets the flag,
\* server 2 lands first, and server 1's second run cancels with the flag
\* still set [D3]. No fault is needed. With Reset it holds.
EXTENDS Env

\* @typeAlias: val = Str;
\* @typeAlias: arg = Bool;
\* @typeAlias: item = Int;
Sticky_typedefs == TRUE

CONSTANT
    \* @type: Bool;
    Reset

VARIABLES
    \* @type: Str -> Str;
    pc,
    \* @type: Str -> Int;
    rq,
    \* @type: Str -> Str;
    told

vars == <<envVars, pc, rq, told>>

K == CHOOSE k \in Keys : TRUE

\* The note is the flag made. The argument is its value before any run, FALSE.
\* @type: ($ctx, $val) => $out;
Tf(c, v) ==
    LET made == IF Reset THEN v = "none" ELSE c.note \/ v = "none" IN
    IF v = "none" THEN WriteNote(c.srv, made) ELSE CancelNote(v, made)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init ==
    /\ EnvInit("none", 0)
    /\ pc = [s \in Servers |-> "send"]
    /\ rq = [s \in Servers |-> 0]
    /\ told = [s \in Servers |-> "none"]

Send(s) ==
    /\ pc[s] = "send"
    /\ Issue(s, K, FALSE)
    /\ rq' = [rq EXCEPT ![s] = NextReq]
    /\ pc' = [pc EXCEPT ![s] = "wait"]
    /\ UNCHANGED told

Hear(s) ==
    /\ pc[s] = "wait"
    /\ \E a \in {"ok", "nil"} : Reply(rq[s], a)
    /\ told' = [told EXCEPT ![s] = IF req[rq[s]].note THEN "made" ELSE "found"]
    /\ pc' = [pc EXCEPT ![s] = "done"]
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, told>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Send(s) \/ Hear(s)

TrueMade == \A s \in Servers : told[s] = "made" => Cur(K) = s
=============================================================================
