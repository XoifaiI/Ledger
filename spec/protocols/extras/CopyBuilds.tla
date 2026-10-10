------------------------------ MODULE CopyBuilds ------------------------------
\* CopyBuilds is CopyAbs (extras 5, at the level of landings) with holders
\* on two builds, for open question 17. Everything else is CopyAbs's.
\*
\* The key's state of write count q is stored at level 0. A holder on
\* build level Lvl[h] copies its own view: the state migrated in memory to
\* its level (record 5.3, 6). So a part is [q, lv]: piece j of state q
\* migrated to level lv. The header holds q, at, and lv, the level of the
\* copied state (extras 5.1). On an equal q a header update renews only
\* the holder fields (5.2), so it keeps its level, unless FixLevelWins or
\* FixLevelTakes (below) says otherwise. The follower's build is
\* the newest: it migrates what it reads from the header's level up to
\* its own. That shows a state the key held only when every part it joins
\* is at the header's level: a part at another level is migrated again or
\* not at all.
\*
\* A refresh pushes parts every time, as CopyAbs's HRead does. Extras 5.2
\* pushes at an unchanged q only when the header's at is TTL_C / 2 old, so
\* this is a superset of the prose: a fix that holds here holds there.
\*
\* Candidate fixes, each a switch:
\*   FixPartLevel: a part carries its level, and the follower joins parts
\*     only when each carries the header's q and level.
\*   FixLevelWins: on an equal q, a header update of a higher level takes
\*     that level.
\*   FixLevelTakes: on an equal q, a header update takes the carried level
\*     whatever it is: the pushing holder's header is written whole (the
\*     chosen design, extras 5.2). It overrides FixLevelWins.
\*     CopyBuildsLive.tla checks that it is live across builds.
EXTENDS Integers

CONSTANTS
    Holders,      \* the servers that refresh
    Lvl,          \* Lvl[h]: the level of holder h's build
    MaxW,         \* writes of the key
    MaxT,         \* ticks of true time
    Skew,         \* Skew[h]: holder h's clock minus true time
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

\* A refresh: read any state the key held, set its slot's parts at this holder's level, then the header.
HRead(h) == /\ hs[h].ph = "" /\ \E q \in 1..kq : hs' = [hs EXCEPT ![h] = [ph |-> "part", q |-> q, j |-> 0]]
            /\ UNCHANGED <<kq, t, hdr, parts, fl, shown, back, unheld>>
HPart(h) == /\ hs[h].ph = "part"
            /\ parts' = [parts EXCEPT ![Slot(hs[h].q)][hs[h].j] = [q |-> hs[h].q, lv |-> Lvl[h]]]
            /\ hs' = [hs EXCEPT ![h] = IF hs[h].j = 1 THEN [@ EXCEPT !.ph = "head"] ELSE [@ EXCEPT !.j = 1]]
            /\ UNCHANGED <<kq, t, hdr, fl, shown, back, unheld>>
\* 5.2: the header keeps the larger q; on an equal q it renews the holder fields (here at), and the level
\* by FixLevelTakes or FixLevelWins.
HHead(h) == LET new == [q |-> hs[h].q, at |-> t + Skew[h], lv |-> Lvl[h]]
                lv2 == IF FixLevelTakes THEN new.lv
                       ELSE IF FixLevelWins /\ new.lv > hdr.lv THEN new.lv ELSE hdr.lv
            IN /\ hs[h].ph = "head"
               /\ hdr' = IF new.q > hdr.q THEN new
                         ELSE IF new.q = hdr.q THEN [hdr EXCEPT !.at = new.at, !.lv = lv2]
                         ELSE hdr
               /\ hs' = [hs EXCEPT ![h] = H0]
               /\ UNCHANGED <<kq, t, parts, fl, shown, back, unheld>>

\* A follower's tick: the header, then part 0 and part 1 of its slot, then show or not (5.3).
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
                        \* Migrated from the header's level: a state the key held only if every part
                        \* is at that level.
                        /\ unheld' = (unheld \/ ~sameLv)
                   ELSE UNCHANGED <<shown, back, unheld>>
          /\ UNCHANGED <<kq, t, hdr, parts, hs>>

Next == Write \/ Tick \/ FHead \/ FPart0 \/ FPart1
        \/ \E h \in Holders : HRead(h) \/ HPart(h) \/ HHead(h)

Spec == Init /\ [][Next]_vars

\* A7 and A8, as CopyAbs states them.
ReadWasHeld == ~unheld
NeverBack == ~back
\* Probe: the follower shows the last state.
ShownLast == shown.q < MaxW
=============================================================================
