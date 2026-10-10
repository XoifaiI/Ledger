------------------------------- MODULE MCTxCut -------------------------------
\* The constants of TxCut for TLC. u1 and u3 each move 1 from k0 to d, u2
\* moves 1 from d to k0, all decided on d. Three cuts n1, n2 and n3,
\* stamped 1 to 3, and a cut room of one name, so each later cut drops the
\* one before and raises hk. Two credits may land on k0. Each key starts
\* with 2.
EXTENDS TxCut

MCU == {"u1", "u2", "u3"}
MCAmt == [u \in MCU |-> IF u = "u2" THEN 1 ELSE -1]
MCCuts == {"n1", "n2", "n3"}
MCSt == [n \in MCCuts |-> CASE n = "n1" -> 1 [] n = "n2" -> 2 [] OTHER -> 3]
=============================================================================
