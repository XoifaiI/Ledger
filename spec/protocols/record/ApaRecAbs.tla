------------------------------ MODULE ApaRecAbs -------------------------------
\* RecAbs for Apalache: constants given by ConstInit. IndInit is IndInv
\* over every value of each variable's type, so one step from it covers
\* every state of the instance that satisfies IndInv, and S5 (AtMostOnce)
\* holds in each: record 9's I1 and I2 are inductive. Each Ctl* is
\* ConstInit with one rule off; its induction step must fail.
EXTENDS RecAbs

Base == W = {"a", "b"} /\ N = 2 /\ Names = {1, 2} /\ MaxSt = 3
Big == W = {"a", "b", "c"} /\ N = 3 /\ Names = {1, 2} /\ MaxSt = 4

ConstInit == Base /\ FixRaise = TRUE /\ FixEntry = TRUE
ConstBig == Big /\ FixRaise = TRUE /\ FixEntry = TRUE
CtlRaise == Base /\ FixRaise = FALSE /\ FixEntry = TRUE
CtlEntry == Base /\ FixRaise = TRUE /\ FixEntry = FALSE

IndInit == IndInv
=============================================================================
