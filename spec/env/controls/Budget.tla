------------------------------- MODULE Budget -------------------------------
\* A toy that decides Busy from its request budget, as a design may choose
\* a path from GetRequestBudgetForRequestType [D22, D23].
\*
\* One server tries an op at most once in each tick. A try reads
\* Budget(s, "read") and Budget(s, "write"). If each is at least Need, it
\* sends an UpdateAsync, which spends one read and one write, and waits
\* for its answer. If not, it answers Busy before any call leaves, as
\* design rule 4 allows. The guard that allows one try in each tick reads
\* now. It only stages the scenario, and no design reads now. The ghost
\* busyCalm records a Busy answered once calm, and it reads calm as a
\* ghost only.
\*
\* NeverBusy says no try answers Busy. It fails with Budgets TRUE, since a
\* budget may read low, and it holds with Budgets FALSE, where every
\* budget reads MaxBudget for ever. So a check with Budgets FALSE never
\* runs a path that a low budget chooses. NoBusyCalm says no try answers
\* Busy once calm. It fails with BudgetAfterCalm 0, since a budget may
\* read 0 for ever after calm. It holds when BudgetAfterCalm is at least
\* Need, since Heal and each tick refill every budget to the floor and the
\* toy spends one of each in a tick.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
Budget_typedefs == TRUE

CONSTANT
    \* @type: Int;
    Need

VARIABLES
    \* @type: Str;
    pc,
    \* @type: Int;
    rq,
    \* @type: Int;
    tried,
    \* @type: Int;
    busy,
    \* @type: Bool;
    busyCalm

vars == <<envVars, pc, rq, tried, busy, busyCalm>>

S == CHOOSE s \in Servers : TRUE
K == CHOOSE k \in Keys : TRUE

\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, v + 1)

\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

Init == EnvInit(0, 0) /\ pc = "try" /\ rq = 0 /\ tried = -1 /\ busy = 0 /\ busyCalm = FALSE

Affords == Budget(S, "read") >= Need /\ Budget(S, "write") >= Need

\* A try sends the op when the budget affords it.
Send ==
    /\ pc = "try"
    /\ tried < now
    /\ Affords
    /\ Issue(S, K, 0)
    /\ rq' = NextReq
    /\ tried' = now
    /\ pc' = "wait"
    /\ UNCHANGED <<busy, busyCalm>>

\* A try answers Busy before any call leaves when the budget does not afford it.
Busy ==
    /\ pc = "try"
    /\ tried < now
    /\ up[S]
    /\ ~Affords
    /\ tried' = now
    /\ busy' = busy + 1
    /\ busyCalm' = (busyCalm \/ calm)
    /\ UNCHANGED <<envVars, pc, rq>>

Hear ==
    /\ pc = "wait"
    /\ \E a \in Heard : Reply(rq, a)
    /\ pc' = "try"
    /\ UNCHANGED <<rq, tried, busy, busyCalm>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<pc, rq, tried, busy, busyCalm>>
    \/ Send \/ Busy \/ Hear

NeverBusy == busy = 0

NoBusyCalm == ~busyCalm
=============================================================================
