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
\* parts, two per slot by the parity of q (5.1), each {q, d}. A holder's
\* refresh (5.2, R5a) reads the key and shows the read as a key read does,
\* then decides from its lease alone (the header replica 0 held after its
\* last ok): with no lease it pushes replica 0 alone, n and c 1; with one
\* it pushes a q above the lease's, or the lease's own q when the lease
\* says c < n or its count grew past the lease's n (D23), at its count;
\* on the lease's q otherwise it may push (the push age), renew replica
\* 0's header or do nothing; a q below the lease's does nothing. A push
\* writes replica n - 1 down to 1 and then replica 0, each its two parts
\* of slot q mod 2, carrying q, then its header. A failed write to replica
\* 1, or a header update it cancels, leaves the push not whole: replica 0
\* is then written as a push to it alone (n and c 1), as Copies/Push does.
\* On replica 0 an ok makes the merged header the lease and raises the
\* count to its n, a nil drops the lease (D13), and a failure under a
\* lease, part or header, sends a cold read of z, a key nothing writes
\* (D14): if it answers, the lease is kept and the count doubles, up to
\* Reps, once the lease's c has reached it (R8, R9, D12); if not, the
\* lease goes. So n rises only by growth (D1). Hearing an
\* answer and sending the next request are two steps, as in Tot: Env's
\* Reply and MsReply keep the other request table unchanged, so one
\* action that does both can never fire. The header's
\* transform cancels an update whose q is smaller than the item's (5.2);
\* else it writes the larger q, the larger n, the writer's clock (Ledger's
\* holder stamp is the last write's), and the complete count of the push
\* its q came from: c = n from a push, the larger c on an equal q. Any
\* server of Holders may refresh at any time: who holds, the lease's
\* clock and when to push again are liveness, checked in CopyRep.tla.
\*
\* A follower's tick (5.3) gets the header of its home replica, Home[s]
\* mod the n its last header showed. If the header's q is above the q the
\* server last showed, it gets the parts of that slot of the same replica
\* one at a time and ends at a part that is missing or carries another q;
\* it shows the state once every part carried the header's q. A replica
\* other than 0 that holds no header or misses a part sends the server's
\* next tick to replica 0 (zf), as Copies/Follow does. A failed header or
\* part read sends one cold read of z (R9): an answer ends the tick
\* quietly, a failure sends the follower to the key itself, as it may also
\* go at any time. A show goes through the record's shown table: only a q
\* at least the last shown. Holders and Followers are every server unless
\* a config narrows them.
\*
\* LEFT OUT: the state in the header itself (a state that fits: one item,
\* no mixing), big (a header with no parts: the follower reads the key),
\* MaxAge, Tick, the lapse rule, replica 0's lease check and the miss
\* breaker (liveness), Stale (local), gone keys, and a Peek's fallback
\* inside its one tick (a Peek reads replica 0 at once; Follow's next tick
\* does, as here).
\*
\* PROPERTIES
\*   A7 ReadWasHeld: every shown state is one the key held. A8 NeverBack:
\*   what a server shows never goes back.
EXTENDS Env, TLC

CONSTANTS
    MaxW,          \* writes of k by A
    Reps,          \* the most replicas a holder's count reaches, 1 or 2
    Home,          \* Home[s]: server s's home replica under the largest replica count
    FixPartQ,      \* a follower shows parts only when every part carries the header's q (A7)
    FixOrderQ      \* a follower orders by q; else by the header's clock, as UpdatedTime (A8, M14)

ASSUME Reps \in {1, 2}

VARIABLES
    rf,        \* rf[s]: a refresh: [ph, q, n, c, todo, r, j, at, ren] (ph "" none, "read", "parts", "head",
               \* "cold" with r 0 the cold read to send, "coldread")
    lease,     \* lease[s]: replica 0's header after this server's last ok: [q, n, c] (q -1: none)
    cnt,       \* cnt[s]: the server's replica count as holder (D12, D25)
    tk,        \* tk[s]: a follower tick: [ph, h, rep, r, got, j] (ph "" none, "head", "parts", "key",
               \* "cold" with r 0 the cold read to send, "coldread", "down" before its key read)
    nf,        \* nf[s]: the replica count of the last header server s read
    zf,        \* zf[s]: server s's next tick reads replica 0 (Copies/Follow's fallback)
    shown,     \* shown[s]: [q, at] of the state server s last showed (q -1: none)
    wout,      \* the write of A out, 0 for none
    writes,    \* writes of k sent
    back,      \* a show went back. Ghost.
    unheld     \* a show of a state k never held. Ghost.

