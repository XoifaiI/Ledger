---- MODULE RecAbs ----
EXTENDS Integers, FiniteSets

CONSTANTS
    W,
    N,
    Names,
    MaxSt,
    FixRaise,
    FixEntry

VARIABLES
    E,
    T,
    h,
    ack,
    st,
    nst,
    tk,
    ntk,
    tst

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

J(w, e, i) == IF e.on /\ i <= e.lo THEN "before" ELSE IF ~e.on /\ st[w][i] <= h THEN "forgotten" ELSE "took"

Land(w, a, i) ==
    LET e == E[w] IN
    /\ a <= ack[w] /\ a < i /\ i <= N
    /\ i = a + 1 \/ (e.on /\ i - 1 <= e.lo)
    /\ J(w, e, i) = "took"
    /\ E' = [E EXCEPT ![w] = [on |-> TRUE, lo |-> i, t |-> Max(IF e.on THEN e.t ELSE 0, st[w][i])]]
    /\ tk' = [tk EXCEPT ![w][i] = tk[w][i] + 1]
    /\ tst' = [tst EXCEPT ![w][i] = st[w][i]]
    /\ UNCHANGED <<T, h, ack, st, nst, ntk>>

Flaw(w, lo) ==
    /\ ~FixEntry /\ ~E[w].on
    /\ E' = [E EXCEPT ![w] = [on |-> TRUE, lo |-> lo, t |-> h]]
    /\ UNCHANGED <<T, h, ack, st, nst, tk, ntk, tst>>

Ack(w) ==
    /\ ack[w] < N
    /\ tk[w][ack[w] + 1] >= 1 \/ st[w][ack[w] + 1] <= h
    /\ ack' = [ack EXCEPT ![w] = @ + 1]
    /\ UNCHANGED <<E, T, h, st, nst, tk, ntk, tst>>

Name(n) ==
    /\ n \notin T /\ nst[n] > h
    /\ T' = T \cup {n}
    /\ ntk' = [ntk EXCEPT ![n] = @ + 1]
    /\ UNCHANGED <<E, h, ack, st, nst, tk, tst>>

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

AtMostOnce == /\ \A w \in W, i \in Ops : tk[w][i] <= 1
              /\ \A n \in Names : ntk[n] <= 1

I1 == \A w \in W, i \in Ops :
        tk[w][i] >= 1 => IF E[w].on THEN i <= E[w].lo /\ tst[w][i] <= E[w].t ELSE tst[w][i] <= h
Kept == \A w \in W, i \in Ops : tk[w][i] >= 1 => st[w][i] = tst[w][i]
Settled == \A w \in W, i \in Ops : i <= ack[w] => tk[w][i] >= 1 \/ st[w][i] <= h
Prefix == \A w \in W, j \in Ops :
    (tk[w][j] >= 1 \/ (E[w].on /\ j <= E[w].lo)) => \A i \in Ops : i <= j => tk[w][i] >= 1 \/ i <= ack[w]
I2 == \A n \in Names : ntk[n] >= 1 => n \in T \/ nst[n] <= h
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
====
