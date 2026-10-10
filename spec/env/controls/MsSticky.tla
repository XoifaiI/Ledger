------------------------------ MODULE MsSticky ------------------------------
\* A toy that must fail under Env when a MemoryStore transform keeps a
\* value across its runs without a reset. Taking a lease is set an upvalue
\* if absent, return nil if held, and that upvalue is wrong on the second
\* run without the reset [M10].
\*
\* Two servers each try to take one MemoryStore key with an UpdateAsync
\* whose expiry is Ttl. The transform writes an item that names its server
\* when no live item is there, and cancels when one is. It keeps a flag,
\* mine, in its note. The server reads the flag once the call answers "ok"
\* or "nil", and answers mine when it is set. Reset is the fix: each run
\* starts the flag at FALSE. Without Reset a run starts from what the last
\* run left.
\*
\* TrueMine says a server that answered mine is the one the item names.
\* Without Reset it fails: server 1's first run sets the flag, server 2's
\* write applies first, and server 1's second run cancels with the flag
\* still set [M10]. No fault is needed. With Reset it holds. The item
\* lives longer than the model's time.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Bool;
\* @typeAlias: item = Str;
MsSticky_typedefs == TRUE

CONSTANTS
    \* @type: Bool;
    Reset,
    \* @type: Int;
    Ttl

VARIABLES
    \* @type: Str -> Str;
    pc,
    \* @type: Str -> Int;
    mq,
    \* @type: Str -> Str;
    told

vars == <<envVars, pc, mq, told>>

M == CHOOSE m \in MKeys : TRUE

\* No datastore call is made.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Cancel(c, v)

\* The note is the flag mine. The argument is its value before any run, FALSE.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) ==
    LET mine == IF Reset THEN ~it.has ELSE c.note \/ ~it.has IN
    IF it.has THEN MsCancelNote(it, mine) ELSE MsWriteNote(c.srv, mine)

Init ==
    /\ EnvInit(0, "none")
    /\ pc = [s \in Servers |-> "send"]
    /\ mq = [s \in Servers |-> 0]
    /\ told = [s \in Servers |-> "none"]

Send(s) ==
    /\ pc[s] = "send"
    /\ MsIssue(s, M, FALSE, Ttl)
    /\ mq' = [mq EXCEPT ![s] = NextMsReq]
    /\ pc' = [pc EXCEPT ![s] = "wait"]
    /\ UNCHANGED told

\* The server reads note, the flag its transform left.
Hear(s) ==
    /\ pc[s] = "wait"
    /\ \E a \in {"ok", "nil"} : MsReply(mq[s], a)
    /\ told' = [told EXCEPT ![s] = IF mreq[mq[s]].note THEN "mine" ELSE "theirs"]
    /\ pc' = [pc EXCEPT ![s] = "done"]
    /\ UNCHANGED mq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, mq, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, mq, told>>
    \/ CrashAll /\ UNCHANGED <<pc, mq, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, mq, told>>
    \/ \E s \in Servers : Send(s) \/ Hear(s)

TrueMine == \A s \in Servers : told[s] = "mine" => MsView(M).has /\ MsView(M).v = s
=============================================================================