vars == <<envVars, rf, lease, cnt, tk, nf, zf, shown, wout, writes, back, unheld>>

K == "k"
Cold == "z"
Z == [ex |-> FALSE, q |-> 0]
NoLease == [q |-> -1, n |-> 0, c |-> 0]
Min(a, b) == IF a <= b THEN a ELSE b
\* Who refreshes and who ticks or reads the key as a follower: every server unless a config narrows it.
Holders == Servers
Followers == Servers
\* A holder's count at the start: 1, or 2 where a config starts holders that grew before (a count lives with
\* its holder, D25), so a probe of the replica path needs no failure to grow first. A crash starts it at 1.
InitCount == 1
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

RF0 == [ph |-> "", q |-> -1, n |-> 1, c |-> 1, todo |-> <<>>, r |-> 0, j |-> 0, at |-> 0, ren |-> FALSE]
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
    /\ UNCHANGED <<rf, lease, cnt, tk, nf, zf, shown, back, unheld>>

HearWrite ==
    /\ wout # 0
    /\ \E a \in Heard : Reply(wout, a)
    /\ wout' = 0
    /\ UNCHANGED <<rf, lease, cnt, tk, nf, zf, shown, writes, back, unheld>>

\* A part of replica r's slot of q, carrying q.
SetPart(s, r, q, j) == MsIssueSet(s, Slot(r, q)[j], [w |-> TRUE], Item([I0 EXCEPT !.q = q, !.d = Piece(q, j - 1)], MaxExpiry))

\* A holder's refresh (5.2, sheet E8, R5a): read k.
RefreshStart(s) ==
    /\ s \in Holders
    /\ rf[s].ph = ""
    /\ IssueGet(s, K, [w |-> FALSE])
    /\ rf' = [rf EXCEPT ![s] = [RF0 EXCEPT !.ph = "read", !.r = NextReq]]
    /\ UNCHANGED <<lease, cnt, tk, nf, zf, shown, wout, writes, back, unheld>>

\* A push of q to n replicas: replica n - 1 first, replica 0 last, each header carrying n and c = n.
Push(q, n) == [RF0 EXCEPT !.ph = "parts", !.q = q, !.n = n, !.c = n, !.todo = Order(n), !.j = 1]

\* The read the holder shows: "ok" with a value at a q at least the shown q. It decides from its lease
\* alone (R5a): no lease pushes replica 0 alone; a q above the lease's, or the lease's own q when the
\* lease says c < n or the count grew past the lease's n (D23), pushes at the count; the lease's own q
\* otherwise is a free choice for the code's push age and renew time: push, renew or nothing; a q below
\* the lease's does nothing. Any other answer ends the refresh (the code reads again later).
RefreshRead(s) ==
    /\ rf[s].ph = "read"
    /\ \E a \in Heard :
         LET x == ReadOf(rf[s].r).v
             L == lease[s]
         IN /\ Reply(rf[s].r, a)
            /\ IF a = "ok" /\ x.ex /\ x.q >= shown[s].q
               THEN /\ ShowIt(s, x.q, shown[s].at, Piece(x.q, 0), Piece(x.q, 1))
                    /\ \/ L.q < 0 /\ rf' = [rf EXCEPT ![s] = Push(x.q, 1)]
                       \/ /\ L.q >= 0 /\ (x.q > L.q \/ (x.q = L.q /\ (L.c < L.n \/ cnt[s] > L.n)))
                          /\ rf' = [rf EXCEPT ![s] = Push(x.q, cnt[s])]
                       \/ /\ L.q >= 0 /\ x.q = L.q /\ L.c >= L.n /\ cnt[s] <= L.n
                          /\ \/ rf' = [rf EXCEPT ![s] = Push(x.q, cnt[s])]
                             \/ rf' = [rf EXCEPT ![s] = [RF0 EXCEPT !.ph = "head", !.q = x.q, !.n = L.n, !.c = L.c,
                                                                    !.todo = <<0>>, !.at = Clock(s), !.ren = TRUE]]
                             \/ rf' = [rf EXCEPT ![s] = RF0]
                       \/ L.q >= 0 /\ x.q < L.q /\ rf' = [rf EXCEPT ![s] = RF0]
               ELSE /\ rf' = [rf EXCEPT ![s] = RF0]
                    /\ UNCHANGED <<shown, back, unheld>>
    /\ UNCHANGED <<lease, cnt, tk, nf, zf, wout, writes>>

