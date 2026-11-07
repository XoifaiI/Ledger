---- MODULE Env ----
EXTENDS Integers, Sequences, FiniteSets

Env_typedefs == TRUE

CONSTANTS
    Servers,
    Keys,
    MKeys,
    MaxReqs,
    MaxMsReqs,
    MaxTime,
    MaxSkew,
    MaxFaults,
    FailBefore,
    LoseAnswer,
    LoseCommit,
    LateLand,
    DsSplit,
    DsOutage,
    Reverts,
    Crashes,
    Shutdowns,
    ClockJumps,
    ClockSteps,
    MsFail,
    MsMaybe,
    MsVanish,
    MsEvict,
    MsOutage,
    MsSplit,
    StaleGet,
    StaleRun,
    StaleList,
    MsStale,
    RunAfterAnswer,
    KeyInfo,
    MsOn,
    Budgets,
    LagAfterCalm,
    DelayAfterCalm,
    SkewAfterCalm,
    MaxBudget,
    BudgetAfterCalm,
    LifeAfterCalm,
    MaxExpiry

VARIABLES
    hist,
    upd,
    curAt,
    ver,
    ext,
    req,
    up,
    inc,
    now,
    skew,
    calm,
    calmAt,
    faults,
    dsReach,
    lst,
    ms,
    msPrev,
    msVer,
    msAt,
    mreq,
    msReach,
    msZero,
    bud

envVars == <<hist, upd, curAt, ver, ext, req, up, inc, now, skew, calm, calmAt, faults, dsReach,
             lst, ms, msPrev, msVer, msAt, mreq, msReach, msZero, bud>>
store == <<hist, upd, curAt, ver, ext>>
host == <<up, inc, now, skew>>
servers == <<host, bud>>
settle == <<calm, calmAt>>
access == <<dsReach, lst>>
mslots == <<ms, msPrev, msVer, msAt>>
memory == <<mslots, mreq, msReach, msZero>>

ASSUME EnvConstants ==
    /\ MaxReqs \in Nat /\ MaxMsReqs \in Nat /\ MaxTime \in Nat /\ MaxSkew \in Nat
    /\ MaxFaults \in Nat
    /\ FailBefore \in BOOLEAN /\ LoseAnswer \in BOOLEAN /\ LoseCommit \in BOOLEAN
    /\ LateLand \in BOOLEAN /\ DsSplit \in BOOLEAN /\ DsOutage \in BOOLEAN /\ Reverts \in BOOLEAN
    /\ Crashes \in BOOLEAN /\ Shutdowns \in BOOLEAN /\ ClockJumps \in BOOLEAN
    /\ ClockSteps \in BOOLEAN
    /\ MsFail \in BOOLEAN /\ MsMaybe \in BOOLEAN /\ MsVanish \in BOOLEAN
    /\ MsOutage \in BOOLEAN /\ MsSplit \in BOOLEAN
    /\ StaleGet \in BOOLEAN /\ StaleRun \in BOOLEAN /\ StaleList \in BOOLEAN
    /\ MsStale \in BOOLEAN /\ RunAfterAnswer \in BOOLEAN /\ KeyInfo \in BOOLEAN
    /\ MsOn \in BOOLEAN /\ MsEvict \in BOOLEAN /\ Budgets \in BOOLEAN
    /\ LagAfterCalm \in Nat /\ DelayAfterCalm \in Nat
    /\ SkewAfterCalm \in Nat /\ SkewAfterCalm <= MaxSkew
    /\ MaxBudget \in Nat /\ BudgetAfterCalm \in 0..MaxBudget
    /\ LifeAfterCalm \in Nat /\ MaxExpiry \in Nat

MaxVers == 2 * MaxReqs + MaxFaults

Phases == {"sent", "ran", "cancel", "landed", "read", "gone"}
MsPhases == {"sent", "ran", "cancel", "threw", "read", "applied", "gone"}
Runs == {"none", "write", "cancel"}
MsRuns == Runs \cup {"throw"}
Heard == {"ok", "nil", "err"}
MsHeard == {"ok", "nil", "err"}
ListHeard == {"ok", "end", "err"}

NoStamp == -1

Max(a, b) == IF a >= b THEN a ELSE b

Faulty == ~calm /\ faults < MaxFaults

Up(s) == up[s]

Clock(s) == now + skew[s]

Job(s) == <<s, inc[s]>>

SkewRange == IF calm THEN -SkewAfterCalm..SkewAfterCalm ELSE -MaxSkew..MaxSkew

Cur(k) == hist[k][ver[k]]

Absent(k, x) == x = hist[k][0]

Write(c, x) == [w |-> TRUE, v |-> x, n |-> c.arg]

Cancel(c, x) == [w |-> FALSE, v |-> x, n |-> c.arg]

WriteNote(x, m) == [w |-> TRUE, v |-> x, n |-> m]

CancelNote(x, m) == [w |-> FALSE, v |-> x, n |-> m]

MsWrite(c, x) == [w |-> TRUE, v |-> x, n |-> c.arg, t |-> FALSE]

MsCancel(c, it) == [w |-> FALSE, v |-> it.v, n |-> c.arg, t |-> FALSE]

MsWriteNote(x, m) == [w |-> TRUE, v |-> x, n |-> m, t |-> FALSE]

MsCancelNote(it, m) == [w |-> FALSE, v |-> it.v, n |-> m, t |-> FALSE]

MsThrow(c) == [w |-> FALSE, v |-> msZero, n |-> c.arg, t |-> TRUE]

MsThrowNote(m) == [w |-> FALSE, v |-> msZero, n |-> m, t |-> TRUE]

NextReq == Len(req) + 1
NextMsReq == Len(mreq) + 1

Waiting(s, r) ==
    /\ r \in DOMAIN req
    /\ req[r].srv = s
    /\ req[r].inc = inc[s]
    /\ req[r].ans = "none"

MsWaiting(s, r) ==
    /\ r \in DOMAIN mreq
    /\ mreq[r].srv = s
    /\ mreq[r].inc = inc[s]
    /\ mreq[r].ans = "none"

SetOut(s, k) == \E r \in DOMAIN req : req[r].kind = "set" /\ req[r].key = k /\ Waiting(s, r)

BudgetTypes == {"read", "write", "list", "remove"}

Budget(s, t) == bud[s][t]

BudFull == [s \in Servers |-> [t \in BudgetTypes |-> MaxBudget]]

BudFloor == IF calm THEN BudgetAfterCalm ELSE 0

Spend(s, ts) ==
    IF Budgets
    THEN [bud EXCEPT ![s] = [t \in BudgetTypes |-> IF t \in ts THEN Max(bud[s][t] - 1, 0) ELSE bud[s][t]]]
    ELSE bud

