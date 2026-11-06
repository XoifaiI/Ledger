-------------------------------- MODULE MCCopy ---------------------------------
\* Copy with server A homed on replica 0 and server B on replica 1.
EXTENDS Copy
HomeDef == [s \in Servers |-> IF s = "A" THEN 0 ELSE 1]
=============================================================================
