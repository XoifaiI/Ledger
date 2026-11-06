---------------------------------- MODULE Copy ---------------------------------
\* Copy is the copies of the extras design (section 5, with the
\* holder of section 4), over env/Env.tla (a copy sits beside it).
\*
\* WHAT IS MODELLED
\*
\* One followed key k whose state needs two parts. Server A writes it:
\* each write adds 1 to the record's q, and the state of write count q is
\* the two pieces <<q, 0>> and <<q, 1>>, so pieces of two versions show
\* as a state the key never held. The copy is written to up to Reps
\* replicas. Replica r is a header item (q, the holder's clock at, the
\* number of parts, the replica count n and the complete count c) and its
\* parts, two per slot by the parity of q (5.1), each {q, d}. A refresh
\* (5.2) reads the key, picks a replica count n, and for each of replicas
\* n - 1 down to 1 and then replica 0 sets the two parts of slot q mod 2,
\* each carrying q, then updates that replica's header. A failed write to
\* replica 1, or a header update it cancels, leaves the push not whole:
\* replica 0 is then written as a push to replica 0 alone (n and c 1), as
\* Copies/Push does; on replica 0 either ends the refresh. Hearing an
\* answer and sending the next request are two steps, as in Tot: Env's
\* Reply and MsReply keep the other request table unchanged, so one
\* action that does both can never fire. The header's
\* transform cancels an update whose q is smaller than the item's (5.2);
\* else it writes the larger q, the larger n, the writer's clock (Ledger's
\* holder stamp is the last write's), and the complete count of the push
\* its q came from: c = n from a push, the larger c on an equal q. Any
\* server may refresh at any time with any n: who holds, when to grow and
\* when to push again are liveness, checked in CopyRep.tla.
\*
\* A follower's tick (5.3) gets the header of its home replica, Home[s]
\* mod the n its last header showed. If the header's q is above the q the
\* server last showed, it gets the parts of that slot of the same replica
\* one at a time and ends at a part that is missing or carries another q;
\* it shows the state once every part carried the header's q. A replica
\* other than 0 that holds no header or misses a part sends the server's
\* next tick to replica 0 (zf), as Copies/Follow does. With MemoryStore
\* down it reads the key itself. A show goes through the record's shown
\* table: only a q at least the last shown.
\*
\* LEFT OUT: the state in the header itself (a state that fits: one item,
\* no mixing), big (a header with no parts: the follower reads the key),
\* MaxAge, Tick, the lapse rule, the growth signal and the miss breaker
\* (liveness), Stale (local), gone keys, the cold read after a failed
\* read (a failed read ends the tick here), and a Peek's fallback inside
\* its one tick (Follow reads replica 0 at once; here the next tick does).
\*
\* PROPERTIES
\*   A7 ReadWasHeld: every shown state is one the key held. A8 NeverBack:
\*   what a server shows never goes back.
EXTENDS Env, TLC

CONSTANTS
    MaxW,          \* writes of k by A
    Reps,          \* the replicas a refresh may write, 1 or 2
    Home,          \* Home[s]: server s's home replica under the largest replica count
    FixPartQ,      \* a follower shows parts only when every part carries the header's q (A7)
    FixOrderQ      \* a follower orders by q; else by the header's clock, as UpdatedTime (A8, M14)

ASSUME Reps \in {1, 2}

VARIABLES
    rf,        \* rf[s]: a refresh in progress: [ph, q, n, todo, r, j, at] (ph "" none, "read", "parts", "head")
    tk,        \* tk[s]: a follower tick: [ph, h, rep, r, got, j] (ph "" none, "head", "parts", "key")
    nf,        \* nf[s]: the replica count of the last header server s read
    zf,        \* zf[s]: server s's next tick reads replica 0 (Copies/Follow's fallback)
    shown,     \* shown[s]: [q, at] of the state server s last showed (q -1: none)
    wout,      \* the write of A out, 0 for none
    writes,    \* writes of k sent
    back,      \* a show went back. Ghost.
    unheld     \* a show of a state k never held. Ghost.

