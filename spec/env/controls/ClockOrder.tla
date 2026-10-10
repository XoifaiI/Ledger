----------------------------- MODULE ClockOrder -----------------------------
\* A toy that must fail under Env. It orders two events by comparing the
\* clocks of two servers.
\*
\* Server 1 writes event 1 to a key, stamped with its own clock. Once that
\* call answered and true time has moved on, server 2 writes event 2,
\* stamped with its own clock. The key keeps the event with the larger
\* stamp, so the transform of event 2 cancels when it reads a larger
\* stamp. Event 2 happened after event 1 in true time. SendTwo reads now
\* only to stage that order, and sentAt is a ghost. With AfterCalm TRUE,
\* SendOne waits for calm, which also only stages the scenario.
\*
\* NewestKept says that once event 2 answered, the key holds event 2. With
\* MaxSkew 1, server 1's clock may read one tick ahead and server 2's one
\* tick behind, so event 2 carries the smaller stamp and loses [C1]. With
\* MaxSkew 0 the stamps follow true time and it holds. Once calm each
\* clock reads within SkewAfterCalm of true time. So with both events
\* after calm, it holds under SkewAfterCalm 0 although MaxSkew is 1, and
\* it fails under SkewAfterCalm 1. The two servers are different model
\* values, so the configs name them.
\*
\* With ById TRUE each event is stamped with NextReq, the id its call
\* gets, in place of a clock. That breaks the rule of Env that a server
\* step never puts a call id into an argument. The ids count every call of
\* every server in the order they were sent, so the stamps follow true
\* order and NewestKept holds under MaxSkew 1. Roblox gives no such
\* counter [D17]. Env cannot stop the read, and this control shows what
\* the rule keeps out.
EXTENDS Env

\* @typeAlias: val = { e: Int, t: Int };
\* @typeAlias: arg = { e: Int, t: Int };
\* @typeAlias: item = Int;
ClockOrder_typedefs == TRUE

CONSTANTS
    \* @type: Str;
    First,
    \* @type: Str;
    Second,
    \* @type: Bool;
    AfterCalm,
    \* @type: Bool;
    ById

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Int;
    sentAt

vars == <<envVars, pc, rq, sentAt>>

K == CHOOSE k \in Keys : TRUE

\* The stamp server s gives an event: its clock, or with ById the id of the call, which Env's
\* rule forbids.
\* @type: Str => Int;
Stamp(s) == IF ById THEN NextReq ELSE Clock(s)

\* Keep the event with the larger stamp.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == IF v.e = 0 \/ c.arg.t > v.t THEN Write(c, c.arg) ELSE Cancel(c, v)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit([e |-> 0, t |-> 0], 0) /\ pc = "one" /\ rq = 0 /\ sentAt = 0

\* The guard on calm only stages the scenario.
SendOne ==
    /\ pc = "one"
    /\ AfterCalm => calm
    /\ Issue(First, K, [e |-> 1, t |-> Stamp(First)])
    /\ rq' = NextReq
    /\ sentAt' = now
    /\ pc' = "waitOne"

HearOne ==
    /\ pc = "waitOne"
    /\ Reply(rq, "ok")
    /\ pc' = "two"
    /\ UNCHANGED <<rq, sentAt>>

SendTwo ==
    /\ pc = "two"
    /\ now > sentAt
    /\ Issue(Second, K, [e |-> 2, t |-> Stamp(Second)])
    /\ rq' = NextReq
    /\ pc' = "waitTwo"
    /\ UNCHANGED sentAt

HearTwo ==
    /\ pc = "waitTwo"
    /\ \E a \in {"ok", "nil"} : Reply(rq, a)
    /\ pc' = "done"
    /\ UNCHANGED <<rq, sentAt>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, sentAt>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, rq, sentAt>>
    \/ CrashAll /\ UNCHANGED <<pc, rq, sentAt>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, sentAt>>
    \/ SendOne \/ HearOne \/ SendTwo \/ HearTwo

NewestKept == pc = "done" => Cur(K).e = 2
=============================================================================
