---- MODULE CopyBuilds ----
EXTENDS Integers

CONSTANTS
    Holders,
    Lvl,
    MaxW,
    MaxT,
    Skew,
    FixPartLevel,
    FixLevelWins,
    FixLevelTakes

VARIABLES kq, t, hdr, parts, hs, fl, shown, back, unheld

vars == <<kq, t, hdr, parts, hs, fl, shown, back, unheld>>

NoItem == [q |-> -1, at |-> -100, lv |-> -1]
NoPart == [q |-> -1, lv |-> -1]
Slot(q) == q % 2
H0 == [ph |-> "", q |-> -1, j |-> 0]
F0 == [ph |-> "", h |-> NoItem, got |-> <<NoPart, NoPart>>]

Init ==
    /\ kq = 0 /\ t = 0
    /\ hdr = NoItem
    /\ parts = [s \in 0..1 |-> [j \in 0..1 |-> NoPart]]
    /\ hs = [h \in Holders |-> H0]
    /\ fl = F0
    /\ shown = NoItem
    /\ back = FALSE /\ unheld = FALSE

Write == kq < MaxW /\ kq' = kq + 1 /\ UNCHANGED <<t, hdr, parts, hs, fl, shown, back, unheld>>
Tick == t < MaxT /\ t' = t + 1 /\ UNCHANGED <<kq, hdr, parts, hs, fl, shown, back, unheld>>

HRead(h) == /\ hs[h].ph = "" /\ \E q \in 1..kq : hs' = [hs EXCEPT ![h] = [ph |-> "part", q |-> q, j |-> 0]]
            /\ UNCHANGED <<kq, t, hdr, parts, fl, shown, back, unheld>>
HPart(h) == /\ hs[h].ph = "part"
            /\ parts' = [parts EXCEPT ![Slot(hs[h].q)][hs[h].j] = [q |-> hs[h].q, lv |-> Lvl[h]]]
            /\ hs' = [hs EXCEPT ![h] = IF hs[h].j = 1 THEN [@ EXCEPT !.ph = "head"] ELSE [@ EXCEPT !.j = 1]]
            /\ UNCHANGED <<kq, t, hdr, fl, shown, back, unheld>>
HHead(h) == LET new == [q |-> hs[h].q, at |-> t + Skew[h], lv |-> Lvl[h]]
                lv2 == IF FixLevelTakes THEN new.lv
                       ELSE IF FixLevelWins /\ new.lv > hdr.lv THEN new.lv ELSE hdr.lv
            IN /\ hs[h].ph = "head"
               /\ hdr' = IF new.q > hdr.q THEN new
                         ELSE IF new.q = hdr.q THEN [hdr EXCEPT !.at = new.at, !.lv = lv2]
                         ELSE hdr
               /\ hs' = [hs EXCEPT ![h] = H0]
               /\ UNCHANGED <<kq, t, parts, fl, shown, back, unheld>>

FHead == /\ fl.ph = "" /\ hdr.q >= 1 /\ hdr.q > shown.q
         /\ fl' = [F0 EXCEPT !.ph = "p0", !.h = hdr]
         /\ UNCHANGED <<kq, t, hdr, parts, hs, shown, back, unheld>>
FPart0 == /\ fl.ph = "p0" /\ fl' = [fl EXCEPT !.ph = "p1", !.got[1] = parts[Slot(fl.h.q)][0]]
          /\ UNCHANGED <<kq, t, hdr, parts, hs, shown, back, unheld>>
FPart1 == /\ fl.ph = "p1"
          /\ LET got == <<fl.got[1], parts[Slot(fl.h.q)][1]>>
                 h == fl.h
                 sameQ == got[1].q = h.q /\ got[2].q = h.q
                 sameLv == got[1].lv = h.lv /\ got[2].lv = h.lv
             IN /\ fl' = F0
                /\ IF sameQ /\ (sameLv \/ ~FixPartLevel)
                   THEN /\ shown' = h
                        /\ back' = (back \/ h.q < shown.q)
                        /\ unheld' = (unheld \/ ~sameLv)
                   ELSE UNCHANGED <<shown, back, unheld>>
          /\ UNCHANGED <<kq, t, hdr, parts, hs>>

Next == Write \/ Tick \/ FHead \/ FPart0 \/ FPart1
        \/ \E h \in Holders : HRead(h) \/ HPart(h) \/ HHead(h)

Spec == Init /\ [][Next]_vars

ReadWasHeld == ~unheld
NeverBack == ~back
ShownLast == shown.q < MaxW
====