\* The refresh's next request: part j of the replica at the head of todo, or that replica's header,
\* stamped with the clock at which its last part was heard, as Copies/Push stamps it.
RefreshSend(s) ==
    /\ rf[s].ph \in {"parts", "head"} /\ rf[s].r = 0
    /\ LET rep == Head(rf[s].todo) IN
       IF rf[s].ph = "parts"
       THEN SetPart(s, rep, rf[s].q, rf[s].j)
       ELSE MsIssue(s, HeaderItem(rep), [q |-> rf[s].q, at |-> rf[s].at, n |-> rf[s].n, c |-> rf[s].c], MaxExpiry)
    /\ rf' = [rf EXCEPT ![s].r = NextMsReq]
    /\ UNCHANGED <<lease, cnt, tk, nf, zf, shown, wout, writes, back, unheld>>

\* A failed or cancelled write: on replica 1 the push is not whole, and replica 0 is written as a push
\* to it alone (n and c 1); on replica 0, under a lease, the cold read goes next, and with none the
\* refresh ends.
Unwritten(s) ==
    rf' = [rf EXCEPT ![s] = IF Head(rf[s].todo) # 0
                            THEN [RF0 EXCEPT !.ph = "parts", !.q = rf[s].q, !.todo = <<0>>, !.j = 1]
                            ELSE IF lease[s].q >= 0 THEN [RF0 EXCEPT !.ph = "cold"] ELSE RF0]

RefreshPart(s) ==
    /\ rf[s].ph = "parts" /\ rf[s].r # 0
    /\ \E a \in MsHeard :
         /\ MsReply(rf[s].r, a)
         /\ IF a # "ok" THEN Unwritten(s)
            ELSE IF rf[s].j = 1 THEN rf' = [rf EXCEPT ![s].r = 0, ![s].j = 2]
            ELSE rf' = [rf EXCEPT ![s].ph = "head", ![s].r = 0, ![s].at = Clock(s)]
    /\ UNCHANGED <<lease, cnt, tk, nf, zf, shown, wout, writes, back, unheld>>

