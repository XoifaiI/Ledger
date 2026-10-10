------------------------------- MODULE MCCopyAbs -------------------------------
\* CopyAbs with two holders whose clocks run one tick fast and one tick slow.
EXTENDS CopyAbs
SkewDef == [h \in Holders |-> IF h = "X" THEN 1 ELSE -1]
=============================================================================