vars == <<envVars, rf, tk, nf, zf, shown, wout, writes, back, unheld>>

K == "k"
Z == [ex |-> FALSE, q |-> 0]
Piece(q, j) == <<q, j>>

\* Replica r's items: its header, and its two slots of two parts.
HeaderItem(r) == IF r = 0 THEN "h" ELSE "g"
Slot(r, q) == IF r = 0 THEN (IF q % 2 = 0 THEN <<"a0", "a1">> ELSE <<"b0", "b1">>)
              ELSE (IF q % 2 = 0 THEN <<"c0", "c1">> ELSE <<"d0", "d1">>)

NoPart == [q |-> -1, d |-> <<-1, -1>>]
NoHead == [q |-> -1, at |-> -100, p |-> 0, n |-> 0, c |-> 0]
I0 == [q |-> -1, at |-> -100, p |-> 0, d |-> <<-1, -1>>, n |-> 0, c |-> 0]

\* A push to n writes replicas n - 1 down to 1, then replica 0.
Order(n) == IF n = 1 THEN <<0>> ELSE <<1, 0>>

\* The key: each write adds 1 to q (its state is Piece(q, 0) and Piece(q, 1)).
Tf(c, v) == WriteNote([ex |-> TRUE, q |-> v.q + 1], c.arg)

\* The header merge (5.2): an update with a smaller q than the item's is cancelled; else the larger q;
\* the larger n; the complete count of the push the kept q came from; and the writer's clock, as Ledger's
\* holder stamp keeps the last write's, whichever state stays. It writes every merge, as Copies/Push does.
\* The control orders the copy by that clock instead, as UpdatedTime would (M14).
MsTf(c, it) ==
    LET cur == IF it.has THEN it.v ELSE I0
        new == c.arg
        lower == IF FixOrderQ THEN new.q < cur.q ELSE new.at < cur.at
        take == IF FixOrderQ THEN new.q > cur.q ELSE new.at > cur.at
        keptC == IF new.q > cur.q THEN new.c ELSE IF new.q = cur.q THEN Max(cur.c, new.c) ELSE cur.c
        merged == IF take
                  THEN [cur EXCEPT !.q = new.q, !.at = new.at, !.p = 2, !.n = Max(cur.n, new.n), !.c = keptC]
                  ELSE [cur EXCEPT !.at = new.at, !.n = Max(cur.n, new.n), !.c = keptC]
    IN IF lower THEN MsCancel(c, it) ELSE MsWrite(c, merged)

RF0 == [ph |-> "", q |-> -1, n |-> 1, todo |-> <<>>, r |-> 0, j |-> 0, at |-> 0]
TK0 == [ph |-> "", h |-> NoHead, rep |-> 0, r |-> 0, got |-> <<NoPart, NoPart>>, j |-> 0]

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
    /\ UNCHANGED <<rf, tk, nf, zf, shown, back, unheld>>

HearWrite ==
    /\ wout # 0
    /\ \E a \in Heard : Reply(wout, a)
    /\ wout' = 0
    /\ UNCHANGED <<rf, tk, nf, zf, shown, writes, back, unheld>>

\* A part of replica r's slot of q, carrying q.
SetPart(s, r, q, j) == MsIssueSet(s, Slot(r, q)[j], [w |-> TRUE], Item([I0 EXCEPT !.q = q, !.d = Piece(q, j - 1)], MaxExpiry))

\* A holder's refresh: read k; pick n; for each replica in order set the two parts of its slot, then
\* update its header.
RefreshStart(s) ==
    /\ rf[s].ph = ""
    /\ IssueGet(s, K, [w |-> FALSE])
    /\ rf' = [rf EXCEPT ![s] = [RF0 EXCEPT !.ph = "read", !.r = NextReq]]
    /\ UNCHANGED <<tk, nf, zf, shown, wout, writes, back, unheld>>

