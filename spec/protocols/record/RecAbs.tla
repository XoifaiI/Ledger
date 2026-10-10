-------------------------------- MODULE RecAbs --------------------------------
\* RecAbs is the record's dedupe at the level of landings, for the proof
\* of S5 (at most once) from record 9's writer invariant I1 and horizon
\* invariant I2, as TxAbs is the transaction's. Each action is one write
\* that lands on the key, so stale runs, reruns, late landings and retries
\* from any server are interleavings; Rec.tla runs the same rules as
\* requests under every Env fault.
\*
\* Minted ops: writer w's ops are numbered 1..N. Its server's ack passes
\* an op only once the op is settled: it took, or it is forgotten for good
\* (its stamp at or below h, which never falls, and no restamp once acked).
\* An op answered Unresolved stays in the writer and is sent again (record
\* 5.1), so ack does not pass it. A request carries the ops above the ack
\* when it left, which is at most the ack now, in number order; any number
\* of requests from any time may land. A run judges them in order (record
\* 4): rule 1, decided before (at or below the entry's lo); rule 4,
\* forgotten (no entry and its stamp at or below h), which stops the run
\* (the prefix rule); rule 9, took. It lands when something took, and step
\* 5 leaves lo at the last op that took and t at the largest stamp taken.
\* An entry is made only by rule 9 (step 5).
\*
\* Timed names: rule 2, held in T; rule 3, forgotten (stamp at or below h);
\* rule 9, took, and the name goes into T.
\*
\* Age and fit (steps 7, 8) drop any writer's entry or a name from T at
\* some write, raising h to its t or stamp. A restamp (3.4) gives an op a
\* new stamp only when it is above the ack and never took: that is what
\* the clean rule of 3.3 guarantees, and Rec.tla's RecCtlRestamp shows it
\* is needed.
EXTENDS Integers, FiniteSets

CONSTANTS
    \* @type: Set(Str);
    W,          \* writers
    \* @type: Int;
    N,          \* ops per writer, numbered 1..N
    \* @type: Set(Int);
    Names,      \* timed names
    \* @type: Int;
    MaxSt,      \* stamps are 0..MaxSt
    \* @type: Bool;
    FixRaise,   \* a drop raises h over what it drops (record 4 steps 7, 8)
    \* @type: Bool;
    FixEntry    \* an entry is made only when rule 9 judged a minted op (step 5; cheapest's round 1)

VARIABLES
    \* @type: Str -> { on: Bool, lo: Int, t: Int };
    E,          \* E[w]: w's entry
    \* @type: Set(Int);
    T,          \* the names held
    \* @type: Int;
    h,          \* the horizon
    \* @type: Str -> Int;
    ack,        \* ack[w]: w's server's ack
    \* @type: Str -> (Int -> Int);
    st,         \* st[w][i]: the stamp op i of w carries now
    \* @type: Int -> Int;
    nst,        \* nst[n]: the stamp of name n
    \* @type: Str -> (Int -> Int);
    tk,         \* tk[w][i]: how often op i of w took effect. Ghost.
    \* @type: Int -> Int;
    ntk,        \* ntk[n]: how often name n took effect. Ghost.
    \* @type: Str -> (Int -> Int);
    tst         \* tst[w][i]: the stamp op i of w took with. Ghost.

vars == <<E, T, h, ack, st, nst, tk, ntk, tst>>

Ops == 1..N
Stamps == 0..MaxSt
NoE == [on |-> FALSE, lo |-> 0, t |-> 0]
Max(a, b) == IF a >= b THEN a ELSE b

Init ==
    /\ E = [w \in W |-> NoE]
    /\ T = {}
    /\ h = 0
    /\ ack = [w \in W |-> 0]
    /\ st \in [W -> [Ops -> 1..MaxSt]]
    /\ nst \in [Names -> 1..MaxSt]
    /\ tk = [w \in W |-> [i \in Ops |-> 0]]
    /\ ntk = [n \in Names |-> 0]
    /\ tst = [w \in W |-> [i \in Ops |-> 0]]

\* Rule 1, 4 or 9 for op i of w on entry e.
\* @type: (Str, { on: Bool, lo: Int, t: Int }, Int) => Str;
J(w, e, i) == IF e.on /\ i <= e.lo THEN "before" ELSE IF ~e.on /\ st[w][i] <= h THEN "forgotten" ELSE "took"

\* One op a run takes. A run of a request that carried ops a+1..b judges them in order and lands their
\* effects in one write: before its first op that takes, every op is decided before (at or below lo);
\* from it on, each op takes (the entry now exists, so no stamp is checked, and each number is above
\* lo). So the run is the sequence of these steps for its ops that take, in order, with nothing between;
\* this model lets other steps fall between them too, so it has more behaviours than the runs, and what
\* holds here holds for them. A request's ack is at most its writer's ack now. Op i may take when it is
\* the first op the request carried or every op before it in the request is at or below lo.
Land(w, a, i) ==
    LET e == E[w] IN
    /\ a <= ack[w] /\ a < i /\ i <= N
    /\ i = a + 1 \/ (e.on /\ i - 1 <= e.lo)
    /\ J(w, e, i) = "took"
    /\ E' = [E EXCEPT ![w] = [on |-> TRUE, lo |-> i, t |-> Max(IF e.on THEN e.t ELSE 0, st[w][i])]]
    /\ tk' = [tk EXCEPT ![w][i] = tk[w][i] + 1]
    /\ tst' = [tst EXCEPT ![w][i] = st[w][i]]
    /\ UNCHANGED <<T, h, ack, st, nst, ntk>>

\* Cheapest's round 1: an entry made by a run whose minted ops met rule 4 (none took), with lo the last
\* number that run decided, which may be below ops of w that took before a drop (its section 5).
Flaw(w, lo) ==
    /\ ~FixEntry /\ ~E[w].on
    /\ E' = [E EXCEPT ![w] = [on |-> TRUE, lo |-> lo, t |-> h]]
    /\ UNCHANGED <<T, h, ack, st, nst, tk, ntk, tst>>

\* The server hears the fate of op ack+1: it took, or it is forgotten for good.
Ack(w) ==
    /\ ack[w] < N
    /\ tk[w][ack[w] + 1] >= 1 \/ st[w][ack[w] + 1] <= h
    /\ ack' = [ack EXCEPT ![w] = @ + 1]
    /\ UNCHANGED <<E, T, h, st, nst, tk, ntk, tst>>

\* A timed name: held (rule 2) or forgotten (rule 3) changes nothing; else it took.
Name(n) ==
    /\ n \notin T /\ nst[n] > h
    /\ T' = T \cup {n}
    /\ ntk' = [ntk EXCEPT ![n] = @ + 1]
    /\ UNCHANGED <<E, h, ack, st, nst, tk, tst>>

\* Age and fit: an entry or a name goes, and h rises to what it dropped.
DropE(w) ==
    /\ E[w].on
    /\ E' = [E EXCEPT ![w] = NoE]
    /\ h' = IF FixRaise THEN Max(h, E[w].t) ELSE h
    /\ UNCHANGED <<T, ack, st, nst, tk, ntk, tst>>
DropN(n) ==
    /\ n \in T
    /\ T' = T \ {n}
    /\ h' = IF FixRaise THEN Max(h, nst[n]) ELSE h
    /\ UNCHANGED <<E, ack, st, nst, tk, ntk, tst>>

\* A restamp (3.4): an op above the ack that never took gets a new stamp.
Restamp(w, i, s) ==
    /\ i > ack[w] /\ tk[w][i] = 0
    /\ st' = [st EXCEPT ![w][i] = s]
    /\ UNCHANGED <<E, T, h, ack, nst, tk, ntk, tst>>

Next ==
    \/ \E w \in W, a \in 0..N, i \in 1..N : Land(w, a, i)
    \/ \E w \in W, lo \in 0..N : Flaw(w, lo)
    \/ \E w \in W : Ack(w) \/ DropE(w)
    \/ \E n \in Names : Name(n) \/ DropN(n)
    \/ \E w \in W, i \in Ops, s \in Stamps : Restamp(w, i, s)

Spec == Init /\ [][Next]_vars

\* S5, and the invariants of record 9.

AtMostOnce == /\ \A w \in W, i \in Ops : tk[w][i] <= 1
              /\ \A n \in Names : ntk[n] <= 1

\* I1, the writer invariant: an entry's lo covers every op of its writer that took, and its t every
\* stamp they took with; with no entry, every op that took has its stamp at or below h.
I1 == \A w \in W, i \in Ops :
        tk[w][i] >= 1 => IF E[w].on THEN i <= E[w].lo /\ tst[w][i] <= E[w].t ELSE tst[w][i] <= h
\* A taken op keeps the stamp it took with.
Kept == \A w \in W, i \in Ops : tk[w][i] >= 1 => st[w][i] = tst[w][i]
\* Every op at or below the ack is settled: it took, or its stamp is at or below h.
Settled == \A w \in W, i \in Ops : i <= ack[w] => tk[w][i] >= 1 \/ st[w][i] <= h
\* Below an op that took, and below an entry's lo, every op took or is at or below the ack (a run
\* decides a prefix, and carries every op above the ack).
Prefix == \A w \in W, j \in Ops :
    (tk[w][j] >= 1 \/ (E[w].on /\ j <= E[w].lo)) => \A i \in Ops : i <= j => tk[w][i] >= 1 \/ i <= ack[w]
\* I2, the horizon invariant for names: a name that took is held, or its stamp is at or below h.
I2 == \A n \in Names : ntk[n] >= 1 => n \in T \/ nst[n] <= h
\* A name held took.
Held == \A n \in T : ntk[n] = 1

TypeOK ==
    /\ E \in [W -> [on : BOOLEAN, lo : 0..N, t : 0..MaxSt]]
    /\ T \in SUBSET Names
    /\ h \in 0..MaxSt
    /\ ack \in [W -> 0..N]
    /\ st \in [W -> [Ops -> Stamps]]
    /\ nst \in [Names -> 1..MaxSt]
    /\ tk \in [W -> [Ops -> 0..1]]
    /\ ntk \in [Names -> 0..1]
    /\ tst \in [W -> [Ops -> Stamps]]

IndInv == TypeOK /\ AtMostOnce /\ I1 /\ Kept /\ Settled /\ Prefix /\ I2 /\ Held
=============================================================================
