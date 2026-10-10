------------------------------ MODULE MCCopyBuilds ------------------------------
\* Holder X on the old build (level 0), clock one tick fast; Y on the new (level 1), one slow.
EXTENDS CopyBuilds
SkewDef == [h \in Holders |-> IF h = "X" THEN 1 ELSE -1]
LvlDef == [h \in Holders |-> IF h = "X" THEN 0 ELSE 1]
=============================================================================
