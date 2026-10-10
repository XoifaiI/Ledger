----------------------------- MODULE CondWrite -----------------------------
\* A correct toy that must hold under Env with every datastore fault on.
\*
\* Two servers each get the same op, id 1, and write it to one key with an
\* UpdateAsync. The value keeps the ids it applied. The transform cancels
\* when the value already holds the id, and otherwise applies the op and
\* adds the id. A server that hears an error sends the op again under the
\* same id. A server that crashes sends it again after it restarts, as a
\* game would. A server that hears "ok" answers that the op applied. On
\* "nil" it reads seen: it answers yes when the value its transform read
\* holds the id, and refused otherwise.
\*
\* AtMostOnce says the op landed at most once, counted over every landing
\* of every call, so a key that later forgets the id cannot hide a second
\* landing, and a call that lands twice counts twice. TrueYes says every
\* server that answered yes was right: the key holds the id now. Ids only
\* join the value, so a cancel that read an older version that held the id
\* is still right. The configs that hold set StaleRun and RunAfterAnswer,
\* so a run may read any older version, and a transform may run again
\* after its call answered an error, even after its write landed [D7,
\* D13]. The main config sets LoseCommit too, so a transform may also run
\* again after its write landed while its server waits [D10]. The check in
\* the transform catches each, since it runs on every run.
\*
\* Three switches make it fail. Dedupe is the fix: with Dedupe FALSE the
\* transform skips the id check, and AtMostOnce must fail. ReadNil is a
\* second fix. Refuses makes the transform cancel every op for another
\* reason, as a key that is full does. With Refuses and ReadNil FALSE the
\* server answers yes on a "nil" that meant refused, and TrueYes must
\* fail. Reverts lets an outside party write version 0 back as a new
\* version [D28]. The key forgets the id, so a retry applies it again and
\* AtMostOnce fails, and an earlier yes is no longer true, so TrueYes
\* fails. That is why D28 is named beside every "at most once for all
\* time".
EXTENDS Env

\* @typeAlias: val = { n: Int, ids: Set(Int) };
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
CondWrite_typedefs == TRUE

CONSTANTS
    \* @type: Bool;
    Dedupe,
    \* @type: Bool;
    ReadNil,
    \* @type: Bool;
    Refuses

VARIABLES
    \* @type: Str -> Str;
    pc,
    \* @type: Str -> Int;
    rq,
    \* @type: Str -> Str;
    told

vars == <<envVars, pc, rq, told>>

K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) ==
    IF Refuses \/ (Dedupe /\ c.arg \in v.ids)
    THEN Cancel(c, v)
    ELSE Write(c, [n |-> v.n + 1, ids |-> v.ids \cup {c.arg}])

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init ==
    /\ EnvInit([n |-> 0, ids |-> {}], 0)
    /\ pc = [s \in Servers |-> "send"]
    /\ rq = [s \in Servers |-> 0]
    /\ told = [s \in Servers |-> "none"]

Send(s) ==
    /\ pc[s] = "send"
    /\ Issue(s, K, 1)
    /\ rq' = [rq EXCEPT ![s] = NextReq]
    /\ pc' = [pc EXCEPT ![s] = "wait"]
    /\ UNCHANGED told

\* @type: (Str, Str) => Str;
Answer(s, a) ==
    IF a = "ok" \/ ~ReadNil \/ 1 \in req[rq[s]].seen.ids THEN "yes" ELSE "refused"

Hear(s) ==
    /\ pc[s] = "wait"
    /\ \E a \in Heard :
          /\ Reply(rq[s], a)
          /\ IF a = "err"
             THEN pc' = [pc EXCEPT ![s] = "send"] /\ UNCHANGED told
             ELSE /\ pc' = [pc EXCEPT ![s] = "done"]
                  /\ told' = [told EXCEPT ![s] = Answer(s, a)]
    /\ UNCHANGED rq

Lost(s) == Crash(s) /\ pc' = [pc EXCEPT ![s] = "down"] /\ UNCHANGED <<rq, told>>
Back(s) == Restart(s) /\ pc' = [pc EXCEPT ![s] = "send"] /\ UNCHANGED <<rq, told>>
LostAll == CrashAll /\ pc' = [s \in Servers |-> IF up[s] THEN "down" ELSE pc[s]] /\ UNCHANGED <<rq, told>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Lost(s) \/ Back(s) \/ Send(s) \/ Hear(s)
    \/ LostAll

\* Every version an UpdateAsync made, over every landing of every call.
Landings == UNION {req[r].made : r \in {q \in DOMAIN req : req[q].kind = "upd"}}

AtMostOnce == Cardinality(Landings) <= 1
TrueYes == \A s \in Servers : told[s] = "yes" => 1 \in Cur(K).ids
=============================================================================
