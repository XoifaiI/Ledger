------------------------------- MODULE MCTxAbs -------------------------------
\* The constants of TxAbs for TLC and Apalache: two keys, and uses that
\* each transfer between them. u1 moves 1 from k1 to k2, decided on k2.
\* u2 moves 1 from k2 to k1, decided on k1, so the two cross and each key
\* is a leg key of one and the decider of the other. u3 is u1's terms
\* decided on the sender, so a key holds a debit and a credit mark at
\* once. k1 starts with 1 and k2 with 0, so debits contend.
EXTENDS TxAbs

MCK == {"k1", "k2"}
MCU == {"u1", "u2", "u3"}
MCAmt == [u \in MCU |-> CASE u = "u1" -> [k \in MCK |-> IF k = "k1" THEN -1 ELSE 1]
                          [] u = "u2" -> [k \in MCK |-> IF k = "k1" THEN 1 ELSE -1]
                          [] u = "u3" -> [k \in MCK |-> IF k = "k1" THEN -1 ELSE 1]]
MCD == [u \in MCU |-> CASE u = "u1" -> "k2" [] u = "u2" -> "k1" [] u = "u3" -> "k1"]
MCStart == [k \in MCK |-> IF k = "k1" THEN 1 ELSE 0]
=============================================================================
