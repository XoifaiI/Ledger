------------------------------ MODULE MCTxBuild ------------------------------
\* The constants of TxBuild for TLC. Three builds: old declares no
\* migration, mid the breaking one, new both. u1 is old's transfer of 1
\* from k1 to k2, decided on k2; u2 is new's transfer of 1 from k2 to k1,
\* decided on k1; u3 is mid's transfer of 1 from k1 to k2 decided on k1,
\* the sender. So a newer build's Tent or Commit migrates a key an older
\* build's use has a mark on, or is blocked by it, and old meets the floor
\* a newer build raised. Every build may edit each key twice; new may set
\* y.
EXTENDS TxBuild

MCK == {"k1", "k2"}
MCB == {"old", "mid", "new"}
MCMc == [b \in MCB |-> CASE b = "old" -> 0 [] b = "mid" -> 1 [] b = "new" -> 2]
MCU == {"u1", "u2", "u3"}
MCBu == [u \in MCU |-> CASE u = "u1" -> "old" [] u = "u2" -> "new" [] u = "u3" -> "mid"]
MCAmt == [u \in MCU |-> [k \in MCK |->
            IF u = "u2" THEN (IF k = "k1" THEN 1 ELSE -1) ELSE (IF k = "k1" THEN -1 ELSE 1)]]
MCD == [u \in MCU |-> IF u = "u1" THEN "k2" ELSE "k1"]
MCStart == [k \in MCK |-> 2]
=============================================================================