TfOf(r) == req[req[r].clo].tf
SeenOf(r) == req[req[r].clo].seen
NoteOf(r) == req[req[r].clo].note

ReadOf(r) == [v |-> req[r].seen, u |-> req[r].u]

Vers(k) == {i \in 0..MaxVers : i <= ver[k]}

Written == {k \in Keys : ver[k] > 0}

Age(t) == now - Max(t, calmAt)

Lagged(k) ==
    {i \in Vers(k) : \/ i = ver[k]
                     \/ ~calm
                     \/ i < ver[k] /\ curAt[k][i + 1] > now - LagAfterCalm}

Overdue(r) ==
    /\ calm
    /\ Waiting(req[r].srv, r)
    /\ \/ req[r].kind \in {"upd", "set"} /\ req[r].ph \in {"sent", "ran"}
       \/ req[r].kind = "get" /\ req[r].ph = "sent"
       \/ req[r].ph \in {"landed", "cancel", "read"}
    /\ Age(req[r].at) >= DelayAfterCalm

RunVers(r) == IF StaleRun /\ ~Overdue(r) THEN Lagged(req[r].key) ELSE {ver[req[r].key]}

GetVers(r) == IF StaleGet /\ ~Overdue(r) THEN Lagged(req[r].key) ELSE {ver[req[r].key]}

Stamps(k, x) == IF Absent(k, x) THEN {NoStamp} ELSE IF KeyInfo THEN 0..MaxTime ELSE {0}

Live(sl) == sl.has /\ now < sl.exp

ShowAt(sl, t) == [has |-> sl.has /\ t < sl.exp, v |-> IF sl.has /\ t < sl.exp THEN sl.v ELSE msZero]

Show(sl) == ShowAt(sl, now)

MsView(mk) == Show(ms[mk])

MsPrevView(mk) == ShowAt(msPrev[mk], msAt[mk])

MsLagged(mk) == MsStale /\ msVer[mk] > 0 /\ (~calm \/ msAt[mk] > now - LagAfterCalm)

MsExpiredLag(mk) ==
    /\ MsStale
    /\ ms[mk].has
    /\ msAt[mk] < ms[mk].exp
    /\ ms[mk].exp <= now
    /\ \/ ~calm
       \/ ms[mk].exp > now - LagAfterCalm

MsNow(mk) == [it |-> MsView(mk), cur |-> TRUE, rv |-> msVer[mk]]

MsLooks(mk) ==
    {MsNow(mk)}
    \cup (IF MsLagged(mk) THEN {[it |-> MsPrevView(mk), cur |-> FALSE, rv |-> msVer[mk] - 1]} ELSE {})
    \cup (IF MsExpiredLag(mk) THEN {[it |-> ShowAt(ms[mk], msAt[mk]), cur |-> FALSE, rv |-> msVer[mk]]} ELSE {})

MsReads(mk) == {l.it : l \in MsLooks(mk)}

Item(x, t) == [has |-> TRUE, v |-> x, ttl |-> t]

NoItem == [has |-> FALSE, v |-> msZero, ttl |-> 0]

Gone == [has |-> FALSE, v |-> msZero, exp |-> 0]

Stored(p) == [has |-> p.has, v |-> IF p.has THEN p.v ELSE msZero, exp |-> now + p.ttl]

MsOverdue(r) ==
    /\ calm
    /\ MsWaiting(mreq[r].srv, r)
    /\ Age(mreq[r].at) >= DelayAfterCalm

NoWalk == [on |-> FALSE, ex |-> FALSE, from |-> {}, got |-> {}, ask |-> FALSE, at |-> 0,
           read |-> FALSE, page |-> {}, end |-> FALSE, skip |-> {}, passed |-> {}]

ListOverdue(s) ==
    /\ calm
    /\ up[s]
    /\ lst[s].ask
    /\ Age(lst[s].at) >= DelayAfterCalm

EnvInit(z, zi) ==
    /\ hist = [k \in Keys |-> [i \in 0..MaxVers |-> z]]
    /\ upd = [k \in Keys |-> [i \in 0..MaxVers |-> NoStamp]]
    /\ curAt = [k \in Keys |-> [i \in 0..MaxVers |-> 0]]
    /\ ver = [k \in Keys |-> 0]
    /\ ext = [k \in Keys |-> 0]
    /\ req = <<>>
    /\ up = [s \in Servers |-> TRUE]
    /\ inc = [s \in Servers |-> 0]
    /\ now = 0
    /\ skew \in [Servers -> -MaxSkew..MaxSkew]
    /\ calm = FALSE
    /\ calmAt = 0
    /\ faults = 0
    /\ dsReach = [s \in Servers |-> TRUE]
    /\ lst = [s \in Servers |-> NoWalk]
    /\ ms = [mk \in MKeys |-> [has |-> FALSE, v |-> zi, exp |-> 0]]
    /\ msPrev = [mk \in MKeys |-> [has |-> FALSE, v |-> zi, exp |-> 0]]
    /\ msVer = [mk \in MKeys |-> 0]
    /\ msAt = [mk \in MKeys |-> 0]
    /\ mreq = <<>>
    /\ msReach = [s \in Servers |-> MsOn]
    /\ msZero = zi
    /\ IF Budgets THEN bud \in [Servers -> [BudgetTypes -> 0..MaxBudget]] ELSE bud = BudFull

NewCall(s, k, a, kind, ph, x, c) ==
    [srv |-> s, inc |-> inc[s], key |-> k, kind |-> kind, arg |-> a, at |-> now,
     ph |-> ph, rv |-> -1, tf |-> "none", seen |-> hist[k][0], note |-> a,
     res |-> x, ans |-> "none", clo |-> c, by |-> 0, u |-> NoStamp, made |-> {}]

Issue(s, k, a) ==
    /\ up[s]
    /\ Len(req) < MaxReqs
    /\ req' = Append(req, NewCall(s, k, a, "upd", "sent", hist[k][0], NextReq))
    /\ bud' = Spend(s, {"read", "write"})
    /\ UNCHANGED <<store, host, settle, faults, access, memory>>

IssueAgain(s, r, a) ==
    /\ up[s]
    /\ Len(req) < MaxReqs
    /\ r \in DOMAIN req
    /\ req[r].srv = s
    /\ req[r].inc = inc[s]
    /\ req[r].kind = "upd"
    /\ req' = Append(req, NewCall(s, req[r].key, a, "upd", "sent", hist[req[r].key][0], req[r].clo))
    /\ bud' = Spend(s, {"read", "write"})
    /\ UNCHANGED <<store, host, settle, faults, access, memory>>

