------------------------------- MODULE ApaTxAbs -------------------------------
\* TxAbs for Apalache: the constants of MCTxAbs given by ConstInit, since
\* Apalache takes constants from an operator and not from a config.
\* Checked as the proof plan says: IndInit is IndInv over every value of
\* each variable's type, with unbounded integers, so one step from it
\* covers every state of this size that satisfies IndInv.
\*
\* ConstInit is the design on MCTxAbs's constants. ConstBig is the design
\* on three keys and three attempts, with a three-leg use and amounts
\* above 1. Each Ctl* is ConstInit with one guard off (TxAbs's Off), and
\* its induction step must fail: the proof needs that guard.
EXTENDS TxAbs

Base ==
    /\ K = {"k1", "k2"}
    /\ U = {"u1", "u2", "u3"}
    /\ MaxA = 2
    /\ Amt = [u \in {"u1", "u2", "u3"} |->
                IF u = "u2" THEN [k \in {"k1", "k2"} |-> IF k = "k1" THEN 1 ELSE -1]
                ELSE [k \in {"k1", "k2"} |-> IF k = "k1" THEN -1 ELSE 1]]
    /\ D = [u \in {"u1", "u2", "u3"} |-> IF u = "u1" THEN "k2" ELSE "k1"]
    /\ Start = [k \in {"k1", "k2"} |-> IF k = "k1" THEN 1 ELSE 0]

ConstInit == Base /\ Off = {}
CtlAttempt == Base /\ Off = {"attempt"}
CtlPlaced == Base /\ Off = {"placed"}
CtlLow == Base /\ Off = {"low"}
CtlDrop == Base /\ Off = {"drop"}
CtlFence == Base /\ Off = {"fence"}
CtlGiveUp == Base /\ Off = {"giveup"}
CtlGone == Base /\ Off = {"gone"}

\* u1 moves 2 from k1 to k2 and k3, decided on k3 (a credit). u2 moves 1 from k2 to k1, decided on
\* k1 (a credit). u3 moves 1 from k3 to k1, decided on k3 (a debit), and k3 starts empty, so u3 can
\* only land once u1's credit took.
ConstBig ==
    /\ K = {"k1", "k2", "k3"}
    /\ U = {"u1", "u2", "u3"}
    /\ MaxA = 3
    /\ Amt = [u \in {"u1", "u2", "u3"} |-> [k \in {"k1", "k2", "k3"} |->
                CASE u = "u1" -> (CASE k = "k1" -> -2 [] k = "k2" -> 1 [] OTHER -> 1)
                  [] u = "u2" -> (CASE k = "k1" -> 1 [] k = "k2" -> -1 [] OTHER -> 0)
                  [] OTHER -> (CASE k = "k1" -> 1 [] k = "k2" -> 0 [] OTHER -> -1)]]
    /\ D = [u \in {"u1", "u2", "u3"} |-> IF u = "u2" THEN "k1" ELSE "k3"]
    /\ Start = [k \in {"k1", "k2", "k3"} |-> CASE k = "k1" -> 2 [] k = "k2" -> 1 [] OTHER -> 0]
    /\ Off = {}

IndInit == IndInv
=============================================================================
