-------------------------------- MODULE CopyAbs --------------------------------
\* CopyAbs is the copies of extras 5 at the level of landings, as TxAbs is
\* the transaction's: each action is one write or one read that lands, so
\* stale reads, slow holders and interleaved refreshes are interleavings.
\* Copy.tla runs the same design on Env with every fault; its controls
\* fail only on paths deeper than its state space lets a search reach, so
\* they are shown here.
\*
\* The key's write count kq only grows; state q is the two pieces
\* <<q, 0>> and <<q, 1>>. A holder reads any q the key held (a GetAsync
\* may be stale, D8), sets the two parts of slot q mod 2 one by one, then
\* updates the header, which keeps the larger q (5.2). A follower reads
\* the header, then each part of its slot, and shows the state only if
\* both parts carry the header's q (5.3), and only a q above the last it
\* showed (the record's shown table). A holder's clock is its own, off
\* true time by Skew[h]; the header records it as at.
EXTENDS Integers

CONSTANTS
    Holders,    \* the servers that refresh
    MaxW,       \* writes of the key
    MaxT,       \* ticks of true time
    Skew,       \* Skew[h]: holder h's clock minus true time
    FixPartQ,   \* show parts only when each carries the header's q
    FixOrderQ   \* the header keeps the larger q and the follower orders by q; else both order by at

VARIABLES kq, t, hdr, parts, hs, fl, shown, back, unheld

vars == <<kq, t, hdr, parts, hs, fl, shown, back, unheld>>

NoItem == [q |-> -1, at |-> -100]
Slot(q) == q % 2
H0 == [ph |-> "", q |-> -1, j |-> 0]
F0 == [ph |-> "", h |-> NoItem, got |-> <<-1, -1>>]

Init ==
    /\ kq = 0 /\ t = 0
    /\ hdr = NoItem
    /\ parts = [s \in 0..1 |-> [j \in 0..1 |-> -1]]
    /\ hs = [h \in Holders |-> H0]
    /\ fl = F0
    /\ shown = NoItem
    /\ back = FALSE /\ unheld = FALSE

Write == kq < MaxW /\ kq' = kq + 1 /\ UNCHANGED <<t, hdr, parts, hs, fl, shown, back, unheld>>
Tick == t < MaxT /\ t' = t + 1 /\ UNCHANGED <<kq, hdr, parts, hs, fl, shown, back, unheld>>

\* A refresh: read any state the key held, set its slot's parts, then the header.
HRead(h) == /\ hs[h].ph = "" /\ \E q \in 1..kq : hs' = [hs EXCEPT ![h] = [ph |-> "part", q |-> q, j |-> 0]]
            /\ UNCHANGED <<kq, t, hdr, parts, fl, shown, back, unheld>>
HPart(h) == /\ hs[h].ph = "part"
            /\ parts' = [parts EXCEPT ![Slot(hs[h].q)][hs[h].j] = hs[h].q]
            /\ hs' = [hs EXCEPT ![h] = IF hs[h].j = 1 THEN [@ EXCEPT !.ph = "head"] ELSE [@ EXCEPT !.j = 1]]
            /\ UNCHANGED <<kq, t, hdr, fl, shown, back, unheld>>
HHead(h) == LET new == [q |-> hs[h].q, at |-> t + Skew[h]]
                take == IF FixOrderQ THEN new.q > hdr.q ELSE new.at > hdr.at
            IN /\ hs[h].ph = "head"
               /\ hdr' = IF take THEN new ELSE hdr
               /\ hs' = [hs EXCEPT ![h] = H0]
               /\ UNCHANGED <<kq, t, parts, fl, shown, back, unheld>>

\* A follower's tick: the header, then part 0 and part 1 of its slot, then show or not.
Newer(h) == IF FixOrderQ THEN h.q > shown.q ELSE h.at > shown.at
FHead == /\ fl.ph = "" /\ hdr.q >= 1 /\ Newer(hdr)
         /\ fl' = [F0 EXCEPT !.ph = "p0", !.h = hdr]
         /\ UNCHANGED <<kq, t, hdr, parts, hs, shown, back, unheld>>
FPart0 == /\ fl.ph = "p0" /\ fl' = [fl EXCEPT !.ph = "p1", !.got[1] = parts[Slot(fl.h.q)][0]]
          /\ UNCHANGED <<kq, t, hdr, parts, hs, shown, back, unheld>>
FPart1 == /\ fl.ph = "p1"
          /\ LET got == <<fl.got[1], parts[Slot(fl.h.q)][1]>>
                 ok == ~FixPartQ \/ (got[1] = fl.h.q /\ got[2] = fl.h.q)
             IN /\ fl' = F0
                /\ IF ok /\ got[1] >= 1 /\ got[2] >= 1
                   THEN /\ shown' = fl.h
                        /\ back' = (back \/ fl.h.q < shown.q)
                        \* The shown state is pieces <<got[1], 0>> and <<got[2], 1>>: one state only if equal.
                        /\ unheld' = (unheld \/ got[1] # got[2])
                   ELSE UNCHANGED <<shown, back, unheld>>
          /\ UNCHANGED <<kq, t, hdr, parts, hs>>

Next == Write \/ Tick \/ FHead \/ FPart0 \/ FPart1
        \/ \E h \in Holders : HRead(h) \/ HPart(h) \/ HHead(h)

Spec == Init /\ [][Next]_vars

ReadWasHeld == ~unheld
NeverBack == ~back
\* Probe: the follower shows the last state.
ShownLast == shown.q < MaxW
=============================================================================
