----------------------------- MODULE SharedNote -----------------------------
\* A toy that must fail under Env when the tries of one write share a
\* transform closure. A retry that passes the same Luau function to every
\* try makes every try read and set the same upvalues. A caller may keep a
\* flag that says the transform wrote in one of them, and expect it to
\* agree with the answer.
\*
\* One server writes op 1 to one key with an UpdateAsync. The transform
\* writes the op when the key does not hold it and notes that it wrote. It
\* cancels when the key holds the op and notes that it did not write. On
\* an error the server sends the op again, while it has calls left. With
\* Shared TRUE the retry uses IssueAgain, so it shares the closure of the
\* first try. With Shared FALSE it uses Issue, so it has a closure of its
\* own, which is the fix. On "ok" the server reads the note. A note that
\* says no write, beside an "ok", is that disagreement.
\*
\* Agrees says the server never reads a note that says no write after an
\* "ok". With Shared and RunAfterAnswer, the first try runs again after
\* the second landed, reads the op there, cancels, and leaves "no write"
\* in the shared note before the server hears the "ok" [D3, D13]. So it
\* fails. With a closure per try the second try's note is its own, and it
\* holds. With RunAfterAnswer off no run follows the error, and it holds
\* as well.
EXTENDS Env

\* @typeAlias: val = Set(Int);
\* @typeAlias: arg = Bool;
\* @typeAlias: item = Int;
SharedNote_typedefs == TRUE

CONSTANT
    \* @type: Bool;
    Shared

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    first,
    \* @type: Int;
    rq,
    \* @type: Str;
    told

vars == <<envVars, pc, first, rq, told>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* The note says whether the last run wrote. The argument is its value before any run, FALSE.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == IF 1 \in v THEN CancelNote(v, FALSE) ELSE WriteNote(v \cup {1}, TRUE)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit({}, 0) /\ pc = "send" /\ first = 0 /\ rq = 0 /\ told = "none"

Send ==
    /\ pc = "send"
    /\ Issue(S, K, FALSE)
    /\ first' = NextReq
    /\ rq' = NextReq
    /\ pc' = "wait"
    /\ UNCHANGED told

\* On "ok" the server reads the note of the call's closure.
Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard :
          /\ Reply(rq, a)
          /\ CASE a = "ok"  -> pc' = "done" /\ told' = IF NoteOf(rq) THEN "wrote" ELSE "disagrees"
               [] a = "nil" -> pc' = "done" /\ told' = "held"
               [] OTHER     -> pc' = "retry" /\ UNCHANGED told
    /\ UNCHANGED <<first, rq>>

Retry ==
    /\ pc = "retry"
    /\ IF Shared THEN IssueAgain(S, first, FALSE) ELSE Issue(S, K, FALSE)
    /\ rq' = NextReq
    /\ pc' = "wait"
    /\ UNCHANGED <<first, told>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, first, rq, told>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<pc, first, rq, told>>
    \/ CrashAll /\ UNCHANGED <<pc, first, rq, told>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<pc, first, rq, told>>
    \/ Send \/ Hear \/ Retry

Agrees == told # "disagrees"
=============================================================================
