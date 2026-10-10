------------------------------- MODULE MCComp ---------------------------------
\* Comp's instance: a debit use from an old build and a credit use from a new one, two cuts that
\* may come from either build, one hopeful op, and two one key edits.
EXTENDS Comp
UDef == {"u1", "u2"}
AmtDef == [u \in UDef |-> IF u = "u1" THEN -1 ELSE 1]
BsDef == {"old", "new"}
McDef == [b \in BsDef |-> IF b = "old" THEN 0 ELSE 2]
BuDef == [u \in UDef |-> IF u = "u1" THEN "old" ELSE "new"]
CutsDef == {"n1", "n2"}
StDef == [n \in CutsDef |-> IF n = "n1" THEN 1 ELSE 2]
HopsDef == {"h1"}
HopsBigDef == {"h1", "h2"}
=============================================================================