IssueSet(s, k, a, x) ==
    /\ up[s]
    /\ Len(req) < MaxReqs
    /\ req' = Append(req, NewCall(s, k, a, "set", "ran", x, NextReq))
    /\ bud' = Spend(s, IF Absent(k, x) THEN {"remove"} ELSE {"write"})
    /\ UNCHANGED <<store, host, settle, faults, access, memory>>

IssueGet(s, k, a) ==
    /\ up[s]
    /\ Len(req) < MaxReqs
    /\ req' = Append(req, NewCall(s, k, a, "get", "sent", hist[k][0], NextReq))
    /\ bud' = Spend(s, {"read"})
    /\ UNCHANGED <<store, host, settle, faults, access, memory>>

LatePhases(q) ==
    (IF LoseAnswer /\ q.ph = "landed" THEN {"landed"} ELSE {})
    \cup (IF (LateLand \/ (RunAfterAnswer /\ q.kind = "upd")) /\ q.ph = "ran" THEN {"ran"} ELSE {})
    \cup (IF RunAfterAnswer /\ q.kind = "upd" /\ q.ph = "sent" THEN {"sent"} ELSE {})

ErrPhases(q) ==
    (IF FailBefore /\ q.ph \in {"sent", "ran", "cancel", "read"} THEN {"gone"} ELSE {})
    \cup LatePhases(q)

CutPhases(q) ==
    (IF q.ph \in {"sent", "ran", "cancel", "read"} THEN {"gone"} ELSE {}) \cup LatePhases(q)

Reply(r, a) ==
    /\ r \in DOMAIN req
    /\ LET q == req[r] IN
       /\ Waiting(q.srv, r)
       /\ up[q.srv]
       /\ \/ /\ a = "ok"
             /\ q.ph \in {"landed", "read"}
             /\ req' = [req EXCEPT ![r].ans = "ok"]
             /\ UNCHANGED faults
          \/ /\ a = "nil"
             /\ q.ph = "cancel"
             /\ req' = [req EXCEPT ![r].ans = "nil"]
             /\ UNCHANGED faults
          \/ /\ a = "err"
             /\ Faulty
             /\ \E p \in ErrPhases(q) :
                   req' = [req EXCEPT ![r].ans = "err", ![r].ph = p]
             /\ faults' = faults + 1
          \/ /\ a = "err"
             /\ ~dsReach[q.srv]
             /\ \E p \in CutPhases(q) :
                   req' = [req EXCEPT ![r].ans = "err", ![r].ph = p]
             /\ UNCHANGED faults
    /\ UNCHANGED <<store, servers, settle, access, memory>>

ListStart(s, ex) ==
    /\ up[s]
    /\ lst' = [lst EXCEPT ![s] = [NoWalk EXCEPT !.on = TRUE, !.ex = ex,
                                  !.from = {k \in Written : ~ex \/ ~Absent(k, Cur(k))}]]
    /\ UNCHANGED <<store, req, servers, settle, faults, dsReach, memory>>

ListAsk(s) ==
    /\ up[s]
    /\ lst[s].on
    /\ ~lst[s].ask
    /\ lst' = [lst EXCEPT ![s].ask = TRUE, ![s].at = now, ![s].read = FALSE, ![s].page = {},
                          ![s].end = FALSE, ![s].skip = {}]
    /\ bud' = Spend(s, {"list"})
    /\ UNCHANGED <<store, req, host, settle, faults, dsReach, memory>>

ListVers(s, k) == IF StaleList /\ ~ListOverdue(s) THEN Lagged(k) ELSE {ver[k]}

Missable(s, k) ==
    IF lst[s].ex
    THEN \E i \in ListVers(s, k) : Absent(k, hist[k][i])
    ELSE StaleList /\ 0 \in ListVers(s, k)

ListDone(s) == \A k \in lst[s].from \ (lst[s].got \cup lst[s].passed) : Missable(s, k)

Passes(s) == {k \in lst[s].from \ lst[s].got : Missable(s, k)}

Listable(s, k) ==
    /\ k \in Written \ lst[s].got
    /\ \/ ~lst[s].ex
       \/ k \in lst[s].from
       \/ \E i \in ListVers(s, k) : ~Absent(k, hist[k][i])

ListPage(s, k, a) ==
    /\ up[s]
    /\ lst[s].ask
    /\ \/ /\ a = "ok"
          /\ lst[s].read
          /\ k \in lst[s].page
          /\ lst' = [lst EXCEPT ![s].got = @ \cup {k}, ![s].ask = FALSE, ![s].read = FALSE,
                                ![s].page = {}, ![s].passed = @ \cup lst[s].skip, ![s].skip = {}]
          /\ UNCHANGED faults
       \/ /\ a = "end"
          /\ lst[s].read
          /\ lst[s].end
          /\ lst' = [lst EXCEPT ![s] = NoWalk]
          /\ UNCHANGED faults
       \/ /\ a = "err"
          /\ \/ ~dsReach[s] /\ UNCHANGED faults
             \/ FailBefore /\ Faulty /\ faults' = faults + 1
          /\ lst' = [lst EXCEPT ![s].ask = FALSE, ![s].read = FALSE, ![s].page = {},
                                ![s].end = FALSE, ![s].skip = {}]
    /\ UNCHANGED <<store, req, servers, settle, dsReach, memory>>

Run(r, Tf(_, _)) ==
    /\ r \in DOMAIN req
    /\ LET q == req[r]
           c == q.clo IN
       /\ q.kind = "upd"
       /\ up[q.srv]
       /\ \/ Waiting(q.srv, r) /\ q.ph \in {"sent", "ran"} /\ UNCHANGED faults
          \/ /\ LoseCommit /\ Faulty
             /\ Waiting(q.srv, r) /\ q.ph = "landed" /\ Cardinality(q.made) = 1
             /\ faults' = faults + 1
          \/ /\ RunAfterAnswer
             /\ q.ans = "err"
             /\ q.inc = inc[q.srv]
             /\ q.ph \in {"sent", "ran", "landed"}
             /\ q.ph = "landed" => Cardinality(q.made) = 1
             /\ UNCHANGED faults
       /\ \E i \in RunVers(r) :
             LET o == Tf([srv |-> q.srv, arg |-> q.arg, note |-> req[c].note,
                          info |-> upd[q.key][i]],
                         hist[q.key][i])
                 w == o.w IN
             req' = [req EXCEPT ![r].ph = IF w THEN "ran" ELSE "cancel",
                                ![r].rv = i,
                                ![r].res = o.v,
                                ![c].tf = IF w THEN "write" ELSE "cancel",
                                ![c].seen = hist[q.key][i],
                                ![c].note = o.n,
                                ![c].by = r]
    /\ UNCHANGED <<store, servers, settle, access, memory>>

