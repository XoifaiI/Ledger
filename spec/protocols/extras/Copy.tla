---------------------------------- MODULE Copy ---------------------------------
\* Copy is the copies of the extras design (section 5, with the
\* holder of section 4), over env/Env.tla (a copy sits beside it).
\*
\* WHAT IS MODELLED
\*
\* One followed key k whose state needs two parts. Server A writes it:
\* each write adds 1 to the record's q, and the state of write count q is
\* the two pieces <<q, 0>> and <<q, 1>>, so pieces of two versions show
\* as a state the key never held. The copy is a header item h (q, the
\* holder's clock at, and the number of parts) and the parts, two per slot
\* by the parity of q (5.1): items "a0", "a1" for even q, "b0", "b1" for
\* odd, each {q, d}. A holder's refresh (5.2) reads the key, sets the two
\* parts of slot q mod 2, each carrying q, then updates the header, whose
\* transform keeps the larger q. Any server may refresh at any time: who
\* holds is liveness. A follower's tick (5.3) gets the header; if its q is
\* above the q the server last showed, it gets both parts of that slot and
\* shows the state only if every part carries the header's q. With
\* MemoryStore down it reads the key itself. A show goes through the
\* record's shown table: only a q at least the last shown.
\*
\* LEFT OUT: the state in the header itself (a state that fits: one item,
\* no mixing), big (a header with no parts: the follower reads the key),
\* MaxAge, Tick and the lapse rule (liveness), Stale (local), gone keys.
\*
\* PROPERTIES
\*   A7 ReadWasHeld: every shown state is one the key held. A8 NeverBack:
\*   what a server shows never goes back.
EXTENDS Env, TLC

CONSTANTS
    MaxW,          \* writes of k by A
    FixPartQ,      \* a follower shows parts only when every part carries the header's q (A7)
    FixOrderQ      \* a follower orders by q; else by the header's clock, as UpdatedTime (A8, M14)

VARIABLES
    rf,        \* rf[s]: a refresh in progress: [ph, q, r] (ph "" none, "read", "parts", "head")
    tk,        \* tk[s]: a follower tick: [ph, h, r, got] (ph "" none, "head", "parts", "key")
    shown,     \* shown[s]: [q, at] of the state server s last showed (q -1: none)
    wout,      \* the write of A out, 0 for none
    writes,    \* writes of k sent
    back,      \* a show went back. Ghost.
    unheld     \* a show of a state k never held. Ghost.

vars == <<envVars, rf, tk, shown, wout, writes, back, unheld>>

K == "k"
Z == [ex |-> FALSE, q |-> 0]
Piece(q, j) == <<q, j>>
Slot(q) == IF q % 2 = 0 THEN <<"a0", "a1">> ELSE <<"b0", "b1">>
NoPart == [q |-> -1, d |-> <<-1, -1>>]
NoHead == [q |-> -1, at |-> -100, p |-> 0]
I0 == [q |-> -1, at |-> -100, p |-> 0, d |-> <<-1, -1>>]

\* The key: each write adds 1 to q (its state is Piece(q, 0) and Piece(q, 1)).
Tf(c, v) == WriteNote([ex |-> TRUE, q |-> v.q + 1], c.arg)

\* The header keeps the larger q; on an equal q it renews the holder's clock (5.2). The control orders
\* the copy by the holder's clock instead, as UpdatedTime would (M14).
MsTf(c, it) ==
    LET cur == IF it.has THEN it.v ELSE I0
        new == c.arg
        take == IF FixOrderQ THEN new.q > cur.q \/ (new.q = cur.q /\ new.at > cur.at) ELSE new.at > cur.at
    IN IF take THEN MsWrite(c, [cur EXCEPT !.q = new.q, !.at = new.at, !.p = 2]) ELSE MsCancel(c, it)

RF0 == [ph |-> "", q |-> -1, r |-> 0, j |-> 0]
TK0 == [ph |-> "", h |-> NoHead, r |-> 0, got |-> <<NoPart, NoPart>>, j |-> 0]

\* The ghosts of a show: A7 (the two pieces are one state k held) and A8 (q never goes back). at is
\* the header's clock for a show from the copy.
ShowIt(s, q, at, d0, d1) ==
    /\ shown' = [shown EXCEPT ![s] = [q |-> q, at |-> at]]
    /\ back' = (back \/ q < shown[s].q)
    /\ unheld' = (unheld \/ ~(d0 = Piece(q, 0) /\ d1 = Piece(q, 1) /\ q <= ver[K]))

WriteK ==
    /\ wout = 0 /\ writes < MaxW
    /\ Issue("A", K, [w |-> TRUE])
    /\ wout' = NextReq /\ writes' = writes + 1
    /\ UNCHANGED <<rf, tk, shown, back, unheld>>

HearWrite ==
    /\ wout # 0
    /\ \E a \in Heard : Reply(wout, a)
    /\ wout' = 0
    /\ UNCHANGED <<rf, tk, shown, writes, back, unheld>>

\* A holder's refresh: read k; set the two parts of its slot; update the header.
RefreshStart(s) ==
    /\ rf[s].ph = ""
    /\ IssueGet(s, K, [w |-> FALSE])
    /\ rf' = [rf EXCEPT ![s] = [RF0 EXCEPT !.ph = "read", !.r = NextReq]]
    /\ UNCHANGED <<tk, shown, wout, writes, back, unheld>>

RefreshRead(s) ==
    /\ rf[s].ph = "read"
    /\ \E a \in Heard :
         /\ Reply(rf[s].r, a)
         /\ IF a = "ok" /\ ReadOf(rf[s].r).v.ex
            THEN LET q == ReadOf(rf[s].r).v.q IN
                 /\ MsIssueSet(s, Slot(q)[1], [w |-> TRUE], Item([I0 EXCEPT !.q = q, !.d = Piece(q, 0)], MaxExpiry))
                 /\ rf' = [rf EXCEPT ![s] = [ph |-> "parts", q |-> q, r |-> NextMsReq, j |-> 1]]
            ELSE rf' = [rf EXCEPT ![s] = RF0]
    /\ UNCHANGED <<tk, shown, wout, writes, back, unheld>>

RefreshPart(s) ==
    /\ rf[s].ph = "parts"
    /\ \E a \in MsHeard :
         /\ MsReply(rf[s].r, a)
         /\ IF a # "ok" THEN rf' = [rf EXCEPT ![s] = RF0]
            ELSE IF rf[s].j = 1
            THEN /\ MsIssueSet(s, Slot(rf[s].q)[2], [w |-> TRUE], Item([I0 EXCEPT !.q = rf[s].q, !.d = Piece(rf[s].q, 1)], MaxExpiry))
                 /\ rf' = [rf EXCEPT ![s].r = NextMsReq, ![s].j = 2]
            ELSE /\ MsIssue(s, "h", [q |-> rf[s].q, at |-> Clock(s)], MaxExpiry)
                 /\ rf' = [rf EXCEPT ![s].ph = "head", ![s].r = NextMsReq]
    /\ UNCHANGED <<tk, shown, wout, writes, back, unheld>>

RefreshHead(s) ==
    /\ rf[s].ph = "head"
    /\ \E a \in MsHeard : MsReply(rf[s].r, a)
    /\ rf' = [rf EXCEPT ![s] = RF0]
    /\ UNCHANGED <<tk, shown, wout, writes, back, unheld>>

\* A follower's tick: get the header; if it is newer than what this server showed, get the parts.
Newer(s, h) == IF FixOrderQ THEN h.q > shown[s].q ELSE h.at > shown[s].at

TickStart(s) ==
    /\ tk[s].ph = ""
    /\ MsIssueGet(s, "h", [w |-> FALSE])
    /\ tk' = [tk EXCEPT ![s] = [TK0 EXCEPT !.ph = "head", !.r = NextMsReq]]
    /\ UNCHANGED <<rf, shown, wout, writes, back, unheld>>

TickHead(s) ==
    /\ tk[s].ph = "head"
    /\ \E a \in MsHeard :
         /\ MsReply(tk[s].r, a)
         /\ LET it == mreq[tk[s].r].seen
                h == [q |-> it.v.q, at |-> it.v.at, p |-> it.v.p]
            IN IF a = "ok" /\ it.has /\ h.q >= 0 /\ Newer(s, h)
               THEN /\ MsIssueGet(s, Slot(h.q)[1], [w |-> FALSE])
                    /\ tk' = [tk EXCEPT ![s] = [TK0 EXCEPT !.ph = "parts", !.h = h, !.r = NextMsReq, !.j = 1]]
               ELSE tk' = [tk EXCEPT ![s] = TK0]
    /\ UNCHANGED <<rf, shown, wout, writes, back, unheld>>

TickPart(s) ==
    /\ tk[s].ph = "parts"
    /\ \E a \in MsHeard :
         /\ MsReply(tk[s].r, a)
         /\ LET it == mreq[tk[s].r].seen
                p == IF it.has THEN [q |-> it.v.q, d |-> it.v.d] ELSE NoPart
                got == IF tk[s].j = 1 THEN <<p, NoPart>> ELSE <<tk[s].got[1], p>>
                h == tk[s].h
            IN IF a # "ok" \/ ~it.has THEN /\ tk' = [tk EXCEPT ![s] = TK0]
                                            /\ UNCHANGED <<shown, back, unheld>>
               ELSE IF tk[s].j = 1
               THEN /\ MsIssueGet(s, Slot(h.q)[2], [w |-> FALSE])
                    /\ tk' = [tk EXCEPT ![s].r = NextMsReq, ![s].j = 2, ![s].got = got]
                    /\ UNCHANGED <<shown, back, unheld>>
               \* 5.3: show only if every part carries the header's q.
               ELSE /\ tk' = [tk EXCEPT ![s] = TK0]
                    /\ IF ~FixPartQ \/ (got[1].q = h.q /\ got[2].q = h.q)
                       THEN ShowIt(s, h.q, h.at, got[1].d, got[2].d)
                       ELSE UNCHANGED <<shown, back, unheld>>
    /\ UNCHANGED <<rf, wout, writes>>

\* MemoryStore down (or any time): the follower reads the key itself, through the shown table.
KeyStart(s) ==
    /\ tk[s].ph = ""
    /\ IssueGet(s, K, [w |-> FALSE])
    /\ tk' = [tk EXCEPT ![s] = [TK0 EXCEPT !.ph = "key", !.r = NextReq]]
    /\ UNCHANGED <<rf, shown, wout, writes, back, unheld>>

KeyRead(s) ==
    /\ tk[s].ph = "key"
    /\ \E a \in Heard :
         /\ Reply(tk[s].r, a)
         /\ tk' = [tk EXCEPT ![s] = TK0]
         /\ LET x == ReadOf(tk[s].r).v IN
            IF a = "ok" /\ x.ex /\ x.q >= shown[s].q THEN ShowIt(s, x.q, shown[s].at, Piece(x.q, 0), Piece(x.q, 1))
            ELSE UNCHANGED <<shown, back, unheld>>
    /\ UNCHANGED <<rf, wout, writes>>

Init ==
    /\ EnvInit(Z, I0)
    /\ rf = [s \in Servers |-> RF0]
    /\ tk = [s \in Servers |-> TK0]
    /\ shown = [s \in Servers |-> [q |-> -1, at |-> -100]]
    /\ wout = 0 /\ writes = 0 /\ back = FALSE /\ unheld = FALSE

EnvStep == EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<rf, tk, shown, wout, writes, back, unheld>>

Next ==
    \/ EnvStep
    \/ \E s \in Servers : /\ Crash(s)
                          /\ rf' = [rf EXCEPT ![s] = RF0]
                          /\ tk' = [tk EXCEPT ![s] = TK0]
                          /\ shown' = [shown EXCEPT ![s] = [q |-> -1, at |-> -100]]
                          /\ wout' = IF s = "A" THEN 0 ELSE wout
                          /\ UNCHANGED <<writes, back, unheld>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<rf, tk, shown, wout, writes, back, unheld>>
    \/ WriteK \/ HearWrite
    \/ \E s \in Servers : RefreshStart(s) \/ RefreshRead(s) \/ RefreshPart(s) \/ RefreshHead(s)
                          \/ TickStart(s) \/ TickHead(s) \/ TickPart(s) \/ KeyStart(s) \/ KeyRead(s)

Spec == Init /\ [][Next]_vars

ReadWasHeld == ~unheld
NeverBack == ~back
\* Probe: a follower shows a state from the copy at q 2 or more.
ShownLate == \A s \in Servers : shown[s].q < 2
=============================================================================