RefreshRead(s) ==
    /\ rf[s].ph = "read"
    /\ \E a \in Heard, n \in 1..Reps :
         /\ Reply(rf[s].r, a)
         /\ rf' = IF a = "ok" /\ ReadOf(rf[s].r).v.ex
                  THEN [rf EXCEPT ![s] = [ph |-> "parts", q |-> ReadOf(rf[s].r).v.q, n |-> n, todo |-> Order(n), r |-> 0, j |-> 1, at |-> 0]]
                  ELSE [rf EXCEPT ![s] = RF0]
    /\ UNCHANGED <<tk, nf, zf, shown, wout, writes, back, unheld>>

\* The refresh's next request: part j of the replica at the head of todo, or that replica's header,
\* stamped with the clock at which its last part was heard, as Copies/Push stamps it.
RefreshSend(s) ==
    /\ rf[s].ph \in {"parts", "head"} /\ rf[s].r = 0
    /\ LET rep == Head(rf[s].todo) IN
       IF rf[s].ph = "parts"
       THEN SetPart(s, rep, rf[s].q, rf[s].j)
       ELSE MsIssue(s, HeaderItem(rep), [q |-> rf[s].q, at |-> rf[s].at, n |-> rf[s].n, c |-> rf[s].n], MaxExpiry)
    /\ rf' = [rf EXCEPT ![s].r = NextMsReq]
    /\ UNCHANGED <<tk, nf, zf, shown, wout, writes, back, unheld>>

\* A failed or cancelled write: on replica 0 the refresh ends; on replica 1 the push is not whole, and
\* replica 0 is written as a push to replica 0 alone.
Unwritten(s) ==
    rf' = [rf EXCEPT ![s] = IF Head(rf[s].todo) = 0 THEN RF0
                            ELSE [ph |-> "parts", q |-> rf[s].q, n |-> 1, todo |-> <<0>>, r |-> 0, j |-> 1, at |-> 0]]

RefreshPart(s) ==
    /\ rf[s].ph = "parts" /\ rf[s].r # 0
    /\ \E a \in MsHeard :
         /\ MsReply(rf[s].r, a)
         /\ IF a # "ok" THEN Unwritten(s)
            ELSE IF rf[s].j = 1 THEN rf' = [rf EXCEPT ![s].r = 0, ![s].j = 2]
            ELSE rf' = [rf EXCEPT ![s].ph = "head", ![s].r = 0, ![s].at = Clock(s)]
    /\ UNCHANGED <<tk, nf, zf, shown, wout, writes, back, unheld>>

\* The header's answer; then the next replica's parts, or the refresh ends. A cancel ("nil") is an update
\* whose q is below the replica's: the replica does not hold the push.
RefreshHead(s) ==
    /\ rf[s].ph = "head" /\ rf[s].r # 0
    /\ \E a \in MsHeard :
         /\ MsReply(rf[s].r, a)
         /\ IF a # "ok" THEN Unwritten(s)
            ELSE IF Tail(rf[s].todo) = <<>> THEN rf' = [rf EXCEPT ![s] = RF0]
            ELSE rf' = [rf EXCEPT ![s].ph = "parts", ![s].todo = Tail(rf[s].todo), ![s].r = 0, ![s].j = 1]
    /\ UNCHANGED <<tk, nf, zf, shown, wout, writes, back, unheld>>

\* A follower's tick: get the header of its home replica, or of replica 0 after a fallback; if it is newer
\* than what this server showed, get the parts of the same replica one at a time.
Newer(s, h) == IF FixOrderQ THEN h.q > shown[s].q ELSE h.at > shown[s].at
HomeOf(s) == Home[s] % Max(nf[s], 1)

TickStart(s) ==
    /\ tk[s].ph = ""
    /\ LET r == IF zf[s] THEN 0 ELSE HomeOf(s) IN
       /\ MsIssueGet(s, HeaderItem(r), [w |-> FALSE])
       /\ tk' = [tk EXCEPT ![s] = [TK0 EXCEPT !.ph = "head", !.r = NextMsReq, !.rep = r]]
    /\ zf' = [zf EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<rf, nf, shown, wout, writes, back, unheld>>

