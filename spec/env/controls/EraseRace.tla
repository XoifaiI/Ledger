----------------------------- MODULE EraseRace ------------------------------
\* A toy that shows why no design may erase a key with a conditional write
\* of z. Roblox has no such write: a transform that returns nil cancels,
\* and RemoveAsync is the only removal, which is blind [D6, D18].
\*
\* A writer writes 1 to a key with an UpdateAsync. Once it hears "ok" it
\* writes 2 with a second UpdateAsync. An eraser reads the key with a
\* GetAsync, and when the read shows 1 it erases the key. Mode says how.
\* With "blind" it sends a RemoveAsync. With "cond" it sends an
\* UpdateAsync whose transform writes z when it reads 1 and cancels
\* otherwise. With "tomb" the same transform writes a tombstone, a value
\* that is not z, which Roblox stamps, lists and counts in storage like
\* any other value. On "ok" the eraser says it erased the key.
\*
\* TwoKept says that once the write of 2 answered "ok", the key holds 2.
\* NeverErased says the eraser never says it erased the key. A blind
\* removal lands on whatever version is current, so it can land after the
\* write of 2 and remove it, at no fault, and TwoKept fails. That is the
\* late removal race of D18 and bound T18. z means no value, and no
\* transform may write it, so the conditional erase breaks the rule
\* EnvNoZWrite states, in the state where its run returns z. On Roblox
\* that run writes the value z stands for, a version that is not a
\* removal. The tombstone lands only on the version that holds 1, so it
\* never removes 2: TwoKept holds, and NeverErased fails, since the erase
\* takes effect. The configs turn on FailBefore, LoseAnswer, LoseCommit,
\* LateLand, StaleGet, StaleRun and RunAfterAnswer.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
EraseRace_typedefs == TRUE

CONSTANTS
    \* @type: Str;
    Mode,
    \* @type: Str;
    Wr,
    \* @type: Str;
    Er

VARIABLES
    \* @type: Str;
    wpc,
    \* @type: Int;
    wq,
    \* @type: Str;
    epc,
    \* @type: Int;
    eq,
    \* @type: Str;
    etold

vars == <<envVars, wpc, wq, epc, eq, etold>>

K == CHOOSE k \in Keys : TRUE

\* The erase, argument 9, writes z or a tombstone of -1 when it reads 1, and cancels otherwise.
\* Any other argument writes itself, whatever it reads.
\* @type: ($ctx, $val) => $out;
Tf(c, v) ==
    IF c.arg = 9
    THEN IF v = 1 THEN Write(c, IF Mode = "tomb" THEN -1 ELSE 0) ELSE Cancel(c, v)
    ELSE Write(c, c.arg)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init ==
    /\ EnvInit(0, 0)
    /\ wpc = "one" /\ wq = 0
    /\ epc = "read" /\ eq = 0 /\ etold = "none"

SendOne ==
    /\ wpc = "one"
    /\ Issue(Wr, K, 1)
    /\ wq' = NextReq
    /\ wpc' = "waitOne"
    /\ UNCHANGED <<epc, eq, etold>>

HearOne ==
    /\ wpc = "waitOne"
    /\ \E a \in Heard : Reply(wq, a) /\ wpc' = IF a = "ok" THEN "two" ELSE "stop"
    /\ UNCHANGED <<wq, epc, eq, etold>>

SendTwo ==
    /\ wpc = "two"
    /\ Issue(Wr, K, 2)
    /\ wq' = NextReq
    /\ wpc' = "waitTwo"
    /\ UNCHANGED <<epc, eq, etold>>

HearTwo ==
    /\ wpc = "waitTwo"
    /\ \E a \in Heard : Reply(wq, a) /\ wpc' = IF a = "ok" THEN "done" ELSE "stop"
    /\ UNCHANGED <<wq, epc, eq, etold>>

Look ==
    /\ epc = "read"
    /\ IssueGet(Er, K, 0)
    /\ eq' = NextReq
    /\ epc' = "reading"
    /\ UNCHANGED <<wpc, wq, etold>>

Saw ==
    /\ epc = "reading"
    /\ \E a \in Heard :
          /\ Reply(eq, a)
          /\ epc' = IF a = "ok" /\ ReadOf(eq).v = 1 THEN "erase" ELSE "stop"
    /\ UNCHANGED <<wpc, wq, eq, etold>>

\* A blind erase is a RemoveAsync, which writes z. The others are an UpdateAsync.
Erase ==
    /\ epc = "erase"
    /\ IF Mode = "blind" THEN IssueSet(Er, K, 9, 0) ELSE Issue(Er, K, 9)
    /\ eq' = NextReq
    /\ epc' = "erasing"
    /\ UNCHANGED <<wpc, wq, etold>>

Erased ==
    /\ epc = "erasing"
    /\ \E a \in Heard :
          /\ Reply(eq, a)
          /\ etold' = CASE a = "ok" -> "erased" [] a = "nil" -> "kept" [] OTHER -> "unknown"
    /\ epc' = "done"
    /\ UNCHANGED <<wpc, wq, eq>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<wpc, wq, epc, eq, etold>>
    \/ \E s \in Servers : Crash(s) /\ UNCHANGED <<wpc, wq, epc, eq, etold>>
    \/ CrashAll /\ UNCHANGED <<wpc, wq, epc, eq, etold>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<wpc, wq, epc, eq, etold>>
    \/ SendOne \/ HearOne \/ SendTwo \/ HearTwo \/ Look \/ Saw \/ Erase \/ Erased

TwoKept == wpc = "done" => Cur(K) = 2
NeverErased == etold # "erased"
=============================================================================
