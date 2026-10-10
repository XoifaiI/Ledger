---------------------------- MODULE MCCopyBuildsLive ----------------------------
\* As MCCopyBuilds: X on the old build (level 0), clock one fast; Y on the new (level 1), one slow.
EXTENDS CopyBuildsLive
SkewDef == [h \in Holders |-> IF h = "X" THEN 1 ELSE -1]
LvlDef == [h \in Holders |-> IF h = "X" THEN 0 ELSE 1]
=============================================================================