\* No header on a replica other than 0 sends the next tick to replica 0. A failed read ends the tick.
TickHead(s) ==
    /\ tk[s].ph = "head"
    /\ \E a \in MsHeard :
         /\ MsReply(tk[s].r, a)
         /\ LET it == mreq[tk[s].r].seen
                rep == tk[s].rep
                h == [q |-> it.v.q, at |-> it.v.at, p |-> it.v.p, n |-> it.v.n, c |-> it.v.c]
            IN IF a = "ok" /\ it.has /\ h.q >= 0
               THEN /\ nf' = [nf EXCEPT ![s] = Max(h.n, 1)]
                    /\ tk' = [tk EXCEPT ![s] = IF Newer(s, h)
                                               THEN [TK0 EXCEPT !.ph = "parts", !.h = h, !.rep = rep, !.j = 1]
                                               ELSE TK0]
                    /\ UNCHANGED zf
               ELSE /\ tk' = [tk EXCEPT ![s] = TK0]
                    /\ zf' = [zf EXCEPT ![s] = (a = "ok" /\ rep # 0)]
                    /\ UNCHANGED nf
    /\ UNCHANGED <<rf, shown, wout, writes, back, unheld>>

\* The tick's next request: part j of the header's slot of the same replica.
TickSend(s) ==
    /\ tk[s].ph = "parts" /\ tk[s].r = 0
    /\ MsIssueGet(s, Slot(tk[s].rep, tk[s].h.q)[tk[s].j], [w |-> FALSE])
    /\ tk' = [tk EXCEPT ![s].r = NextMsReq]
    /\ UNCHANGED <<rf, nf, zf, shown, wout, writes, back, unheld>>