Land(r) ==
    /\ r \in DOMAIN req
    /\ LET q == req[r]
           n == ver[q.key] + 1 IN
       /\ q.ph = "ran"
       /\ q.kind = "set" \/ q.rv = ver[q.key]
       /\ ver[q.key] < MaxVers
       /\ LateLand \/ (Waiting(q.srv, r) /\ up[q.srv])
       /\ ver' = [ver EXCEPT ![q.key] = n]
       /\ hist' = [hist EXCEPT ![q.key][n] = q.res]
       /\ curAt' = [curAt EXCEPT ![q.key][n] = now]
       /\ \E u \in Stamps(q.key, q.res) :
             /\ upd' = [upd EXCEPT ![q.key][n] = u]
             /\ req' = [req EXCEPT ![r].ph = "landed", ![r].u = u, ![r].made = @ \cup {n}]
    /\ UNCHANGED <<ext, servers, settle, faults, access, memory>>

Fetch(r) ==
    /\ r \in DOMAIN req
    /\ LET q == req[r] IN
       /\ q.kind = "get"
       /\ q.ph = "sent"
       /\ Waiting(q.srv, r)
       /\ up[q.srv]
       /\ \E i \in GetVers(r) :
             req' = [req EXCEPT ![r].ph = "read", ![r].rv = i, ![r].seen = hist[q.key][i],
                                ![r].u = upd[q.key][i]]
    /\ UNCHANGED <<store, servers, settle, faults, access, memory>>

ListFetch(s) ==
    /\ up[s]
    /\ lst[s].ask
    /\ ~lst[s].read
    /\ \/ \E k \in Keys :
             /\ Listable(s, k)
             /\ lst' = [lst EXCEPT ![s].read = TRUE, ![s].page = {k}, ![s].skip = Passes(s) \ {k}]
       \/ ListDone(s) /\ lst' = [lst EXCEPT ![s].read = TRUE, ![s].end = TRUE]
    /\ UNCHANGED <<store, req, servers, settle, faults, dsReach, memory>>

Revert(k) ==
    /\ Reverts
    /\ Faulty
    /\ ver[k] < MaxVers
    /\ \E i \in Vers(k) \ {ver[k]} :
          \E u \in Stamps(k, hist[k][i]) :
             /\ hist' = [hist EXCEPT ![k][ver[k] + 1] = hist[k][i]]
             /\ upd' = [upd EXCEPT ![k][ver[k] + 1] = u]
    /\ curAt' = [curAt EXCEPT ![k][ver[k] + 1] = now]
    /\ ver' = [ver EXCEPT ![k] = @ + 1]
    /\ ext' = [ext EXCEPT ![k] = @ + 1]
    /\ faults' = faults + 1
    /\ UNCHANGED <<req, servers, settle, access, memory>>

DsCut(s) ==
    /\ DsSplit
    /\ Faulty
    /\ dsReach[s]
    /\ dsReach' = [dsReach EXCEPT ![s] = FALSE]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, servers, settle, lst, memory>>

DsDown ==
    /\ DsOutage
    /\ Faulty
    /\ \E s \in Servers : dsReach[s]
    /\ dsReach' = [s \in Servers |-> FALSE]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, servers, settle, lst, memory>>

DsMend ==
    /\ \E s \in Servers : ~dsReach[s]
    /\ dsReach' = [s \in Servers |-> TRUE]
    /\ UNCHANGED <<store, req, servers, settle, faults, lst, memory>>

Crash(s) ==
    /\ up[s]
    /\ Crashes
    /\ Faulty
    /\ up' = [up EXCEPT ![s] = FALSE]
    /\ inc' = [inc EXCEPT ![s] = @ + 1]
    /\ lst' = [lst EXCEPT ![s] = NoWalk]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, now, skew, bud, settle, dsReach, memory>>

CrashAll ==
    /\ Shutdowns
    /\ Faulty
    /\ \E s \in Servers : up[s]
    /\ up' = [s \in Servers |-> FALSE]
    /\ inc' = [s \in Servers |-> IF up[s] THEN inc[s] + 1 ELSE inc[s]]
    /\ lst' = [s \in Servers |-> NoWalk]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, now, skew, bud, settle, dsReach, memory>>

Restart(s) ==
    /\ ~up[s]
    /\ up' = [up EXCEPT ![s] = TRUE]
    /\ \E d \in SkewRange : skew' = [skew EXCEPT ![s] = d]
    /\ IF Budgets
       THEN \E f \in [BudgetTypes -> 0..MaxBudget] :
               /\ \A t \in BudgetTypes : f[t] >= BudFloor
               /\ bud' = [bud EXCEPT ![s] = f]
       ELSE UNCHANGED bud
    /\ UNCHANGED <<store, req, inc, now, settle, faults, access, memory>>

Tick(Hold) ==
    /\ now < MaxTime
    /\ ~(calm /\ Hold)
    /\ ~\E r \in DOMAIN req : Overdue(r)
    /\ ~\E r \in DOMAIN mreq : MsOverdue(r)
    /\ ~\E s \in Servers : ListOverdue(s)
    /\ now' = now + 1
    /\ IF Budgets
       THEN \E b \in [Servers -> [BudgetTypes -> 0..MaxBudget]] :
               /\ \A s \in Servers, t \in BudgetTypes : b[s][t] >= Max(bud[s][t], BudFloor)
               /\ bud' = b
       ELSE UNCHANGED bud
    /\ UNCHANGED <<store, req, up, inc, skew, settle, faults, access, memory>>

BudgetDrop(s) ==
    /\ Budgets
    /\ \E t \in BudgetTypes, n \in 0..MaxBudget :
          /\ BudFloor <= n /\ n < bud[s][t]
          /\ bud' = [bud EXCEPT ![s][t] = n]
    /\ UNCHANGED <<store, req, host, settle, faults, access, memory>>

Jump(s) ==
    /\ ClockJumps
    /\ Faulty
    /\ \E d \in SkewRange \ {skew[s]} : skew' = [skew EXCEPT ![s] = d]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, up, inc, now, bud, settle, access, memory>>

ClockStep(s) ==
    /\ ClockSteps
    /\ up[s]
    /\ \E d \in SkewRange \ {skew[s]} : skew' = [skew EXCEPT ![s] = d]
    /\ UNCHANGED <<store, req, up, inc, now, bud, settle, faults, access, memory>>

