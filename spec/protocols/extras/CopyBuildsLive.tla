---------------------------- MODULE CopyBuildsLive ----------------------------
\* CopyBuildsLive is CopyBuilds.tla (extras 5, holders on two builds) for
\* liveness across a deploy. Its actions are CopyBuilds' (FixLevelTakes
\* included), plus:
\*   Deploy: one step after which every holder but Survivor starts no new
\*     refresh (a refresh already under way may still land, or never).
\*     Survivor on the new build is a finished rollout; Survivor on the
\*     old build is an old holder outliving a new one (a mid-rollout
\*     handoff, or a rollback).
\*   Fairness: on a quiet key (writes stop, as MaxW forces), the survivor
\*     refreshes for ever, reading the key's last state infinitely often
\*     (SF), and the follower ticks (WF).
\* Property: ShowsLast, the follower eventually shows the key's last q and
\* stays there (extras 5.3). With FixPartLevel alone, a header set at the
\* last q by the other holder keeps that holder's level, so the follower
\* never joins the survivor's parts; FixLevelWins is live only when the
\* survivor is on the newer build; FixLevelTakes is live both ways. Safety
\* under FixLevelTakes is CopyBuildsFixTakes.cfg on CopyBuilds.tla. No
\* symmetry (liveness).
EXTENDS Integers

CONSTANTS Holders, Lvl, MaxW, MaxT, Skew, FixPartLevel, FixLevelWins, FixLevelTakes, Survivor

VARIABLES kq, t, hdr, parts, hs, fl, shown, back, unheld, gone

vars == <<kq, t, hdr, parts, hs, fl, shown, back, unheld, gone>>

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
    /\ gone = FALSE

Write == kq < MaxW /\ kq' = kq + 1 /\ UNCHANGED <<t, hdr, parts, hs, fl, shown, back, unheld, gone>>
Tick == t < MaxT /\ t' = t + 1 /\ UNCHANGED <<kq, hdr, parts, hs, fl, shown, back, unheld, gone>>
Deploy == ~gone /\ gone' = TRUE /\ UNCHANGED <<kq, t, hdr, parts, hs, fl, shown, back, unheld>>

Starts(h) == h = Survivor \/ ~gone

HReadAt(h, q) == /\ hs[h].ph = "" /\ Starts(h) /\ q \in 1..kq
                 /\ hs' = [hs EXCEPT ![h] = [ph |-> "part", q |-> q, j |-> 0]]
                 /\ UNCHANGED <<kq, t, hdr, parts, fl, shown, back, unheld, gone>>
HRead(h) == \E q \in 1..kq : HReadAt(h, q)
HReadFresh(h) == HReadAt(h, kq)
HPart(h) == /\ hs[h].ph = "part"
            /\ parts' = [parts EXCEPT ![Slot(hs[h].q)][hs[h].j] = [q |-> hs[h].q, lv |-> Lvl[h]]]
            /\ hs' = [hs EXCEPT ![h] = IF hs[h].j = 1 THEN [@ EXCEPT !.ph = "head"] ELSE [@ EXCEPT !.j = 1]]
            /\ UNCHANGED <<kq, t, hdr, fl, shown, back, unheld, gone>>
HHead(h) == LET new == [q |-> hs[h].q, at |-> t + Skew[h], lv |-> Lvl[h]]
                lv2 == IF FixLevelTakes THEN new.lv
                       ELSE IF FixLevelWins /\ new.lv > hdr.lv THEN new.lv ELSE hdr.lv
            IN /\ hs[h].ph = "head"
               /\ hdr' = IF new.q > hdr.q THEN new
                         ELSE IF new.q = hdr.q THEN [hdr EXCEPT !.at = new.at, !.lv = lv2]
                         ELSE hdr
               /\ hs' = [hs EXCEPT ![h] = H0]
               /\ UNCHANGED <<kq, t, parts, fl, shown, back, unheld, gone>>

FHead == /\ fl.ph = "" /\ hdr.q >= 1 /\ hdr.q > shown.q
         /\ fl' = [F0 EXCEPT !.ph = "p0", !.h = hdr]
         /\ UNCHANGED <<kq, t, hdr, parts, hs, shown, back, unheld, gone>>
FPart0 == /\ fl.ph = "p0" /\ fl' = [fl EXCEPT !.ph = "p1", !.got[1] = parts[Slot(fl.h.q)][0]]
          /\ UNCHANGED <<kq, t, hdr, parts, hs, shown, back, unheld, gone>>
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
          /\ UNCHANGED <<kq, t, hdr, parts, hs, gone>>

Next == Write \/ Tick \/ Deploy \/ FHead \/ FPart0 \/ FPart1
        \/ \E h \in Holders : HRead(h) \/ HPart(h) \/ HHead(h)

Fair == /\ WF_vars(Deploy)
        /\ SF_vars(HReadFresh(Survivor))
        /\ WF_vars(HPart(Survivor)) /\ WF_vars(HHead(Survivor))
        /\ WF_vars(FHead) /\ WF_vars(FPart0) /\ WF_vars(FPart1)

Spec == Init /\ [][Next]_vars
LiveSpec == Spec /\ Fair

ReadWasHeld == ~unheld
NeverBack == ~back
\* The oracle's liveness: on a quiet key the follower eventually shows the key's last state, and stays there.
ShowsLast == <>[](kq >= 1 => shown.q = kq)
=============================================================================