\* The header's answer. On replica 1: "ok" goes on to replica 0's parts; else the push is not whole. On
\* replica 0: "ok" makes the merged header the lease and raises the count to its n; "nil" (a cancel: a
\* lower q, or in the code another holder's live lease) drops the lease (D13); "err" goes to the cold
\* read under a lease.
RefreshHead(s) ==
    /\ rf[s].ph = "head" /\ rf[s].r # 0
    /\ \E a \in MsHeard :
         LET merged == mreq[rf[s].r].res.v IN
         /\ MsReply(rf[s].r, a)
         /\ IF Head(rf[s].todo) # 0
            THEN /\ IF a = "ok"
                    THEN rf' = [rf EXCEPT ![s].ph = "parts", ![s].todo = Tail(rf[s].todo), ![s].r = 0, ![s].j = 1]
                    ELSE Unwritten(s)
                 /\ UNCHANGED <<lease, cnt>>
            ELSE IF a = "ok"
            THEN /\ lease' = [lease EXCEPT ![s] = [q |-> merged.q, n |-> merged.n, c |-> merged.c]]
                 /\ cnt' = [cnt EXCEPT ![s] = Max(@, merged.n)]
                 /\ rf' = [rf EXCEPT ![s] = RF0]
            ELSE IF a = "nil"
            THEN /\ lease' = [lease EXCEPT ![s] = NoLease]
                 /\ rf' = [rf EXCEPT ![s] = RF0]
                 /\ UNCHANGED cnt
            ELSE /\ Unwritten(s)
                 /\ UNCHANGED <<lease, cnt>>
    /\ UNCHANGED <<tk, nf, zf, shown, wout, writes, back, unheld>>

\* The cold read after a failure on replica 0 under a lease (R8, R9, D14), and its answer: "ok" (absent
\* included) keeps the lease and doubles the count, up to Reps, once the lease's c has reached it (D12);
\* anything else lets the lease go.
RefreshCold(s) ==
    /\ rf[s].ph = "cold" /\ rf[s].r = 0
    /\ MsIssueGet(s, Cold, [w |-> FALSE])
    /\ rf' = [rf EXCEPT ![s].ph = "coldread", ![s].r = NextMsReq]
    /\ UNCHANGED <<lease, cnt, tk, nf, zf, shown, wout, writes, back, unheld>>

RefreshColdRead(s) ==
    /\ rf[s].ph = "coldread"
    /\ \E a \in MsHeard :
         /\ MsReply(rf[s].r, a)
         /\ IF a = "ok"
            THEN /\ cnt' = [cnt EXCEPT ![s] = IF lease[s].c >= @ THEN Min(2 * @, Reps) ELSE @]
                 /\ UNCHANGED lease
            ELSE /\ lease' = [lease EXCEPT ![s] = NoLease]
                 /\ UNCHANGED cnt
    /\ rf' = [rf EXCEPT ![s] = RF0]
    /\ UNCHANGED <<tk, nf, zf, shown, wout, writes, back, unheld>>

\* A follower's tick: get the header of its home replica, or of replica 0 after a fallback; if it is newer
\* than what this server showed, get the parts of the same replica one at a time.
Newer(s, h) == IF FixOrderQ THEN h.q > shown[s].q ELSE h.at > shown[s].at
HomeOf(s) == Home[s] % Max(nf[s], 1)

TickStart(s) ==
    /\ s \in Followers
    /\ tk[s].ph = ""
    /\ LET r == IF zf[s] THEN 0 ELSE HomeOf(s) IN
       /\ MsIssueGet(s, HeaderItem(r), [w |-> FALSE])
       /\ tk' = [tk EXCEPT ![s] = [TK0 EXCEPT !.ph = "head", !.r = NextMsReq, !.rep = r]]
    /\ zf' = [zf EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<rf, lease, cnt, nf, shown, wout, writes, back, unheld>>

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
               ELSE /\ tk' = [tk EXCEPT ![s] = IF a = "err" THEN [TK0 EXCEPT !.ph = "cold"] ELSE TK0]
                    /\ zf' = [zf EXCEPT ![s] = (a = "ok" /\ rep # 0)]
                    /\ UNCHANGED nf
    /\ UNCHANGED <<rf, lease, cnt, shown, wout, writes, back, unheld>>

\* The tick's next request: part j of the header's slot of the same replica.
TickSend(s) ==
    /\ tk[s].ph = "parts" /\ tk[s].r = 0
    /\ MsIssueGet(s, Slot(tk[s].rep, tk[s].h.q)[tk[s].j], [w |-> FALSE])
    /\ tk' = [tk EXCEPT ![s].r = NextMsReq]
    /\ UNCHANGED <<rf, lease, cnt, nf, zf, shown, wout, writes, back, unheld>>

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
               THEN /\ tk' = [tk EXCEPT ![s] = [TK0 EXCEPT !.ph = "cold"]]
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
    /\ UNCHANGED <<rf, lease, cnt, nf, wout, writes>>

\* A failed header or part read sends one cold read (R9): an answer ends the tick quietly; a failure
\* means MemoryStore is down, and the follower reads the key (KeyStart from "down").
TickCold(s) ==
    /\ tk[s].ph = "cold" /\ tk[s].r = 0
    /\ MsIssueGet(s, Cold, [w |-> FALSE])
    /\ tk' = [tk EXCEPT ![s].ph = "coldread", ![s].r = NextMsReq]
    /\ UNCHANGED <<rf, lease, cnt, nf, zf, shown, wout, writes, back, unheld>>

TickColdRead(s) ==
    /\ tk[s].ph = "coldread"
    /\ \E a \in MsHeard :
         /\ MsReply(tk[s].r, a)
         /\ tk' = [tk EXCEPT ![s] = IF a = "ok" THEN TK0 ELSE [TK0 EXCEPT !.ph = "down"]]
    /\ UNCHANGED <<rf, lease, cnt, nf, zf, shown, wout, writes, back, unheld>>

\* MemoryStore down (or any time): the follower reads the key itself, through the shown table.
KeyStart(s) ==
    /\ s \in Followers
    /\ tk[s].ph \in {"", "down"}
    /\ IssueGet(s, K, [w |-> FALSE])
    /\ tk' = [tk EXCEPT ![s] = [TK0 EXCEPT !.ph = "key", !.r = NextReq]]
    /\ UNCHANGED <<rf, lease, cnt, nf, zf, shown, wout, writes, back, unheld>>

KeyRead(s) ==
    /\ tk[s].ph = "key"
    /\ \E a \in Heard :
         /\ Reply(tk[s].r, a)
         /\ tk' = [tk EXCEPT ![s] = TK0]
         /\ LET x == ReadOf(tk[s].r).v IN
            IF a = "ok" /\ x.ex /\ x.q >= shown[s].q THEN ShowIt(s, x.q, shown[s].at, Piece(x.q, 0), Piece(x.q, 1))
            ELSE UNCHANGED <<shown, back, unheld>>
    /\ UNCHANGED <<rf, lease, cnt, nf, zf, wout, writes>>

Init ==
    /\ EnvInit(Z, I0)
    /\ rf = [s \in Servers |-> RF0]
    /\ lease = [s \in Servers |-> NoLease]
    /\ cnt = [s \in Servers |-> InitCount]
    /\ tk = [s \in Servers |-> TK0]
    /\ nf = [s \in Servers |-> 1]
    /\ zf = [s \in Servers |-> FALSE]
    /\ shown = [s \in Servers |-> [q |-> -1, at |-> -100]]
    /\ wout = 0 /\ writes = 0 /\ back = FALSE /\ unheld = FALSE

EnvStep == EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<rf, lease, cnt, tk, nf, zf, shown, wout, writes, back, unheld>>

Next ==
    \/ EnvStep
    \/ \E s \in Servers : /\ Crash(s)
                          /\ rf' = [rf EXCEPT ![s] = RF0]
                          /\ lease' = [lease EXCEPT ![s] = NoLease]
                          /\ cnt' = [cnt EXCEPT ![s] = 1]
                          /\ tk' = [tk EXCEPT ![s] = TK0]
                          /\ nf' = [nf EXCEPT ![s] = 1]
                          /\ zf' = [zf EXCEPT ![s] = FALSE]
                          /\ shown' = [shown EXCEPT ![s] = [q |-> -1, at |-> -100]]
                          /\ wout' = IF s = "A" THEN 0 ELSE wout
                          /\ UNCHANGED <<writes, back, unheld>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<rf, lease, cnt, tk, nf, zf, shown, wout, writes, back, unheld>>
    \/ WriteK \/ HearWrite
    \/ \E s \in Servers : RefreshStart(s) \/ RefreshRead(s) \/ RefreshSend(s) \/ RefreshPart(s) \/ RefreshHead(s)
                          \/ RefreshCold(s) \/ RefreshColdRead(s)
                          \/ TickStart(s) \/ TickHead(s) \/ TickSend(s) \/ TickPart(s) \/ TickCold(s) \/ TickColdRead(s)
                          \/ KeyStart(s) \/ KeyRead(s)

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
\* Probe: a holder's count reaches 2, by growth after a failed write to a hot replica 0 (D1).
Grown == \A s \in Servers : cnt[s] < 2
=============================================================================