Heal ==
    /\ ~calm
    /\ calm' = TRUE
    /\ calmAt' = now
    /\ dsReach' = [s \in Servers |-> TRUE]
    /\ msReach' = [s \in Servers |-> MsOn]
    /\ \E f \in [Servers -> -SkewAfterCalm..SkewAfterCalm] :
          skew' = [s \in Servers |->
                     IF skew[s] \in -SkewAfterCalm..SkewAfterCalm THEN skew[s] ELSE f[s]]
    /\ bud' = IF Budgets
             THEN [s \in Servers |-> [t \in BudgetTypes |-> Max(bud[s][t], BudgetAfterCalm)]]
             ELSE bud
    /\ UNCHANGED <<store, req, up, inc, now, faults, lst, mslots, mreq, msZero>>

NewMsCall(s, mk, a, kind, ph, p, t) ==
    [srv |-> s, inc |-> inc[s], key |-> mk, kind |-> kind, arg |-> a, ttl |-> t, at |-> now,
     ph |-> ph, rv |-> -1, cur |-> FALSE, tf |-> "none",
     seen |-> [has |-> FALSE, v |-> msZero], note |-> a, res |-> p, ans |-> "none", made |-> 0]

MsIssue(s, mk, a, t) ==
    /\ up[s]
    /\ t >= 0
    /\ Len(mreq) < MaxMsReqs
    /\ mreq' = Append(mreq, NewMsCall(s, mk, a, "upd", "sent", NoItem, t))
    /\ UNCHANGED <<store, req, servers, settle, faults, access, mslots, msReach, msZero>>

MsIssueSet(s, mk, a, p) ==
    /\ up[s]
    /\ Len(mreq) < MaxMsReqs
    /\ mreq' = Append(mreq, NewMsCall(s, mk, a, "set", "ran", p, p.ttl))
    /\ UNCHANGED <<store, req, servers, settle, faults, access, mslots, msReach, msZero>>

MsIssueGet(s, mk, a) ==
    /\ up[s]
    /\ Len(mreq) < MaxMsReqs
    /\ mreq' = Append(mreq, NewMsCall(s, mk, a, "get", "sent", NoItem, 0))
    /\ UNCHANGED <<store, req, servers, settle, faults, access, mslots, msReach, msZero>>

MsLatePhases(q) ==
    (IF MsMaybe /\ q.ph \in {"applied", "ran"} THEN {q.ph} ELSE {})
    \cup (IF RunAfterAnswer /\ q.kind = "upd" /\ q.ph \in {"sent", "ran"} THEN {q.ph} ELSE {})

MsErrPhases(q) ==
    (IF MsFail /\ q.ph \in {"sent", "ran", "cancel", "read"} THEN {"gone"} ELSE {})
    \cup MsLatePhases(q)

MsCutPhases(q) ==
    (IF q.ph \in {"sent", "ran", "cancel", "read"} THEN {"gone"} ELSE {}) \cup MsLatePhases(q)

MsReply(r, a) ==
    /\ r \in DOMAIN mreq
    /\ LET q == mreq[r] IN
       /\ MsWaiting(q.srv, r)
       /\ up[q.srv]
       /\ \/ /\ a = "ok"
             /\ msReach[q.srv]
             /\ q.ph \in {"applied", "read"}
             /\ mreq' = [mreq EXCEPT ![r].ans = "ok"]
             /\ UNCHANGED faults
          \/ /\ a = "nil"
             /\ msReach[q.srv]
             /\ q.ph = "cancel"
             /\ mreq' = [mreq EXCEPT ![r].ans = "nil"]
             /\ UNCHANGED faults
          \/ /\ a = "err"
             /\ msReach[q.srv]
             /\ Faulty
             /\ \E p \in MsErrPhases(q) :
                   mreq' = [mreq EXCEPT ![r].ans = "err", ![r].ph = p]
             /\ faults' = faults + 1
          \/ /\ a = "err"
             /\ ~msReach[q.srv]
             /\ \E p \in MsCutPhases(q) :
                   mreq' = [mreq EXCEPT ![r].ans = "err", ![r].ph = p]
             /\ UNCHANGED faults
          \/ /\ a = "err"
             /\ q.ph = "threw"
             /\ mreq' = [mreq EXCEPT ![r].ans = "err", ![r].ph = "gone"]
             /\ UNCHANGED faults
          \/ /\ a = "err"
             /\ q.ttl > MaxExpiry
             /\ mreq' = [mreq EXCEPT ![r].ans = "err", ![r].ph = "gone"]
             /\ UNCHANGED faults
    /\ UNCHANGED <<store, req, servers, settle, access, mslots, msReach, msZero>>

MsRun(r, MsTf(_, _)) ==
    /\ r \in DOMAIN mreq
    /\ LET q == mreq[r] IN
       /\ q.kind \in {"upd", "get"}
       /\ q.ttl <= MaxExpiry
       /\ up[q.srv]
       /\ msReach[q.srv]
       /\ \/ /\ q.ph = "sent" \/ (q.kind = "upd" /\ q.ph = "ran")
             /\ \/ MsWaiting(q.srv, r)
                \/ RunAfterAnswer /\ q.kind = "upd" /\ q.ans = "err" /\ q.inc = inc[q.srv]
             /\ UNCHANGED faults
          \/ /\ LoseCommit /\ Faulty
             /\ q.kind = "upd" /\ q.ph = "applied" /\ q.made = 1
             /\ MsWaiting(q.srv, r)
             /\ faults' = faults + 1
          \/ /\ RunAfterAnswer
             /\ q.kind = "upd" /\ q.ph = "applied" /\ q.made = 1
             /\ q.ans = "err" /\ q.inc = inc[q.srv]
             /\ UNCHANGED faults
       /\ \E l \in (IF MsOverdue(r) THEN {MsNow(q.key)} ELSE MsLooks(q.key)) :
             LET o == MsTf([srv |-> q.srv, arg |-> q.arg, note |-> q.note, info |-> 0], l.it) IN
             mreq' = [mreq EXCEPT ![r] =
                        [q EXCEPT !.ph = IF q.kind = "get" THEN "read"
                                         ELSE IF o.t THEN "threw"
                                         ELSE IF o.w THEN "ran" ELSE "cancel",
                                  !.rv = l.rv,
                                  !.cur = l.cur,
                                  !.tf = IF q.kind = "get" THEN "none"
                                         ELSE IF o.t THEN "throw"
                                         ELSE IF o.w THEN "write" ELSE "cancel",
                                  !.seen = l.it,
                                  !.note = IF q.kind = "get" THEN q.note ELSE o.n,
                                  !.res = IF q.kind = "get" THEN q.res
                                          ELSE [has |-> (o.w /\ ~o.t) \/ l.it.has,
                                                v |-> IF o.t THEN l.it.v ELSE o.v,
                                                ttl |-> IF o.w /\ ~o.t THEN q.ttl ELSE 0]]]
    /\ UNCHANGED <<store, req, servers, settle, access, mslots, msReach, msZero>>

