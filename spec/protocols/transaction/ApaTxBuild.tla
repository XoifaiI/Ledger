------------------------------ MODULE ApaTxBuild ------------------------------
\* TxBuild for Apalache: MCTxBuild's constants given by ConstInit. IndInit
\* is IndInv over every value of each variable's type, with unbounded
\* integers, so one step from it covers every state of this instance that
\* satisfies IndInv, and S15 (OwnMeaning, NoForeignField) holds in each.
\* Each Ctl* is ConstInit with one rule off; its induction step must fail.
EXTENDS TxBuild

Base ==
    /\ K = {"k1", "k2"}
    /\ Bs = {"old", "mid", "new"}
    /\ Mc = [b \in {"old", "mid", "new"} |-> IF b = "old" THEN 0 ELSE IF b = "mid" THEN 1 ELSE 2]
    /\ U = {"u1", "u2", "u3"}
    /\ Bu = [u \in {"u1", "u2", "u3"} |-> IF u = "u1" THEN "old" ELSE IF u = "u2" THEN "new" ELSE "mid"]
    /\ Amt = [u \in {"u1", "u2", "u3"} |-> [k \in {"k1", "k2"} |->
                IF u = "u2" THEN (IF k = "k1" THEN 1 ELSE -1) ELSE (IF k = "k1" THEN -1 ELSE 1)]]
    /\ D = [u \in {"u1", "u2", "u3"} |-> IF u = "u1" THEN "k2" ELSE "k1"]
    /\ Start = [k \in {"k1", "k2"} |-> 2]
    /\ MaxEd = 2

ConstInit == Base /\ FixFloor = TRUE /\ FixMigBlock = TRUE /\ FixCarry = TRUE
CtlFloor == Base /\ FixFloor = FALSE /\ FixMigBlock = TRUE /\ FixCarry = TRUE
CtlMigBlock == Base /\ FixFloor = TRUE /\ FixMigBlock = FALSE /\ FixCarry = TRUE
CtlCarry == Base /\ FixFloor = TRUE /\ FixMigBlock = TRUE /\ FixCarry = FALSE

IndInit == IndInv
=============================================================================
