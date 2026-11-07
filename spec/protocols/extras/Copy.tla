---- MODULE Copy ----
EXTENDS Env, TLC

CONSTANTS
    MaxW,
    Reps,
    Home,
    FixPartQ,
    FixOrderQ

ASSUME Reps \in {1, 2}

VARIABLES
    rf,
    lease,
    cnt,
    tk,
    nf,
    zf,
    shown,
    wout,
    writes,
    back,
    unheld

vars == <<envVars, rf, lease, cnt, tk, nf, zf, shown, wout, writes, back, unheld>>

K == "k"
Cold == "z"
Z == [ex |-> FALSE, q |-> 0]
NoLease == [q |-> -1, n |-> 0, c |-> 0]
Min(a, b) == IF a <= b THEN a ELSE b
Holders == Servers
Followers == Servers
InitCount == 1
Piece(q, j) == <<q, j>>

HeaderItem(r) == IF r = 0 THEN "h" ELSE "g"
Slot(r, q) == IF r = 0 THEN (IF q % 2 = 0 THEN <<"a0", "a1">> ELSE <<"b0", "b1">>)
              ELSE (IF q % 2 = 0 THEN <<"c0", "c1">> ELSE <<"d0", "d1">>)

NoPart == [q |-> -1, d |-> <<-1, -1>>]
NoHead == [q |-> -1, at |-> -100, p |-> 0, n |-> 0, c |-> 0]
I0 == [q |-> -1, at |-> -100, p |-> 0, d |-> <<-1, -1>>, n |-> 0, c |-> 0]

Order(n) == IF n = 1 THEN <<0>> ELSE <<1, 0>>

Tf(c, v) == WriteNote([ex |-> TRUE, q |-> v.q + 1], c.arg)

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

SetPart(s, r, q, j) == MsIssueSet(s, Slot(r, q)[j], [w |-> TRUE], Item([I0 EXCEPT !.q = q, !.d = Piece(q, j - 1)], MaxExpiry))

RefreshStart(s) ==
    /\ s \in Holders
    /\ rf[s].ph = ""
    /\ IssueGet(s, K, [w |-> FALSE])
    /\ rf' = [rf EXCEPT ![s] = [RF0 EXCEPT !.ph = "read", !.r = NextReq]]
    /\ UNCHANGED <<lease, cnt, tk, nf, zf, shown, wout, writes, back, unheld>>

Push(q, n) == [RF0 EXCEPT !.ph = "parts", !.q = q, !.n = n, !.c = n, !.todo = Order(n), !.j = 1]

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

RefreshSend(s) ==
    /\ rf[s].ph \in {"parts", "head"} /\ rf[s].r = 0
    /\ LET rep == Head(rf[s].todo) IN
       IF rf[s].ph = "parts"
       THEN SetPart(s, rep, rf[s].q, rf[s].j)
       ELSE MsIssue(s, HeaderItem(rep), [q |-> rf[s].q, at |-> rf[s].at, n |-> rf[s].n, c |-> rf[s].c, ren |-> rf[s].ren],
                    MaxExpiry)
    /\ rf' = [rf EXCEPT ![s].r = NextMsReq]
    /\ UNCHANGED <<lease, cnt, tk, nf, zf, shown, wout, writes, back, unheld>>

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

Newer(s, h) == IF FixOrderQ THEN h.q > shown[s].q ELSE h.at > shown[s].at
Showable(s, h) == IF FixOrderQ THEN h.q >= shown[s].q ELSE h.at >= shown[s].at
HomeOf(s) == Home[s] % Max(nf[s], 1)

TickStart(s) ==
    /\ s \in Followers
    /\ tk[s].ph = ""
    /\ LET r == IF zf[s] THEN 0 ELSE HomeOf(s) IN
       /\ MsIssueGet(s, HeaderItem(r), [w |-> FALSE])
       /\ tk' = [tk EXCEPT ![s] = [TK0 EXCEPT !.ph = "head", !.r = NextMsReq, !.rep = r]]
    /\ zf' = [zf EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<rf, lease, cnt, nf, shown, wout, writes, back, unheld>>

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

TickSend(s) ==
    /\ tk[s].ph = "parts" /\ tk[s].r = 0
    /\ MsIssueGet(s, Slot(tk[s].rep, tk[s].h.q)[tk[s].j], [w |-> FALSE])
    /\ tk' = [tk EXCEPT ![s].r = NextMsReq]
    /\ UNCHANGED <<rf, lease, cnt, nf, zf, shown, wout, writes, back, unheld>>

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
               ELSE IF ~Showable(s, h)
               THEN /\ tk' = [tk EXCEPT ![s] = [TK0 EXCEPT !.ph = "down"]]
                    /\ UNCHANGED <<zf, shown, back, unheld>>
               ELSE /\ tk' = [tk EXCEPT ![s] = TK0]
                    /\ UNCHANGED zf
                    /\ ShowIt(s, h.q, h.at, got[1].d, got[2].d)
    /\ UNCHANGED <<rf, lease, cnt, nf, wout, writes>>

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
ShownLate == \A s \in Servers : shown[s].q < 2
ReadFromCopy == ~\E s \in Servers : tk[s].ph = "parts" /\ tk[s].j = 2
ReadFromReplica == ~\E s \in Servers : tk[s].ph = "parts" /\ tk[s].rep = 1 /\ tk[s].j = 2
HeaderMerge(r) == mreq[r].kind = "upd" /\ mreq[r].ph = "applied" /\ mreq[r].seen.has
OneHolder == \A x, y \in DOMAIN mreq :
    (mreq[x].key = "h" /\ mreq[y].key = "h" /\ mreq[x].kind = "upd" /\ mreq[y].kind = "upd") => mreq[x].srv = mreq[y].srv
MergesNewer == ~(OneHolder /\ \E r \in DOMAIN mreq : HeaderMerge(r) /\ mreq[r].arg.q > mreq[r].seen.v.q)
MergesSmallerN == ~(OneHolder /\ \E r \in DOMAIN mreq : HeaderMerge(r) /\ mreq[r].arg.n < mreq[r].seen.v.n)
Renewed == ~\E r \in DOMAIN mreq : mreq[r].kind = "upd" /\ "ren" \in DOMAIN mreq[r].arg /\ mreq[r].arg.ren
                                   /\ mreq[r].ans = "ok"
WentDown == ~(OneHolder /\ \E s \in Servers : tk[s].ph = "down")
Grown == \A s \in Servers : cnt[s] < 2
====