MsApply(r) ==
    /\ r \in DOMAIN mreq
    /\ LET q == mreq[r] IN
       /\ q.ph = "ran"
       /\ q.kind = "set" \/ q.rv = msVer[q.key]
       /\ q.ttl <= MaxExpiry
       /\ MsOn
       /\ \/ MsWaiting(q.srv, r) /\ up[q.srv] /\ msReach[q.srv]
          \/ MsMaybe /\ ~MsWaiting(q.srv, r)
       /\ ms' = [ms EXCEPT ![q.key] = Stored(q.res)]
       /\ msPrev' = [msPrev EXCEPT ![q.key] = ms[q.key]]
       /\ msVer' = [msVer EXCEPT ![q.key] = @ + 1]
       /\ msAt' = [msAt EXCEPT ![q.key] = now]
       /\ mreq' = [mreq EXCEPT ![r].ph = "applied", ![r].made = @ + 1]
    /\ UNCHANGED <<store, req, servers, settle, faults, access, msReach, msZero>>

MsVanishStep(mk) ==
    /\ MsVanish
    /\ Faulty
    /\ Live(ms[mk])
    /\ ms' = [ms EXCEPT ![mk] = Gone]
    /\ msPrev' = [msPrev EXCEPT ![mk] = ms[mk]]
    /\ msVer' = [msVer EXCEPT ![mk] = @ + 1]
    /\ msAt' = [msAt EXCEPT ![mk] = now]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, servers, settle, access, mreq, msReach, msZero>>

MsEvictStep(mk) ==
    /\ MsEvict
    /\ Live(ms[mk])
    /\ ~calm \/ Age(msAt[mk]) >= LifeAfterCalm
    /\ ms' = [ms EXCEPT ![mk] = Gone]
    /\ msPrev' = [msPrev EXCEPT ![mk] = ms[mk]]
    /\ msVer' = [msVer EXCEPT ![mk] = @ + 1]
    /\ msAt' = [msAt EXCEPT ![mk] = now]
    /\ UNCHANGED <<store, req, servers, settle, faults, access, mreq, msReach, msZero>>

MsDown ==
    /\ MsOutage
    /\ Faulty
    /\ \E s \in Servers : msReach[s]
    /\ msReach' = [s \in Servers |-> FALSE]
    /\ \/ UNCHANGED mslots
       \/ /\ \E mk \in MKeys : Live(ms[mk])
          /\ ms' = [mk \in MKeys |-> IF Live(ms[mk]) THEN Gone ELSE ms[mk]]
          /\ msPrev' = [mk \in MKeys |-> IF Live(ms[mk]) THEN ms[mk] ELSE msPrev[mk]]
          /\ msVer' = [mk \in MKeys |-> IF Live(ms[mk]) THEN msVer[mk] + 1 ELSE msVer[mk]]
          /\ msAt' = [mk \in MKeys |-> IF Live(ms[mk]) THEN now ELSE msAt[mk]]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, servers, settle, access, mreq, msZero>>

MsMend ==
    /\ MsOn
    /\ \E s \in Servers : ~msReach[s]
    /\ msReach' = [s \in Servers |-> TRUE]
    /\ UNCHANGED <<store, req, servers, settle, faults, access, mslots, mreq, msZero>>

MsCut(s) ==
    /\ MsSplit
    /\ Faulty
    /\ msReach[s]
    /\ msReach' = [msReach EXCEPT ![s] = FALSE]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, servers, settle, access, mslots, mreq, msZero>>

EnvNext(Tf(_, _), MsTf(_, _), Hold) ==
    \/ \E r \in DOMAIN req : Run(r, Tf) \/ Land(r) \/ Fetch(r)
    \/ \E r \in DOMAIN mreq : MsRun(r, MsTf) \/ MsApply(r)
    \/ \E s \in Servers : ListFetch(s)
    \/ \E k \in Keys : Revert(k)
    \/ Tick(Hold)
    \/ Heal
    \/ \E s \in Servers : Jump(s) \/ ClockStep(s) \/ DsCut(s) \/ MsCut(s)
    \/ DsDown
    \/ DsMend
    \/ MsDown
    \/ MsMend
    \/ \E mk \in MKeys : MsVanishStep(mk) \/ MsEvictStep(mk)
    \/ \E s \in Servers : BudgetDrop(s)

RunWaited(r, Tf(_, _)) ==
    /\ r \in DOMAIN req
    /\ Waiting(req[r].srv, r)
    /\ req[r].ph \in {"sent", "ran"}
    /\ Run(r, Tf)

MsRunWaited(r, MsTf(_, _)) ==
    /\ r \in DOMAIN mreq
    /\ MsWaiting(mreq[r].srv, r)
    /\ mreq[r].ph \in {"sent", "ran"}
    /\ MsRun(r, MsTf)

Serve(r) == Land(r) /\ Waiting(req[r].srv, r) /\ up[req[r].srv]

MsServe(r) == MsApply(r) /\ MsWaiting(mreq[r].srv, r)

EnvFair(Tf(_, _), MsTf(_, _), Hold) ==
    /\ WF_envVars(Tick(Hold))
    /\ WF_envVars(Heal)
    /\ \A r \in 1..MaxReqs :
          WF_envVars(RunWaited(r, Tf)) /\ WF_envVars(Serve(r)) /\ WF_envVars(Fetch(r))
    /\ \A r \in 1..MaxMsReqs : WF_envVars(MsRunWaited(r, MsTf)) /\ WF_envVars(MsServe(r))
    /\ \A s \in Servers : WF_envVars(ListFetch(s))