\* 5.3: a part that is missing or, under FixPartQ, carries another q than the header's is a miss: the tick
\* ends, and on a replica other than 0 the next tick reads replica 0. The state shows once every part
\* carried the header's q. A failed read ends the tick.
TickPart(s) ==
    /\ tk[s].ph = "parts" /\ tk[s].r # 0
    /\ \E a \in MsHeard :
         /\ MsReply(tk[s].r, a)
         /\ LET it == mreq[tk[s].r].seen
                p == IF it.has THEN [q |-> it.v.q, d |-> it.v.d] ELSE NoPart
                got == IF tk[s].j = 1 THEN <<p, NoPart>> ELSE <<tk[s].got[1], p>>
                h == tk[s].h
            IN IF a # "ok"
               THEN /\ tk' = [tk EXCEPT ![s] = TK0]
                    /\ UNCHANGED <<zf, shown, back, unheld>>
               ELSE IF ~it.has \/ (FixPartQ /\ p.q # h.q)
               THEN /\ tk' = [tk EXCEPT ![s] = TK0]
                    /\ zf' = [zf EXCEPT ![s] = (tk[s].rep # 0)]
                    /\ UNCHANGED <<shown, back, unheld>>
               ELSE IF tk[s].j = 1
               THEN /\ tk' = [tk EXCEPT ![s].r = 0, ![s].j = 2, ![s].got = got]
                    /\ UNCHANGED <<zf, shown, back, unheld>>
               ELSE /\ tk' = [tk EXCEPT ![s] = TK0]
                    /\ UNCHANGED zf
                    /\ ShowIt(s, h.q, h.at, got[1].d, got[2].d)
    /\ UNCHANGED <<rf, nf, wout, writes>>

\* MemoryStore down (or any time): the follower reads the key itself, through the shown table.
KeyStart(s) ==
    /\ tk[s].ph = ""
    /\ IssueGet(s, K, [w |-> FALSE])
    /\ tk' = [tk EXCEPT ![s] = [TK0 EXCEPT !.ph = "key", !.r = NextReq]]
    /\ UNCHANGED <<rf, nf, zf, shown, wout, writes, back, unheld>>

KeyRead(s) ==
    /\ tk[s].ph = "key"
    /\ \E a \in Heard :
         /\ Reply(tk[s].r, a)
         /\ tk' = [tk EXCEPT ![s] = TK0]
         /\ LET x == ReadOf(tk[s].r).v IN
            IF a = "ok" /\ x.ex /\ x.q >= shown[s].q THEN ShowIt(s, x.q, shown[s].at, Piece(x.q, 0), Piece(x.q, 1))
            ELSE UNCHANGED <<shown, back, unheld>>
    /\ UNCHANGED <<rf, nf, zf, wout, writes>>

Init ==
    /\ EnvInit(Z, I0)
    /\ rf = [s \in Servers |-> RF0]
    /\ tk = [s \in Servers |-> TK0]
    /\ nf = [s \in Servers |-> 1]
    /\ zf = [s \in Servers |-> FALSE]
    /\ shown = [s \in Servers |-> [q |-> -1, at |-> -100]]
    /\ wout = 0 /\ writes = 0 /\ back = FALSE /\ unheld = FALSE

EnvStep == EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<rf, tk, nf, zf, shown, wout, writes, back, unheld>>

Next ==
    \/ EnvStep
    \/ \E s \in Servers : /\ Crash(s)
                          /\ rf' = [rf EXCEPT ![s] = RF0]
                          /\ tk' = [tk EXCEPT ![s] = TK0]
                          /\ nf' = [nf EXCEPT ![s] = 1]
                          /\ zf' = [zf EXCEPT ![s] = FALSE]
                          /\ shown' = [shown EXCEPT ![s] = [q |-> -1, at |-> -100]]
                          /\ wout' = IF s = "A" THEN 0 ELSE wout
                          /\ UNCHANGED <<writes, back, unheld>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<rf, tk, nf, zf, shown, wout, writes, back, unheld>>
    \/ WriteK \/ HearWrite
    \/ \E s \in Servers : RefreshStart(s) \/ RefreshRead(s) \/ RefreshSend(s) \/ RefreshPart(s) \/ RefreshHead(s)
                          \/ TickStart(s) \/ TickHead(s) \/ TickSend(s) \/ TickPart(s) \/ KeyStart(s) \/ KeyRead(s)

Spec == Init /\ [][Next]_vars

ReadWasHeld == ~unheld
NeverBack == ~back
\* Probe: a server shows a state at q 2 or more, from the copy or from the key.
ShownLate == \A s \in Servers : shown[s].q < 2
\* Probe: a follower holds one part of a slot from the copy, of any replica.
ReadFromCopy == ~\E s \in Servers : tk[s].ph = "parts" /\ tk[s].j = 2
\* Probe: a follower holds one part of a slot of replica 1.
ReadFromReplica == ~\E s \in Servers : tk[s].ph = "parts" /\ tk[s].rep = 1 /\ tk[s].j = 2
\* Probes for the replay (tests/replay, Copy): a header update has applied over a live header with a newer
\* q or a smaller replica count, so its merge had something to keep, or was cancelled over one with a
\* larger q, while one server alone updates replica 0's header, as Ledger's lease allows (the model has no
\* lease). A follower falls back: its tick reads replica 0 away from its home.
HeaderMerge(r) == mreq[r].kind = "upd" /\ mreq[r].ph = "applied" /\ mreq[r].seen.has
OneHolder == \A x, y \in DOMAIN mreq :
    (mreq[x].key = "h" /\ mreq[y].key = "h" /\ mreq[x].kind = "upd" /\ mreq[y].kind = "upd") => mreq[x].srv = mreq[y].srv
MergesNewer == ~(OneHolder /\ \E r \in DOMAIN mreq : HeaderMerge(r) /\ mreq[r].arg.q > mreq[r].seen.v.q)
CancelsOlder == ~(OneHolder /\ \E r \in DOMAIN mreq :
    mreq[r].kind = "upd" /\ mreq[r].ph = "cancel" /\ mreq[r].seen.has /\ mreq[r].arg.q < mreq[r].seen.v.q)
MergesSmallerN == ~(OneHolder /\ \E r \in DOMAIN mreq : HeaderMerge(r) /\ mreq[r].arg.n < mreq[r].seen.v.n)
FallsBack == ~(OneHolder /\ \E s \in Servers : tk[s].ph = "head" /\ tk[s].rep = 0 /\ HomeOf(s) # 0)
=============================================================================
