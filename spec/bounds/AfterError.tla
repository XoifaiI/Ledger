----------------------------- MODULE AfterError -----------------------------
\* AfterError backs bounds T03 and T04 on Env. It is not a design. It
\* shows what a server can know about a write it sent once the answer is
\* an error.
\*
\* One server sends op x to key K with an UpdateAsync. The transform
\* writes x when the key holds no x and no fence, and cancels otherwise.
\* When the answer is "ok" the server says yes. When it is an error, the
\* server's view is the same whatever happened to the write [D12]. Mode
\* says what the server does next before it answers:
\*   "none"     it answers a definite no at once. This is Busy after send.
\*   "unran"    it answers no at once when its transform never ran, as tf
\*              tells it, and "unknown" otherwise.
\*   "read"     it reads K with GetAsync and answers no if x is absent. A
\*              read that answers an error leaves the answer unknown.
\*   "probe"    it sends an UpdateAsync that always cancels, and answers
\*              no if the value the probe read has no x.
\*   "fence"    it sends an UpdateAsync that writes a fence when K holds
\*              no x, and cancels when K holds x or a fence. It answers no
\*              only on "ok", or on "nil" over a fence. On an error it
\*              sends the fence again.
\*   "unheard"  as "fence", but it answers no when the fence answers an
\*              error, without hearing it land.
\*
\* The value of K is 0 when K holds nothing, 1 when x took effect, and 2
\* when the fence stands. TrueNo says a no is true: x never takes effect,
\* now or later. It is checked in every state, so a write that lands after
\* the no breaks it. TrueYes says a yes is true. No config can break it:
\* only x's write puts 1 on K, a revert writes back a value K held, and
\* Took looks at every version K ever held, so any 1 that an "ok", a read
\* or a cancel shows is a version x's write made.
\*
\* A server's answer is a function of its view: its own variables and what
\* the platform told it. Behind one error Env keeps these outcomes: the
\* write never took effect [D11], it took effect [D10], it ran and may
\* still land at any later step [D13, D14], or, under RunAfterAnswer, its
\* transform has not run yet and may still run and land [D13]. The
\* configs show which steps after the error make a no true under every one
\* of them.
\*
\* Env's rule is that a safety check sets RunAfterAnswer TRUE or names the
\* assumption it makes instead. Every config here sets it TRUE, except
\* AfterErrorUnranBefore, which names the assumption: it shows that "no
\* effect" read from tf = "none" is true only while a transform never runs
\* after its call answered. AfterErrorNoneBefore sets it TRUE and turns
\* LateLand off. RunAfterAnswer alone lets a transform run after its
\* answer, and Env lets the write of that run land only under LateLand.
\* With LoseAnswer off as well, an error there can only mean no effect.
\*
\* WHAT IT LEAVES OUT
\*
\* Other servers and other keys: one server and one key are enough for
\* the fork. Retries of x itself: a retry is a fresh read [D15] and cannot
\* change what the first request may still do. MemoryStore, time and
\* skew, which none of these steps use: MaxMsReqs and MaxTime are 0, and
\* LagAfterCalm and DelayAfterCalm are MaxTime + 1, so they bound nothing.
\* Next passes FALSE as Env's Hold, as a safety check does, and every
\* config sets ClockSteps FALSE and SkewAfterCalm 0, which change nothing
\* at MaxSkew 0. Shutdowns is FALSE, since with one server a shutdown is a
\* crash. Every config sets LoseCommit TRUE, as Env asks of a safety
\* check, except AfterErrorNoneBefore. Under LoseCommit a rerun after the
\* landing sets the call's phase to "cancel", and FailBefore may then
\* answer an error after the write landed, so that config turns it off
\* with LoseAnswer and LateLand. AfterErrorNoneBeforeCommit turns it on
\* with 2 faults and shows the no false. A GetAsync is a call, so it
\* counts in MaxReqs.
\* Each config states its faults and its bounds on calls and faults.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
AfterError_typedefs == TRUE

CONSTANT
    \* @type: Str;
    Mode

ASSUME Mode \in {"none", "unran", "read", "probe", "fence", "unheard"}

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Str;
    told

vars == <<envVars, pc, rq, told>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* Argument 1 writes x and argument 2 writes the fence, each only on a key that
\* holds neither. Argument 3 is the probe, which always cancels. A cancel hands
\* back the value it read, so a "nil" tells the server that value in res.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == IF c.arg = 3 \/ v # 0 THEN Cancel(c, v) ELSE Write(c, c.arg)

\* No MemoryStore call is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "send" /\ rq = 0 /\ told = "none"

Send ==
    /\ pc = "send"
    /\ Issue(S, K, 1)
    /\ rq' = NextReq
    /\ pc' = "wait"
    /\ UNCHANGED told

Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ IF a = "err"
             THEN pc' = "after" /\ UNCHANGED told
             ELSE pc' = "done" /\ told' = IF a = "ok" THEN "yes" ELSE "unknown"
    /\ UNCHANGED rq

\* Busy after send: a definite no with nothing more sent.
Decide ==
    /\ pc = "after"
    /\ Mode = "none"
    /\ pc' = "done"
    /\ told' = "no"
    /\ UNCHANGED <<envVars, rq>>

\* A no read from tf: the transform never ran, so the server takes the error for no effect.
Unran ==
    /\ pc = "after"
    /\ Mode = "unran"
    /\ pc' = "done"
    /\ told' = IF req[rq].tf = "none" THEN "no" ELSE "unknown"
    /\ UNCHANGED <<envVars, rq>>

Read ==
    /\ pc = "after"
    /\ Mode = "read"
    /\ IssueGet(S, K, 0)
    /\ rq' = NextReq
    /\ pc' = "reading"
    /\ UNCHANGED told

\* The GetAsync answers. ReadOf hands the server the value it read.
Seen ==
    /\ pc = "reading"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ told' = IF a # "ok" THEN "unknown" ELSE IF ReadOf(rq).v = 1 THEN "yes" ELSE "no"
    /\ pc' = "done"
    /\ UNCHANGED rq

Ask ==
    /\ pc = "after"
    /\ Mode \in {"probe", "fence", "unheard"}
    /\ Issue(S, K, IF Mode = "probe" THEN 3 ELSE 2)
    /\ rq' = NextReq
    /\ pc' = "check"
    /\ UNCHANGED told

\* A "nil" hands the server the value its transform read, in res.
Check ==
    /\ pc = "check"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ CASE a = "ok"  -> pc' = "done" /\ told' = "no"
               [] a = "nil" -> pc' = "done" /\ told' = IF req[rq].res = 1 THEN "yes" ELSE "no"
               [] a = "err" -> IF Mode = "unheard"
                               THEN pc' = "done" /\ told' = "no"
                               ELSE pc' = "after" /\ UNCHANGED told
    /\ UNCHANGED rq

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, told>>
    \/ \E s \in Servers : Crash(s) /\ pc' = "down" /\ UNCHANGED <<rq, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, rq, told>>
    \/ Send \/ Hear \/ Decide \/ Unran \/ Read \/ Seen \/ Ask \/ Check

\* x took effect at some version of K.
Took == \E i \in Vers(K) : hist[K][i] = 1

TrueNo == told = "no" => ~Took
TrueYes == told = "yes" => Took
=============================================================================