EnvTypeOK ==
    /\ ver \in [Keys -> 0..MaxVers]
    /\ ext \in [Keys -> 0..MaxFaults]
    /\ DOMAIN hist = Keys
    /\ \A k \in Keys, i \in 0..MaxVers :
          upd[k][i] \in {NoStamp} \cup 0..MaxTime /\ curAt[k][i] \in 0..MaxTime
    /\ Len(req) <= MaxReqs
    /\ \A r \in DOMAIN req :
          /\ req[r].srv \in Servers
          /\ req[r].key \in Keys
          /\ req[r].kind \in {"upd", "set", "get"}
          /\ req[r].at \in 0..now
          /\ req[r].ph \in Phases
          /\ req[r].tf \in Runs
          /\ req[r].ans \in {"none"} \cup Heard
          /\ req[r].rv \in -1..MaxVers
          /\ req[r].clo \in 1..r
          /\ req[r].by \in 0..Len(req)
          /\ req[r].u \in {NoStamp} \cup 0..MaxTime
          /\ req[r].made \subseteq 1..MaxVers
          /\ Cardinality(req[r].made) <= 2
    /\ up \in [Servers -> BOOLEAN]
    /\ inc \in [Servers -> 0..MaxFaults]
    /\ now \in 0..MaxTime
    /\ calm \in BOOLEAN
    /\ calmAt \in 0..now
    /\ faults \in 0..MaxFaults
    /\ dsReach \in [Servers -> BOOLEAN]
    /\ \A s \in Servers :
          /\ lst[s].on \in BOOLEAN /\ lst[s].ex \in BOOLEAN
          /\ lst[s].from \subseteq Keys /\ lst[s].got \subseteq Keys
          /\ lst[s].ask \in BOOLEAN /\ lst[s].read \in BOOLEAN /\ lst[s].end \in BOOLEAN
          /\ lst[s].at \in 0..now
          /\ lst[s].page \subseteq Keys /\ Cardinality(lst[s].page) <= 1
          /\ lst[s].ask => lst[s].on
          /\ lst[s].read => lst[s].ask /\ (lst[s].end \/ lst[s].page # {})
          /\ lst[s].on => up[s]
          /\ lst[s].skip \subseteq lst[s].from \ lst[s].got
          /\ lst[s].passed \subseteq lst[s].from
          /\ lst[s].skip # {} => lst[s].read /\ lst[s].page # {}
    /\ DOMAIN ms = MKeys /\ DOMAIN msPrev = MKeys
    /\ \A mk \in MKeys : ms[mk].has \in BOOLEAN /\ msPrev[mk].has \in BOOLEAN
    /\ msVer \in [MKeys -> 0..(4 * MaxMsReqs + MaxFaults)]
    /\ msAt \in [MKeys -> 0..now]
    /\ Len(mreq) <= MaxMsReqs
    /\ \A r \in DOMAIN mreq :
          /\ mreq[r].srv \in Servers
          /\ mreq[r].key \in MKeys
          /\ mreq[r].kind \in {"upd", "set", "get"}
          /\ mreq[r].ttl >= 0
          /\ mreq[r].at \in 0..now
          /\ mreq[r].ph \in MsPhases
          /\ mreq[r].tf \in MsRuns
          /\ mreq[r].ans \in {"none"} \cup MsHeard
          /\ mreq[r].rv \in -1..msVer[mreq[r].key]
          /\ mreq[r].made \in 0..2
    /\ msReach \in [Servers -> BOOLEAN]
    /\ bud \in [Servers -> [BudgetTypes -> 0..MaxBudget]]

EnvAnswersTrue ==
    /\ \A r \in DOMAIN req :
          /\ req[r].ans = "ok" => req[r].ph = IF req[r].kind = "get" THEN "read" ELSE "landed"
          /\ req[r].ans = "nil" => req[r].ph = "cancel" /\ req[r].kind = "upd"
          /\ ~LoseCommit /\ req[r].ans = "nil" => req[r].made = {}
          /\ ~LoseCommit /\ req[r].ans = "ok" /\ req[r].kind # "get" => Cardinality(req[r].made) = 1
          /\ req[r].kind = "get" /\ req[r].ph = "read" =>
                /\ req[r].rv \in 0..ver[req[r].key]
                /\ req[r].seen = hist[req[r].key][req[r].rv]
                /\ req[r].u = upd[req[r].key][req[r].rv]
    /\ \A r \in DOMAIN mreq :
          /\ mreq[r].ans = "ok" => mreq[r].ph = IF mreq[r].kind = "get" THEN "read" ELSE "applied"
          /\ mreq[r].ans = "nil" => mreq[r].ph = "cancel"
          /\ ~LoseCommit /\ mreq[r].ans = "nil" => mreq[r].made = 0
          /\ ~LoseCommit /\ mreq[r].ans = "ok" /\ mreq[r].kind # "get" => mreq[r].made = 1

EnvNoZWrite ==
    \A r \in DOMAIN req :
        req[r].kind = "upd" =>
            /\ \A i \in req[r].made : ~Absent(req[r].key, hist[req[r].key][i])
            /\ req[r].ph \in {"ran", "landed"} => ~Absent(req[r].key, req[r].res)

EnvNoUpdRemoval == EnvNoZWrite

EnvLandsOnRead ==
    \A r \in DOMAIN req :
        req[r].kind = "upd" /\ req[r].ph = "landed" =>
            /\ req[r].rv + 1 \in req[r].made
            /\ hist[req[r].key][req[r].rv + 1] = req[r].res

EnvOneWritePerVersion ==
    /\ \A k \in Keys :
          ver[k] = Cardinality(UNION {req[r].made : r \in {q \in DOMAIN req : req[q].key = k}})
                   + ext[k]
    /\ \A r1, r2 \in DOMAIN req :
          r1 # r2 /\ req[r1].key = req[r2].key => req[r1].made \cap req[r2].made = {}
    /\ \A r \in DOMAIN req :
          /\ req[r].made \subseteq 1..ver[req[r].key]
          /\ req[r].ph = "landed" => req[r].made # {}
          /\ req[r].kind = "set" => Cardinality(req[r].made) <= 1
          /\ req[r].kind = "get" => req[r].made = {}

EnvVersLeft ==
    /\ \A k \in Keys : ver[k] <= MaxVers
    /\ \A r \in DOMAIN req :
          /\ Cardinality(req[r].made) <= IF req[r].kind = "upd" THEN 2 ELSE 1
          /\ req[r].ph = "ran" => ver[req[r].key] < MaxVers

EnvRunsRecorded ==
    /\ \A r \in DOMAIN req :
          LET c == req[r].clo
              b == req[r].by IN
          /\ req[c].clo = c
          /\ req[r].key = req[c].key /\ req[r].srv = req[c].srv /\ req[r].inc = req[c].inc
          /\ req[r].kind \in {"set", "get"} => c = r /\ req[r].tf = "none" /\ req[r].by = 0
          /\ c # r => req[r].tf = "none" /\ req[r].by = 0
          /\ (req[r].by = 0) = (req[r].tf = "none")
          /\ req[r].kind \in {"upd", "get"} /\ req[r].ph = "sent" => req[r].rv = -1
          /\ req[r].ph = "read" => req[r].kind = "get"
          /\ req[r].kind = "upd" /\ req[r].rv >= 0 => req[c].by # 0
          /\ b # 0 =>
                /\ c = r
                /\ req[b].clo = r
                /\ req[b].rv >= 0
                /\ req[r].seen = hist[req[b].key][req[b].rv]
                /\ req[b].ph = "cancel" => req[r].tf = "cancel"
                /\ req[b].ph \in {"ran", "landed"} => req[r].tf = "write"
    /\ \A r \in DOMAIN mreq :
          /\ mreq[r].kind \in {"set", "get"} => mreq[r].tf = "none"
          /\ mreq[r].ph = "sent" => mreq[r].rv = -1 /\ mreq[r].tf = "none"
          /\ mreq[r].kind = "upd" /\ mreq[r].ph \in {"ran", "applied"} => mreq[r].tf = "write"
          /\ mreq[r].ph = "cancel" => mreq[r].tf = "cancel"
          /\ mreq[r].ph = "threw" => mreq[r].tf = "throw" /\ mreq[r].kind = "upd"
          /\ mreq[r].ph = "read" => mreq[r].kind = "get"
          /\ mreq[r].kind = "upd" /\ mreq[r].ph \in {"ran", "applied"} => mreq[r].res.ttl = mreq[r].ttl
          /\ mreq[r].ph = "applied" => mreq[r].made >= 1
          /\ mreq[r].kind = "get" => mreq[r].made = 0
          /\ mreq[r].kind = "set" => mreq[r].made <= 1
          /\ ~LoseCommit /\ ~RunAfterAnswer => mreq[r].made <= 1

EnvStamps ==
    /\ \A k \in Keys, i \in 0..MaxVers :
          i <= ver[k] => ((upd[k][i] = NoStamp) <=> Absent(k, hist[k][i]))
    /\ ~KeyInfo => \A k \in Keys, i \in 0..MaxVers : upd[k][i] \in {NoStamp, 0}
    /\ ~Reverts => \A k \in Keys : ext[k] = 0
    /\ \A r \in DOMAIN req :
          req[r].kind # "get" =>
             \/ req[r].made = {} /\ req[r].u = NoStamp
             \/ \E i \in req[r].made :
                   /\ upd[req[r].key][i] = req[r].u
                   /\ \A j \in req[r].made : j <= i
    /\ \A r \in DOMAIN req :
          req[r].kind = "get" =>
             IF req[r].rv >= 0 THEN req[r].u = upd[req[r].key][req[r].rv] ELSE req[r].u = NoStamp

EnvTimes ==
    \A k \in Keys :
        /\ \A i \in 1..ver[k] : curAt[k][i - 1] <= curAt[k][i]
        /\ curAt[k][ver[k]] <= now

EnvErrOutcomes ==
    /\ \A r \in DOMAIN req : req[r].ans = "err" =>
          \/ req[r].ph = "gone" /\ (req[r].made = {} \/ LoseCommit)
          \/ LoseAnswer /\ req[r].ph = "landed"
          \/ LateLand /\ req[r].ph \in {"ran", "landed"}
          \/ RunAfterAnswer /\ req[r].kind = "upd" /\ req[r].ph \in {"sent", "ran", "cancel"}
    /\ \A r \in DOMAIN req :
          req[r].ans = "err" /\ req[r].made # {} => LoseAnswer \/ LateLand \/ LoseCommit
    /\ \A r \in DOMAIN mreq : mreq[r].ans = "err" =>
          \/ mreq[r].ph = "gone"
          \/ MsMaybe /\ mreq[r].ph \in {"ran", "applied"}
          \/ RunAfterAnswer /\ mreq[r].kind = "upd" /\ mreq[r].ph \in {"sent", "ran", "cancel", "threw"}
    /\ \A r \in DOMAIN mreq :
          mreq[r].ans = "err" /\ mreq[r].made > 0 => MsMaybe \/ LoseCommit

EnvMemoryOff ==
    ~MsOn =>
        /\ \A mk \in MKeys : ~ms[mk].has
        /\ \A r \in DOMAIN mreq : mreq[r].ph \in {"sent", "ran", "gone"} /\ mreq[r].ans # "ok"

EnvNoGhostItem ==
    /\ \A mk \in MKeys : ~ms[mk].has => ms[mk].v = msZero
    /\ \A mk \in MKeys : ~msPrev[mk].has => msPrev[mk].v = msZero
    /\ \A mk \in MKeys : \A it \in MsReads(mk) : ~it.has => it.v = msZero
    /\ \A r \in DOMAIN mreq : ~mreq[r].seen.has => mreq[r].seen.v = msZero

EnvDelay ==
    /\ \A r \in DOMAIN req :
          (/\ calm /\ Waiting(req[r].srv, r)
           /\ \/ req[r].kind \in {"upd", "set"} /\ req[r].ph \in {"sent", "ran"}
              \/ req[r].kind = "get" /\ req[r].ph = "sent"
              \/ req[r].ph \in {"landed", "cancel", "read"})
              => Age(req[r].at) <= DelayAfterCalm
    /\ \A r \in DOMAIN mreq :
          (calm /\ MsWaiting(mreq[r].srv, r)) => Age(mreq[r].at) <= DelayAfterCalm
    /\ \A s \in Servers : calm /\ lst[s].ask => Age(lst[s].at) <= DelayAfterCalm

EnvExpiry ==
    \A r \in DOMAIN mreq :
        mreq[r].ttl > MaxExpiry =>
            /\ mreq[r].made = 0
            /\ mreq[r].ans \in {"none", "err"}
            /\ mreq[r].tf = "none"

EnvBudgets ==
    /\ ~Budgets => bud = BudFull
    /\ \A s \in Servers, t \in BudgetTypes : Budget(s, t) \in 0..MaxBudget

EnvReach ==
    /\ (\E s \in Servers : ~dsReach[s]) => DsSplit \/ DsOutage
    /\ (\E s \in Servers : msReach[s] # MsOn) => MsSplit \/ MsOutage
    /\ calm => \A s \in Servers : dsReach[s] /\ msReach[s] = MsOn

EnvClocks ==
    /\ skew \in [Servers -> -MaxSkew..MaxSkew]
    /\ calm => \A s \in Servers : -SkewAfterCalm <= skew[s] /\ skew[s] <= SkewAfterCalm

EnvSetsApart ==
    \A r1, r2 \in DOMAIN req :
        (/\ r1 # r2
         /\ req[r1].kind = "set" /\ req[r2].kind = "set"
         /\ req[r1].key = req[r2].key
         /\ Waiting(req[r1].srv, r1))
        => ~Waiting(req[r1].srv, r2)

EnvHolds ==
    /\ EnvTypeOK
    /\ EnvAnswersTrue
    /\ EnvNoZWrite
    /\ EnvLandsOnRead
    /\ EnvOneWritePerVersion
    /\ EnvVersLeft
    /\ EnvRunsRecorded
    /\ EnvStamps
    /\ EnvTimes
    /\ EnvErrOutcomes
    /\ EnvMemoryOff
    /\ EnvNoGhostItem
    /\ EnvDelay
    /\ EnvReach
    /\ EnvClocks
    /\ EnvSetsApart
    /\ EnvExpiry
    /\ EnvBudgets

EnvTimeMoves == <>(now = MaxTime)

====
