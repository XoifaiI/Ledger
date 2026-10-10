--------------------------------- MODULE Tx ---------------------------------
\* Tx is the chosen transaction design,
\* phase A: the protocol on keys that exist. It extends env/Env.tla (a
\* copy sits beside it) and adds nothing to Env.
\*
\* WHAT IS MODELLED
\*
\* Game keys a, b and c each hold one record, the value of the design's section 2 cut
\* to what the protocol reads: the money field g, one game field x, the
\* post diff p of an exclusive mark, the horizon h, the timed room T and
\* the work room P. T holds leg fates, decisions and the names of one key
\* edits. P holds escrow marks, exclusive marks and pinned records. Rooms
\* are counted in items, not bytes: TimedRoom items in T, MarkCap marks
\* and OwedCap pinned records in P. fx is what the write that made the
\* version did, for the ghost observer only.
\*
\* Every write is one Env Issue whose transform is Step: the ends it
\* carries first, then the op's lookups, its horizon, its judgement and
\* its room, in the order of record 4, then Age and Fit, which raise h
\* over every name they drop. A run that decides nothing and ends nothing
\* cancels. Each run leaves a note: its report, the items it read, and w,
\* which turns TRUE once any run of the closure returned a write and never
\* turns back (record 3.3).
\*
\* The request kinds are those of the design's section 3: Tent (3.2) on each leg key
\* but the decider, Commit (3.3) on the decider D, Fence and Resolve
\* (3.4), a drop of pinned records (3.5), and a one key Edit under a game
\* name, judged by the order rule of 4.1. A request may carry resolves of
\* other uses on its key, which Step applies first (record step 3).
\*
\* A server runs one call at a time from its script. A call keeps at most
\* one request out per key (the record's one writer) and may have several
\* keys out at once, as the parallel Tents of 3.2. It reads only its own
\* requests' answers, notes and reads. The coordinator follows the table
\* of 3.6. A blocked writer follows 4.2: read the blocker's decider, ride
\* a decision or a presumed abort, fence it when it is younger or
\* SettleAge old, else wait. A touch follows 5.1 for one item: a mark
\* SettleAge old is ended by 4.2's steps, and a pinned record SettleAge
\* old is verified by resolves of commit on its leg keys, then dropped.
\* A commit that meets OwedCap verifies the listed records the same way
\* and sends again with their drops (3.5).
\* A leg key whose resolve reports missing is proved gone by a ProveGone,
\* a write that lands only on an absent key (5.1 point 5), and only then
\* is the record dropped. A touch's fence that reports missing ends
\* nothing (5.1). A cut reads the gone decider of a mark OrphanAge old and
\* takes its orphan end (cuts 3.2). With ShareHost, server A2 is a second
\* call of server A's process, sharing what it knows of each key's
\* incarnation (record 3.2 step 1; open question 13).
\*
\* WHAT IS LEFT OUT, AND WHY
\*
\* Phase A: keys exist before any call runs, seeded by an UpdateAsync that
\* writes only onto an absent key, so a seed that lands twice or late
\* changes nothing. So there
\* is no existence rule, no incarnation id, no erase, no orphan rule, no
\* Missing: phase B adds them. No migrations or builds: phase B. No clean
\* flag on marks and no reads for the game (4.3): A7 is the record's. No
\* Overdue guard and no Ceiling (5.2): liveness. No level wait at a touch
\* (5.1): any toucher acts once an item is SettleAge old, which only adds
\* behaviours. A drawn name met as forgotten while clean answers Expired
\* where the design draws a new name once: the redraw is a new call. The
\* priority of a writer is its name's stamp and number. A game name's
\* fingerprint is its terms, exact: the 1 in 65,536 misuse of design rule
\* 25 is out. Amounts are 1 and 2, so the credit ceiling of 2^53 never
\* binds. MemoryStore is off: the design uses none.
\*
\* GHOSTS
\*
\* No server step reads them. The observer Obs reads the fx of each
\* landing. dec[n] is "commit" once a Commit of name n landed, comAt[n]
\* its attempt, comT[n] its terms, committer[n] the call whose request
\* landed it. applied[n][k] counts the effects of n's legs on k: the
\* decider's leg at the commit, every other leg at its Resolve.
\* fenced[n][d] is the highest attempt a Fence of n landed at on decider
\* d, finF[n][d] a final one. refd[n][d] says an R or F of n for decider d
\* landed on a leg key or on d. They are kept per decider because a name
\* a game misuses for other terms can name two deciders, and a fence on
\* one stops no commit on the other.
\* made is the money the game's ops and the seeds made. edTook[n] counts
\* the edits of n that took, edBy[n] the call that landed one. bad holds
\* the names of the steps that broke a rule as they landed.
\*
\* PROPERTIES, by their id in the property list
\*   S1 Conservation. S4 AllOrNone, with DecideOnce and MarkEndsDecided as
\*   the flags CommitAfterNever, CommitTwice and EndUndecided in bad, and
\*   ApplyRight. S5 AtMostOnce. S7 through TrueCommitted and NoForName,
\*   which read the terms. S8 in the form NonNeg: every key's balance,
\*   counting committed legs, stays at or above 0, which every op was
\*   judged against (the game's rule). A2 TrueCommitted, TrueEdit. A3
\*   NoMeansNever, NoForName, RulesSaidNo, ExpiredForgot. A5
\*   UnresolvedOnlyWhenUnknown. C3 CostBound. And Env's EnvNoZWrite and
\*   EnvSetsApart.
EXTENDS Env, TLC

CONSTANTS
    Scenario,      \* the script to run, a string
    TimedRoom,     \* the items T keeps
    MarkCap,       \* the marks P keeps
    OwedCap,       \* the pinned records P keeps
    Win,           \* W[kind] in ticks, for every timed name
    SettleAge,     \* in ticks
    MaxAttempts,
    Retries,
    FixCommitAfterAll,   \* a Commit is sent only once every Tent reported mine
    FixResolveAttempt,   \* a Resolve ends only the mark of the attempt it names, or an older one
    FixDropVerified,     \* a pinned record leaves only with a verified drop
    FixRefuseWrites,     \* a refusal is written, and Refused is answered only from a write
    FixOrderRule,        \* a game op beside escrow marks runs under every subset of them
    FixHorizonRaise,     \* a name dropped from T raises h over its stamp
    FixCleanRule,        \* a no read from a cancel counts only when nothing of the call may have written
    FixFenceFirst,       \* an undecided blocker is fenced before its mark is ended
    MustExist,           \* phase B: the keys whose store is must exist; the others create on first write
    Erasable,            \* phase B: the keys whose store may be erased, which carry an incarnation id
    LateAge,             \* phase B: a create whose first send time is more than this old warns LateCreate
    RemoveSend,          \* phase B: a sealer removes its seal only while its clock reads at most this past rt
    FixIdCheck,          \* phase B: a request lands only on the incarnation it was judged for
    Wtx,                 \* phase B: W[tx], how long after its stamp a Commit may create its decider
    OrphanAge,           \* phase B: the age at which a mark whose decider reads gone is aborted (5.1)
    SealAge,             \* phase B: the age of rt past which a seal is left over (cuts 3.4 step 6)
    RemoveLate,          \* phase B: platform bound, a removal lands at most this late; NONE for none
    ReadLag,             \* phase B: platform bound, a GetAsync reads a version current at most this long
                         \* before it; NONE for none
    FixGate,             \* phase B: a Tent, and a Commit on the erased key, are gated by an erase's gate
    FixDrainPins,        \* phase B: an erase drains the pinned records on its key before it seals
    FixCommitWindow,     \* phase B: a Commit creates its decider only within Wtx of its stamp
    FixOrphanAge,        \* phase B: the orphan rule acts only on a read made OrphanAge after the stamp
    FixSealAge,          \* phase B: a create replaces a seal only once it is SealAge old
    FixResolveTerms,     \* candidate fix, not the design: a Resolve ends a mark only of its own terms
                         \* (finding 2 of the transaction design)
    FixCreateOnce,       \* candidate fix, not the design: a run creates a key only if no earlier run
                         \* of its closure wrote, and a send after one that may have written carries
                         \* the id that send would have made (finding 3 of the transaction design)
    FixOwnEvidence,      \* the fix of finding 6 of the transaction design: a Commit answered missing is
                         \* not own evidence; the coordinator fences D. FALSE is the rule as 3.4 wrote it
    KCut,                \* Reset (cuts 3.1): cut names K keeps; a drop raises hk
    FixCutMarks,         \* Reset: the cut lands only when no mark stands (rule 8); else it lands over them
    FixKeep,             \* Reset: a cut whose name is in K reports took and cuts nothing (rule 1)
    FixPinProve,         \* 5.1 point 5: a touch proves gone each leg key whose Resolve reported missing
    FixProveWrites,      \* 5.1 point 5: only a ProveGone that landed is the proof, not one that read
    FixCutOrphan,        \* cuts 3.2: a cut reads the gone decider of a mark OrphanAge old (Questions 15)
    FixFenceNotEvidence, \* 5.1: a touch's fence that reports missing ends nothing (Questions 19)
    ShareHost,           \* Questions 13: server A2 runs in A's process and shares its ic
    LearnAtEnd,          \* Questions 13: a call writes the ids it read into ic when it ends, as Ledger does
    FixWriterOrphan      \* a blocked writer's read of a gone decider takes the orphan end, as a touch's does

VARIABLES
    ls,          \* ls[s]: the call server s runs
    started,     \* the script calls started
    finished,    \* the script calls that ended
    ans,         \* every answer. Ghost.
    ic,          \* ic[s][k]: the incarnation server s last saw on key k (record 3.1)
    dec, comAt, comT, committer, applied, fenced, finF, refd, made, edTook, edBy, bad,
    edIds, late, lossOf, orph, incN, gave

lvars == <<ls, started, finished, ans, ic>>
gvars == <<dec, comAt, comT, committer, applied, fenced, finF, refd, made, edTook, edBy, bad,
           edIds, late, lossOf, orph, incN, gave>>
vars == <<envVars, lvars, gvars>>

ASSUME /\ TimedRoom \in Nat \ {0} /\ MarkCap \in Nat \ {0} /\ OwedCap \in Nat \ {0}
       /\ Win \in Nat \ {0} /\ SettleAge \in Nat /\ MaxAttempts \in Nat \ {0} /\ Retries \in Nat

NONE == -100
\* Questions 13: with ShareHost, server A2 is a second call of server A's process and shares its ic.
Host(s) == IF ShareHost /\ s = "A2" THEN "A" ELSE s
Names == 1..3

\* Terms: the legs of each use. A leg is a key, a field delta d, and a
\* game op, "claim", which sets x to 1 and is refused unless x is 0.

LegRec(k, d, op) == [k |-> k, d |-> d, op |-> op]
Legs(t) ==
    CASE t = 1 -> << LegRec("a", -1, ""), LegRec("b", 1, "") >>
      [] t = 2 -> << LegRec("b", -1, ""), LegRec("a", 1, "") >>
      [] t = 3 -> << LegRec("a", -1, ""), LegRec("c", 1, "") >>
      [] t = 4 -> << LegRec("a", -1, ""), LegRec("b", 0, "claim"), LegRec("c", 1, "") >>
      [] t = 5 -> << LegRec("a", -2, ""), LegRec("b", 1, ""), LegRec("c", 1, "") >>
Hot(t) == IF t = 4 THEN 3 ELSE 0
TxTerms == 1..5

\* The decider, from the terms alone (3.1 step 2).
DOf(t) ==
    LET L == Legs(t)
        ops == {i \in DOMAIN L : L[i].op # ""}
        cr == {i \in DOMAIN L : L[i].d > 0}
    IN IF Hot(t) # 0 THEN L[Hot(t)].k
       ELSE IF Cardinality(ops) = 1 THEN L[CHOOSE i \in ops : TRUE].k
       ELSE IF cr # {} THEN L[CHOOSE i \in cr : \A j \in cr : i <= j].k
       ELSE L[Len(L)].k
LegKeys(t) == {Legs(t)[i].k : i \in DOMAIN Legs(t)}
LegIdx(t, k) == CHOOSE i \in DOMAIN Legs(t) : Legs(t)[i].k = k

\* The terms of a one key edit, by its kind, so a name reused for another kind reads as other terms.
EdT(ek) == CASE ek = "dc" -> 101 [] ek = "dd" -> 102 [] ek = "gd" -> 103 [] ek = "claim" -> 104

\* Values.

\* One shape for every item of T and P. c is its class: "leg" a leg fate, "dec" a decision, "edit"
\* an edit's name, "esc" an escrow mark, "exc" an exclusive mark, "pin" a pinned record.
It0 == [c |-> "", n |-> 0, st |-> 0, f |-> "", a |-> 0, fin |-> FALSE, t |-> 0, dk |-> "",
        amt |-> 0, legs |-> {}]
\* An incarnation id: the life of the server that made the key, and a number of its own.
NoId == [j |-> <<"", 0>>, n |-> 0]
Fx0 == [e |-> "", n |-> 0, a |-> 0, st |-> 0, t |-> 0, dk |-> "", amt |-> 0, fin |-> FALSE, c |-> 0,
        id |-> NoId]

\* z: the key does not exist. Every value a transform writes has ex TRUE, or is a seal, sl TRUE.
\* A seal (cuts 3.4) holds no state: the erase's name sn, rt, the sealer ssrv and the namings nam.
\* G is the gate of the one erase in progress (cuts 2); L the named returns of the orphan rule.
\* The gate names its cut and its kind: an erase's gate stops Tents and Commits, a Reset's only Tents
\* (cuts 3.3). K holds the names of Resets that took, hk their horizon (cuts 3.1).
NoGate == [n |-> 0, st |-> 0, at |-> 0, kd |-> ""]
Z == [ex |-> FALSE, g |-> 0, x |-> 0, p |-> NONE, h |-> NONE, T |-> {}, P |-> {}, fx |-> {},
      id |-> NoId, sl |-> FALSE, sn |-> 0, rt |-> 0, ssrv |-> "", nam |-> 0, G |-> NoGate, L |-> {},
      K |-> {}, hk |-> NONE]
SeedVal(b) == [Z EXCEPT !.ex = TRUE, !.g = b, !.fx = {[Fx0 EXCEPT !.e = "seed", !.amt = b]}]

One(S) == CHOOSE e \in S : TRUE
Marks(R) == {m \in R.P : m.c \in {"esc", "exc"}}
Pins(R) == {m \in R.P : m.c = "pin"}
Named(S, n) == {e \in S : e.n = n}
IsHeld(R, n) == Named(R.T \cup R.P, n) # {}
Forgot(R, n, st) == ~IsHeld(R, n) /\ st <= R.h
HasExc(R) == \E m \in R.P : m.c = "exc"

RECURSIVE SumAmt(_)
SumAmt(S) == IF S = {} THEN 0 ELSE LET e == One(S) IN e.amt + SumAmt(S \ {e})

\* The least the money field can end at, whichever way each escrow mark ends (3.2).
Low(R) == R.g + SumAmt({m \in R.P : m.c = "esc" /\ m.amt < 0})

LegFate(n, st, f, a, t) == [It0 EXCEPT !.c = "leg", !.n = n, !.st = st, !.f = f, !.a = a, !.t = t]
DecEnt(n, st, f, a, fin, t) == [It0 EXCEPT !.c = "dec", !.n = n, !.st = st, !.f = f, !.a = a,
                                           !.fin = fin, !.t = t]
\* Put entry e in T in place of any entry of its name and class.
SetT(R, e) == [R EXCEPT !.T = {x \in @ : ~(x.n = e.n /\ x.c = e.c)} \cup {e}]
AddFx(R, f) == [R EXCEPT !.fx = @ \cup {f}]
FxOf(e, m, c) == [e |-> e, n |-> m.n, a |-> m.a, st |-> m.st, t |-> m.t, dk |-> m.dk,
                  amt |-> m.amt, fin |-> m.fin, c |-> c]

\* The argument and note of every request share one shape (Env: the note
\* starts as the argument). r, w, it, fa, df and rf are the report.

\* iid is the incarnation a request was judged for (record 3.1): m "any", "id" with v, or
\* "absent" with the fresh id v its create would give the key.
AnyId == [m |-> "any", v |-> NoId]
A0 == [k |-> "", ky |-> "", c |-> 0, n |-> 0, st |-> 0, t |-> 0, a |-> 0, li |-> 0, fin |-> FALSE,
       legs |-> {}, ends |-> {}, dr |-> {}, ek |-> "", sb |-> 0, iid |-> AnyId,
       r |-> "", w |-> FALSE, it |-> {}, fa |-> 0, df |-> "", rf |-> FALSE, srt |-> 0, nam |-> 0, sv |-> ""]

\* What a judge returns: the value, whether it acts, and the report.
J(R, act, r) == [R |-> R, act |-> act, r |-> r, it |-> {}, fa |-> 0, df |-> "", rf |-> FALSE]
JIt(R, act, r, it) == [J(R, act, r) EXCEPT !.it = it]
JDec(R, act, r, fa, df, rf) == [J(R, act, r) EXCEPT !.fa = fa, !.df = df, !.rf = rf]

\* Ends: a resolve of a use's mark on this key (3.4), and a drop of pinned
\* records on the decider (3.5). An end is [n, a, out, st, t, dk].

ResEnd(R, e, ci) ==
    LET mks == {m \in Named(Marks(R), e.n) : ~FixResolveTerms \/ m.t = e.t}
        fs == {x \in R.T : x.c = "leg" /\ x.n = e.n}
    IN IF mks # {}
       THEN LET m == One(mks)
                Rm == [R EXCEPT !.P = @ \ {m}, !.p = IF m.c = "exc" THEN NONE ELSE @]
            IN IF e.out = "commit" /\ (m.a = e.a \/ ~FixResolveAttempt)
               THEN [R |-> AddFx(SetT([Rm EXCEPT !.g = IF m.c = "esc" THEN @ + m.amt ELSE @,
                                                 !.x = IF m.c = "exc" THEN R.p ELSE @],
                                      LegFate(m.n, m.st, "took", m.a, m.t)),
                                 FxOf("apply", m, ci)),
                     act |-> TRUE]
               ELSE IF e.out = "orphan"
               THEN [R |-> AddFx([SetT(Rm, LegFate(m.n, m.st, "aborted", m.a, m.t))
                                  EXCEPT !.L = @ \cup {[n |-> m.n, dk |-> m.dk, amt |-> m.amt]}],
                                 FxOf("orphan", m, ci)),
                     act |-> TRUE]
               ELSE IF \/ e.out = "abort" /\ (m.a <= e.a \/ ~FixResolveAttempt)
                       \/ e.out = "commit" /\ m.a < e.a
               THEN [R |-> AddFx(SetT(Rm, LegFate(m.n, m.st, "aborted", m.a, m.t)), FxOf("rm", m, ci)),
                     act |-> TRUE]
               ELSE [R |-> R, act |-> FALSE]
       ELSE IF Forgot(R, e.n, e.st) THEN [R |-> R, act |-> FALSE]
       ELSE IF e.out = "commit"
       THEN IF \E x \in fs : x.f = "took" THEN [R |-> R, act |-> FALSE]
            ELSE [R |-> AddFx(SetT(R, LegFate(e.n, e.st, "took", e.a, e.t)),
                              [FxOf("nomark", [It0 EXCEPT !.n = e.n, !.a = e.a], ci) EXCEPT !.dk = e.dk]),
                  act |-> TRUE]
       ELSE IF \E x \in fs : x.f # "aborted" \/ x.a >= e.a THEN [R |-> R, act |-> FALSE]
       ELSE [R |-> SetT(R, LegFate(e.n, e.st, "aborted", e.a, e.t)), act |-> TRUE]

RECURSIVE Ends(_, _, _)
Ends(R, E, ci) ==
    IF E = {} THEN [R |-> R, act |-> FALSE]
    ELSE LET e == One(E)
             o == ResEnd(R, e, ci)
             rest == Ends(o.R, E \ {e}, ci)
         IN [R |-> rest.R, act |-> o.act \/ rest.act]

\* Move the pinned records named in D to T as decisions that took.
DropPins(R, D) ==
    LET ps == {p \in Pins(R) : p.n \in D} IN
    [R EXCEPT !.P = @ \ ps,
              !.T = {x \in @ : x.n \notin {p.n : p \in ps}}
                    \cup {DecEnt(p.n, p.st, "took", p.a, FALSE, p.t) : p \in ps}]

\* Age and Fit (record 4 steps 7 and 8). Each drop raises h to the stamp
\* of what it drops.

MaxSt(S) == IF S = {} THEN NONE ELSE (CHOOSE e \in S : \A f \in S : f.st <= e.st).st
Raise(h, x) == IF FixHorizonRaise /\ x > h THEN x ELSE h
AgeT(R, clk) == LET old == {e \in R.T : clk - e.st >= Win} IN
               [R EXCEPT !.T = @ \ old, !.h = Raise(@, MaxSt(old))]
\* One drop of the least stamp, first among the items this request did not write.
Fit1(R, own) ==
    IF Cardinality(R.T) <= TimedRoom THEN R
    ELSE LET pool == IF R.T \ own # {} THEN R.T \ own ELSE R.T
             e == CHOOSE e \in pool : \A f \in pool : e.st <= f.st
         IN [R EXCEPT !.T = @ \ {e}, !.h = Raise(@, e.st)]
Post(R, v, clk) ==
    LET own == R.T \ v.T
        R1 == AgeT(R, clk)
    IN Fit1(Fit1(Fit1(R1, own), own), own)

\* The judges. Each starts from R, the value after the ends.

\* Tent (3.2), on a leg key that is not the decider.
TentJ(R, a, ci) ==
    LET L == Legs(a.t)[a.li]
        mks == Named(Marks(R), a.n)
        m == One(mks)
    IN IF mks # {} /\ m.t # a.t THEN J(R, FALSE, "other")
       ELSE IF mks # {} /\ m.a = a.a THEN J(R, FALSE, "mine")
       ELSE IF mks # {} /\ m.a > a.a THEN J(R, FALSE, "superseded")
       ELSE
       LET R1 == IF mks # {}
                 THEN AddFx([R EXCEPT !.P = @ \ {m}, !.p = IF m.c = "exc" THEN NONE ELSE @],
                            FxOf("rm", m, ci))
                 ELSE R
           act1 == mks # {}
           fs == {x \in R1.T : x.c = "leg" /\ x.n = a.n}
           f == One(fs)
           els == {x \in R1.T \cup R1.P : x.n = a.n /\ x.c \in {"dec", "pin", "edit"}}
           mk == [It0 EXCEPT !.n = a.n, !.a = a.a, !.st = a.st, !.t = a.t, !.dk = DOf(a.t), !.amt = L.d]
       IN IF fs # {} /\ f.t # a.t THEN J(R1, act1, "other")
          ELSE IF fs # {} /\ ~(f.f = "aborted" /\ f.a < a.a) THEN JDec(R1, act1, "decided", f.a, f.f, FALSE)
          ELSE IF els # {} THEN J(R1, act1, "other")
          ELSE IF Forgot(R1, a.n, a.st) THEN J(R1, act1, "forgotten")
          ELSE IF FixGate /\ R1.G.n # 0 THEN JIt(R1, act1, "gated", {[It0 EXCEPT !.n = R1.G.n, !.st = R1.G.at]})
          ELSE IF L.op = ""
          THEN IF HasExc(R1) THEN JIt(R1, act1, "blocked", {x \in R1.P : x.c = "exc"})
               ELSE IF L.d < 0 /\ Low(R1) + L.d < 0
               THEN IF FixRefuseWrites
                    THEN J(AddFx(SetT(R1, LegFate(a.n, a.st, "R", a.a, a.t)), FxOf("Rleg", mk, ci)),
                           TRUE, "refused")
                    ELSE J(R1, act1, "refused")
               ELSE IF Cardinality(Marks(R1)) >= MarkCap THEN JIt(R1, act1, "noroom", Marks(R1))
               ELSE J([R1 EXCEPT !.P = @ \cup {[mk EXCEPT !.c = "esc"]}], TRUE, "mine")
          ELSE IF Marks(R1) # {} THEN JIt(R1, act1, "blocked", Marks(R1))
          ELSE IF R1.x # 0
          THEN IF FixRefuseWrites
               THEN J(AddFx(SetT(R1, LegFate(a.n, a.st, "R", a.a, a.t)), FxOf("Rleg", mk, ci)),
                      TRUE, "refused")
               ELSE J(R1, act1, "refused")
          ELSE IF Cardinality(Marks(R1)) >= MarkCap THEN JIt(R1, act1, "noroom", Marks(R1))
          ELSE J([R1 EXCEPT !.P = @ \cup {[mk EXCEPT !.c = "exc"]}, !.p = 1], TRUE, "mine")

\* Commit (3.3), on the decider, after its drops.
CommitJ(R0, a, ci) ==
    LET R == IF ~FixDropVerified /\ Cardinality(Pins(R0)) >= OwedCap
             THEN DropPins(R0, {p.n : p \in Pins(R0)}) ELSE R0
        k == DOf(a.t)
        L == Legs(a.t)[LegIdx(a.t, k)]
        ps == Named(Pins(R), a.n)
        ds == {x \in R.T : x.c = "dec" /\ x.n = a.n}
        d == One(ds)
        pin == [It0 EXCEPT !.c = "pin", !.n = a.n, !.a = a.a, !.st = a.st, !.t = a.t,
                           !.dk = k, !.legs = LegKeys(a.t) \ {k}]
        rdec(f) == DecEnt(a.n, a.st, f, a.a, FALSE, a.t)
        ok == \/ L.op = "" /\ (L.d >= 0 \/ Low(R) + L.d >= 0)
              \/ L.op = "claim" /\ R.x = 0
        blk == IF L.op = "" THEN HasExc(R) ELSE Marks(R) # {}
    IN IF ps # {} THEN (IF One(ps).t # a.t THEN J(R, FALSE, "other")
                        ELSE JDec(R, FALSE, "committed", One(ps).a, "took", FALSE))
       ELSE IF ds # {} /\ d.t # a.t THEN J(R, FALSE, "other")
       ELSE IF ds # {} /\ d.f = "took" THEN JDec(R, FALSE, "committed", d.a, "took", FALSE)
       ELSE IF ds # {} /\ d.f \in {"R", "F"} THEN JDec(R, FALSE, "refused", d.a, d.f, FALSE)
       ELSE IF ds # {} /\ d.f = "fenced" /\ (d.fin \/ d.a >= a.a)
            THEN JDec(R, FALSE, "fenced", d.a, "fenced", d.fin)
       ELSE IF Named({x \in R.T \cup Marks(R) : x.c # "dec"}, a.n) # {} THEN J(R, FALSE, "other")
       ELSE IF ds = {} /\ Forgot(R, a.n, a.st) THEN J(R, FALSE, "forgotten")
       ELSE IF FixGate /\ R.G.n # 0 /\ R.G.kd = "erase"
            THEN JIt(R, FALSE, "gated", {[It0 EXCEPT !.n = R.G.n, !.st = R.G.at]})
       ELSE IF blk THEN JIt(R, FALSE, "blocked", IF L.op = "" THEN {x \in R.P : x.c = "exc"} ELSE Marks(R))
       ELSE IF ~ok
            THEN J(AddFx(SetT(R, rdec("R")), FxOf("Rdec", pin, ci)), TRUE, "refused")
       ELSE IF Cardinality(Pins(R)) >= OwedCap THEN JIt(R, FALSE, "owed", Pins(R))
       ELSE J(AddFx([R EXCEPT !.g = @ + L.d, !.x = IF L.op = "claim" THEN 1 ELSE @,
                              !.T = {x \in @ : ~(x.c = "dec" /\ x.n = a.n)}, !.P = @ \cup {pin}],
                    FxOf("commit", pin, ci)),
              TRUE, "committed")

\* Fence (3.4), on the decider.
FenceJ(R, a, ci) ==
    LET ps == Named(Pins(R), a.n)
        ds == {x \in R.T : x.c = "dec" /\ x.n = a.n}
        d == One(ds)
        fe(at, fin) == FxOf("fence", [It0 EXCEPT !.n = a.n, !.a = at, !.fin = fin, !.dk = a.ky], ci)
    IN IF ps # {} THEN JDec(R, FALSE, "committed", One(ps).a, "took", FALSE)
       ELSE IF ds # {} /\ d.f = "took" THEN JDec(R, FALSE, "committed", d.a, "took", FALSE)
       ELSE IF ds # {} /\ d.f \in {"R", "F"} THEN JDec(R, FALSE, "refused", d.a, d.f, FALSE)
       ELSE IF ds # {} /\ d.a >= a.a /\ (d.fin \/ ~a.fin) THEN JDec(R, FALSE, "fenced", d.a, "fenced", d.fin)
       ELSE IF ds # {}
            THEN LET at == IF d.a >= a.a THEN d.a ELSE a.a
                     fin == d.fin \/ a.fin
                 IN JDec(AddFx(SetT(R, DecEnt(a.n, d.st, "fenced", at, fin, d.t)), fe(at, fin)),
                         TRUE, "fenced", at, "fenced", fin)
       ELSE IF Forgot(R, a.n, a.st) THEN J(R, FALSE, "forgotten")
       ELSE JDec(AddFx(SetT(R, DecEnt(a.n, a.st, "fenced", a.a, a.fin, a.t)), fe(a.a, a.fin)),
                 TRUE, "fenced", a.a, "fenced", a.fin)

\* A one key edit under a game name, judged by the order rule (4.1). Kinds: dc credits 1, dd debits
\* 1 as a field delta judged at Low, gd debits 1 by the game's rule "g at least 1", claim sets x.
EditJ(R, a, ci) ==
    LET es == Named(R.T \cup R.P, a.n)
        e == One(es)
        esc == {m \in R.P : m.c = "esc"}
        verdicts == IF FixOrderRule THEN {R.g + SumAmt(S) >= 1 : S \in SUBSET esc} ELSE {R.g >= 1}
        took(dg, dx) == AddFx(SetT([R EXCEPT !.g = @ + dg, !.x = IF dx THEN 1 ELSE @],
                                   [It0 EXCEPT !.c = "edit", !.n = a.n, !.st = a.st, !.f = "took", !.t = a.t]),
                              [Fx0 EXCEPT !.e = "edit", !.n = a.n, !.amt = dg, !.c = ci, !.id = R.id])
        refused == SetT(R, [It0 EXCEPT !.c = "edit", !.n = a.n, !.st = a.st, !.f = "R", !.t = a.t])
    IN IF es # {} THEN (IF e.c = "edit" /\ e.t = a.t
                        THEN J(R, FALSE, IF e.f = "took" THEN "took" ELSE "refused")
                        ELSE J(R, FALSE, "other"))
       ELSE IF Forgot(R, a.n, a.st) THEN J(R, FALSE, "forgotten")
       ELSE IF HasExc(R) THEN JIt(R, FALSE, "blocked", {x \in R.P : x.c = "exc"})
       ELSE CASE a.ek = "dc" -> J(took(1, FALSE), TRUE, "took")
              [] a.ek = "dd" -> IF Low(R) - 1 < 0 THEN J(refused, TRUE, "refused")
                                ELSE J(took(-1, FALSE), TRUE, "took")
              [] a.ek = "gd" -> IF verdicts = {TRUE} THEN J(took(-1, FALSE), TRUE, "took")
                                ELSE IF verdicts = {FALSE} THEN J(refused, TRUE, "refused")
                                ELSE JIt(R, FALSE, "blocked", esc)
              [] a.ek = "claim" -> IF R.x = 0 THEN J(took(0, TRUE), TRUE, "took")
                                   ELSE J(refused, TRUE, "refused")

\* Step: the one transform.

\* Record step 1.2: a request that may create an absent key. Phase B's store rule: a key outside
\* MustExist is made by its first Tent or Edit judged for no key; an end path write never makes one.
MayCreate(a, clk) ==
    /\ a.ky \notin MustExist
    /\ a.iid.m \in {"absent", "any"}
    /\ \/ a.k \in {"tent", "edit"}
       \/ a.k = "commit" /\ (clk - a.st <= Wtx \/ ~FixCommitWindow)
\* Cuts 3.4 step 6: a seal whose rt the landing clock reads SealAge past is left over.
LeftOver(v, clk) == v.sl /\ (clk - v.rt >= SealAge \/ ~FixSealAge)
\* Record step 1.3: the request was judged for this incarnation.
IdOk(a, v) == a.ky \notin Erasable \/ a.iid.m = "any" \/ a.iid.v = v.id \/ ~FixIdCheck

\* Cuts 3.4, for a key with no mark and no pinned record: the seal replaces the value, and names what
\* it destroyed. A key with marks reports them; phase B step 2 adds the gate and the drain.
EraseStep(c, v, R, act) ==
    LET a == c.arg
        clk == Clock(c.srv)
        M == Marks(R) \cup (IF FixDrainPins THEN Pins(R) ELSE {})
        gate == R.G.n = 0
        R2 == IF gate THEN [R EXCEPT !.G = [n |-> a.n, st |-> a.st, at |-> clk, kd |-> "erase"]] ELSE R
    IN IF M # {}
       THEN IF gate \/ act
            THEN WriteNote(Post(R2, v, clk), [a EXCEPT !.r = "marks", !.it = M, !.w = TRUE])
            ELSE CancelNote(v, [a EXCEPT !.r = "marks", !.it = M, !.w = c.note.w])
       ELSE WriteNote([Z EXCEPT !.sl = TRUE, !.sn = a.n, !.rt = clk, !.ssrv = c.srv, !.nam = R.g,
                                !.fx = R.fx \cup {[Fx0 EXCEPT !.e = "erase", !.n = a.n, !.amt = -R.g, !.c = a.c]}],
                      [a EXCEPT !.r = "sealed", !.srt = clk, !.nam = R.g, !.sv = c.srv, !.w = TRUE])

\* While K holds more than KCut names, drop the least stamp and raise hk to it (cuts 3.1 rule 9.3).
RECURSIVE FitK(_)
FitK(R) ==
    IF Cardinality(R.K) <= KCut THEN R
    ELSE LET d == CHOOSE x \in R.K : \A y \in R.K : x.st <= y.st
         IN FitK([R EXCEPT !.K = @ \ {d}, !.hk = IF d.st > @ THEN d.st ELSE @])

\* Cuts 3.1 for a Reset, after the ends, first rule that applies: kept in K (took); its own gate (skip
\* the horizon); its stamp at or below hk (forgotten); another cut's gate (gatedBy); marks stand (place
\* the gate if none, report marks); else cut: name the money in fx, put the state back to its default,
\* keep the name in K, clear its gate. Pinned records, T, h and every other field are carried. The write
\* lands if it set a gate, applied an end, or cut; else it cancels.
ResetStep(c, v, R, act) ==
    LET a == c.arg
        clk == Clock(c.srv)
        own == R.G.n = a.n /\ R.G.kd = "reset"
        M == Marks(R)
        say(r) == IF act THEN WriteNote(Post(R, v, clk), [a EXCEPT !.r = r, !.w = TRUE])
                  ELSE CancelNote(v, [a EXCEPT !.r = r, !.w = c.note.w])
        R2 == IF R.G.n = 0 THEN [R EXCEPT !.G = [n |-> a.n, st |-> a.st, at |-> clk, kd |-> "reset"]] ELSE R
        cut == FitK([R EXCEPT !.g = 0, !.x = 0, !.p = NONE, !.K = @ \cup {[n |-> a.n, st |-> a.st]},
                              !.G = IF own THEN NoGate ELSE @,
                              !.fx = @ \cup {[Fx0 EXCEPT !.e = "cut", !.n = a.n, !.amt = -R.g, !.c = a.c]}])
    IN IF FixKeep /\ \E x \in R.K : x.n = a.n THEN say("took")
       ELSE IF ~own /\ a.st <= R.hk THEN say("forgotten")
       ELSE IF ~own /\ R.G.n # 0 THEN say("gatedBy")
       ELSE IF M # {} /\ FixCutMarks
            THEN IF R.G.n = 0 \/ act
                 THEN WriteNote(Post(R2, v, clk), [a EXCEPT !.r = "marks", !.it = M, !.w = TRUE])
                 ELSE CancelNote(v, [a EXCEPT !.r = "marks", !.it = M, !.w = c.note.w])
       ELSE WriteNote(Post(cut, v, clk), [a EXCEPT !.r = "took", !.nam = R.g, !.w = TRUE])

Step(c, v) ==
    LET a == c.arg
        clk == Clock(c.srv)
        create == ((~v.ex /\ ~v.sl) \/ LeftOver(v, clk)) /\ MayCreate(a, clk) /\ (~FixCreateOnce \/ ~c.note.w)
        R0 == IF create
              THEN [Z EXCEPT !.ex = TRUE, !.id = a.iid.v,
                             !.fx = {[Fx0 EXCEPT !.e = "create", !.n = a.n]}
                                    \cup IF clk - a.st > LateAge THEN {[Fx0 EXCEPT !.e = "late", !.n = a.n]} ELSE {}]
              ELSE [v EXCEPT !.fx = {}]
        en == Ends(R0, a.ends, a.c)
        dp == IF a.k \in {"commit", "drop", "erase"} THEN DropPins(en.R, a.dr) ELSE en.R
        ea == en.act \/ dp.P # en.R.P
        j == CASE a.k = "tent"   -> TentJ(dp, a, a.c)
               [] a.k = "commit" -> CommitJ(dp, a, a.c)
               [] a.k = "fence"  -> FenceJ(dp, a, a.c)
               [] a.k = "edit"   -> EditJ(dp, a, a.c)
               [] a.k \in {"res", "drop", "erase", "reset"} -> J(dp, FALSE, "done")
        act == create \/ ea \/ j.act \/ (a.k = "commit" /\ j.R.P # dp.P)
        nt == [a EXCEPT !.r = j.r, !.w = c.note.w \/ act, !.it = j.it, !.fa = j.fa, !.df = j.df, !.rf = j.rf]
    IN IF a.k = "seed"
       \* A seed is the model's setup, not an op of the design: a late run of one never lands on a
       \* key made or sealed since (a Reseal walk had one write over a fresh seal).
       THEN IF v.ex \/ v.sl THEN CancelNote(v, [a EXCEPT !.r = "done", !.w = c.note.w])
            ELSE WriteNote(SeedVal(a.sb), [a EXCEPT !.r = "done", !.w = TRUE])
       \* Transaction 5.1 point 5: a ProveGone writes a seal only onto an absent key, or over a seal
       \* left over, as a create may, and cancels on anything else. Without FixProveWrites it only
       \* reads, and cancels.
       ELSE IF a.k = "prove"
       THEN IF ~v.ex /\ (~v.sl \/ LeftOver(v, clk))
            THEN IF FixProveWrites
                 THEN WriteNote([Z EXCEPT !.sl = TRUE, !.rt = clk, !.ssrv = c.srv],
                                [a EXCEPT !.r = "proved", !.srt = clk, !.sv = c.srv, !.w = TRUE])
                 ELSE CancelNote(v, [a EXCEPT !.r = "proved", !.w = c.note.w])
            ELSE CancelNote(v, [a EXCEPT !.r = "exists", !.w = c.note.w])
       ELSE IF v.sl /\ ~create
            THEN IF a.k = "erase" /\ a.n = v.sn
                 THEN CancelNote(v, [a EXCEPT !.r = "sealed", !.srt = v.rt, !.nam = v.nam, !.sv = v.ssrv,
                                             !.w = c.note.w])
                 ELSE CancelNote(v, [a EXCEPT !.r = "missing", !.w = c.note.w])
       ELSE IF ~v.ex /\ ~create THEN CancelNote(v, [nt EXCEPT !.r = "missing", !.w = c.note.w])
       ELSE IF v.ex /\ ~IdOk(a, v) THEN CancelNote(v, [a EXCEPT !.r = "missing", !.w = c.note.w])
       ELSE IF a.k = "erase" THEN EraseStep(c, v, dp, ea)
       ELSE IF a.k = "reset" THEN ResetStep(c, v, dp, ea)
       ELSE IF act THEN WriteNote(Post(j.R, v, Clock(c.srv)), nt)
       ELSE CancelNote(v, [nt EXCEPT !.w = c.note.w])

Tf(c, v) == Step(c, v)
MsTf(c, it) == MsCancel(c, it)

\* The scripts.

E0 == [s |-> "A", m |-> "", n |-> 0, t |-> 0, st |-> NONE, k |-> "", ek |-> "", sb |-> 0,
       pre |-> FALSE, retry |-> FALSE, q |-> FALSE, wait |-> 0]
Seed(s, k, b) == [E0 EXCEPT !.s = s, !.m = "seed", !.k = k, !.sb = b, !.pre = TRUE]
TxE(s, n, t) == [E0 EXCEPT !.s = s, !.m = "tx", !.n = n, !.t = t]
GameTx(s, n, t, st) == [TxE(s, n, t) EXCEPT !.st = st]
Again(e) == [e EXCEPT !.retry = TRUE]
Ed(s, n, k, ek, st) == [E0 EXCEPT !.s = s, !.m = "edit", !.n = n, !.k = k, !.ek = ek, !.st = st,
                                  !.t = EdT(ek)]
Touch(s, k) == [E0 EXCEPT !.s = s, !.m = "touch", !.k = k]
Er(s, n, k, st) == [E0 EXCEPT !.s = s, !.m = "erase", !.n = n, !.k = k, !.st = st]
Rs(s, n, k, st) == [E0 EXCEPT !.s = s, !.m = "reset", !.n = n, !.k = k, !.st = st]
Calm(e) == [e EXCEPT !.q = TRUE]
After(e, i) == [e EXCEPT !.wait = i]

Script ==
    CASE Scenario = "Main"   -> << Seed("A", "a", 1), Seed("A", "b", 0),
                                  TxE("A", 1, 1), TxE("B", 2, 1), Touch("B", "a") >>
      [] Scenario = "Cross"  -> << Seed("A", "a", 1), Seed("A", "b", 1),
                                  TxE("A", 1, 1), TxE("B", 2, 2) >>
      [] Scenario = "Edit"   -> << Seed("A", "a", 1), Seed("A", "b", 0),
                                  TxE("A", 1, 1), Ed("B", 2, "a", "gd", 0) >>
      [] Scenario = "Retry"  -> << Seed("A", "a", 1), Seed("A", "b", 0),
                                  GameTx("A", 1, 1, 0), Again(GameTx("B", 1, 1, 0)) >>
      [] Scenario = "Terms"  -> << Seed("A", "a", 2), Seed("A", "b", 0), Seed("A", "c", 0),
                                  GameTx("A", 1, 1, 0), GameTx("B", 1, 3, 0) >>
      [] Scenario = "Three"  -> << Seed("A", "a", 2), Seed("A", "b", 0), Seed("A", "c", 0),
                                  TxE("A", 1, 5), TxE("B", 2, 1) >>
      [] Scenario = "Excl"   -> << Seed("A", "a", 1), Seed("A", "b", 0), Seed("A", "c", 0),
                                  TxE("A", 1, 4), Ed("B", 2, "b", "claim", 0) >>
      [] Scenario = "Owed"   -> << Seed("A", "a", 2), Seed("A", "b", 0),
                                  TxE("A", 1, 1), TxE("A", 2, 1), Touch("B", "a") >>
      [] Scenario = "Stuck"  -> << Seed("A", "a", 1), Seed("A", "b", 0),
                                  TxE("A", 1, 1), Touch("B", "a"), Touch("B", "b") >>
      [] Scenario = "Forget" -> << Seed("A", "a", 2), Seed("A", "b", 0),
                                  GameTx("A", 1, 1, 0), After(Touch("B", "b"), 3),
                                  Ed("A", 2, "b", "dc", 1), Ed("A", 3, "a", "dc", 1),
                                  After(Again(GameTx("B", 1, 1, 0)), 6) >>
      [] Scenario = "Clean"  -> << Seed("A", "a", 1),
                                  Ed("A", 1, "a", "dc", 0), Ed("B", 2, "a", "dc", 1) >>
      [] Scenario = "LateCreate" -> << Ed("A", 1, "a", "dc", 0), Er("B", 2, "a", 0) >>
      [] Scenario = "EraseSeed"  -> << Seed("A", "a", 2), Er("B", 2, "a", 0), Ed("A", 1, "a", "dc", 0) >>
      [] Scenario = "EraseLeg"   -> << Seed("A", "a", 2), Seed("A", "b", 0),
                                      TxE("A", 1, 1), Er("B", 2, "a", 0) >>
      [] Scenario = "EraseDec"   -> << Seed("A", "a", 2), Seed("A", "b", 0),
                                      TxE("A", 1, 1), Er("B", 2, "b", 0), Touch("B", "a") >>
      [] Scenario = "Orphan"     -> << Seed("A", "a", 1), TxE("A", 1, 3), Touch("B", "a") >>
      \* 5.1's point 3 says a D never made can be made only by a Commit within W[tx]; here an edit
      \* makes it after the touch that may have taken the orphan path.
      [] Scenario = "OrphanMade" -> << Seed("A", "a", 1), TxE("A", 1, 3), Touch("B", "a"),
                                      After(Ed("B", 2, "c", "dc", NONE), 3) >>
      [] Scenario = "Reseal"     -> << Seed("A", "a", 1), Er("B", 2, "a", 0), Ed("A", 1, "a", "dc", 0) >>
      \* A Reset of a transfer's sender while the transfer runs, and a retry of the Reset from the other
      \* server under the same name and stamp (cuts 3.1 to 3.3).
      \* A transfer to a key never made leaves its mark on a; a server then only writes a, by an
      \* edit the mark blocks (transaction 5.1: a touch is a read or a write; L3).
      [] Scenario = "OrphanWrite" -> << Seed("A", "a", 1), TxE("A", 1, 3), After(Ed("B", 2, "a", "gd", NONE), 2) >>
      \* Questions 19: c seeded, a transfer a to c, and a touch of a; a stale run of the touch's fence
      \* of c may report missing.
      [] Scenario = "TouchFence" -> << Seed("A", "a", 1), Seed("A", "c", 0), TxE("A", 1, 3), Touch("B", "a") >>
      \* Questions 21: a transfer a to c whose own Resolve may not land, then a touch of c, an edit on c
      \* that pushes a dropped record's decision out of T, and a touch of a.
      [] Scenario = "TouchPin" -> << Seed("A", "a", 1), Seed("A", "c", 0), TxE("A", 1, 3), After(Touch("B", "c"), 3),
                                    Ed("B", 2, "c", "dc", NONE), Touch("B", "a") >>
      \* Questions 21: the leg key a is erased after the transfer, then c is touched twice. A ProveGone
      \* that meets the eraser's fresh seal cancels; the next touch may find a absent.
      [] Scenario = "PinErased" -> << Seed("A", "a", 1), Seed("A", "c", 0), TxE("A", 1, 3), After(Er("B", 2, "a", 0), 3),
                                     Touch("B", "c"), Touch("B", "c") >>
      \* Questions 21: the claim leg's Tent makes b, b is erased, and a late run of that Tent may make b
      \* again with a mark (design rule 32); then c is touched twice, an edit on c, and b is touched.
      [] Scenario = "PinLateCreate" -> << Seed("A", "a", 1), Seed("A", "c", 0), TxE("A", 1, 4), After(Er("B", 2, "b", 0), 3),
                                         Touch("B", "c"), Touch("B", "c"), Ed("B", 3, "c", "dc", NONE), Touch("B", "b") >>
      \* Questions 15: a transfer to a key that is never made leaves its mark on a; later B erases a,
      \* and nothing else touches it.
      [] Scenario = "CutOrphan" -> << Seed("A", "a", 1), TxE("A", 1, 3), After(Er("B", 2, "a", NONE), 2) >>
      \* Questions 13: A's transfer from a and A2's edit of a are out together; B erases a, and the edit
      \* may make a again.
      [] Scenario = "SameServer" -> << Seed("A", "a", 2), Seed("A", "b", 0), TxE("A", 1, 1),
                                       Ed("A2", 2, "a", "gd", 0), Er("B", 3, "a", 0) >>
      [] Scenario = "Reset"      -> << Seed("A", "a", 2), Seed("A", "b", 0), TxE("A", 1, 1),
                                      Rs("B", 2, "a", 0), Again(Rs("A", 2, "a", 0)) >>
Idx == DOMAIN Script

\* The servers.

\* A request item to send: its key, what it is ("upd", "get", "set"), its argument, its tries.
Rq(k, op, a) == [ky |-> k, op |-> op, arg |-> [a EXCEPT !.ky = k], tr |-> 0]

L0 == [pc |-> "", i |-> 0, m |-> "", n |-> 0, st |-> 0, t |-> 0, a |-> 1, dk |-> "", ks |-> {},
       ek |-> "", mk |-> {}, todo |-> {}, out |-> {}, got |-> {}, wr |-> FALSE, er |-> FALSE,
       fgt |-> FALSE, mis |-> FALSE, rno |-> FALSE, rd |-> 0, hb |-> It0, hk |-> "", ret |-> "", rides |-> {},
       vp |-> {}, said |-> FALSE, slow |-> FALSE, cnt |-> 0, iids |-> {}, nam |-> NONE,
       npc |-> "", ntodo |-> {}, lk |-> {}, edr |-> {}, gat |-> 0, gc |-> 0, cw |-> FALSE, gu |-> FALSE]

NoIc == [m |-> "none", v |-> NoId]
\* The iid a request of this call to key k carries: taken once, when the call first needs it.
\* Before the call knows it, a placeholder: WithIds rebuilds the batch once it does.
IidOf(l, k) == IF k \notin Erasable \/ ~\E x \in l.iids : x.k = k THEN AnyId
               ELSE (CHOOSE x \in l.iids : x.k = k).iid
Arg(l) == [A0 EXCEPT !.c = l.i, !.n = l.n, !.st = l.st, !.t = l.t, !.a = l.a]
RidesOn(l, k) == {r.e : r \in {x \in l.rides : x.ky = k}}
TentItem(l, k) == Rq(k, "upd", [Arg(l) EXCEPT !.k = "tent", !.li = LegIdx(l.t, k), !.ends = RidesOn(l, k),
                                               !.iid = IidOf(l, k)])
Tents(l) == {TentItem(l, k) : k \in l.ks \ l.mk}
CommitItem(l, dr) == Rq(l.dk, "upd", [Arg(l) EXCEPT !.k = "commit", !.legs = l.ks, !.dr = dr,
                                                     !.ends = RidesOn(l, l.dk), !.iid = IidOf(l, l.dk)])
FenceItem(dk, n, a, fin, st, t, ci) ==
    Rq(dk, "upd", [A0 EXCEPT !.k = "fence", !.c = ci, !.n = n, !.a = a, !.fin = fin, !.st = st, !.t = t])
EndRec(n, a, out, st, t, dk) == [n |-> n, a |-> a, out |-> out, st |-> st, t |-> t, dk |-> dk]
ResItem(k, E, ci) == Rq(k, "upd", [A0 EXCEPT !.k = "res", !.c = ci, !.ends = E])
OwnEnd(l, out, a) == EndRec(l.n, a, out, l.st, l.t, l.dk)
\* A commit is resolved on every leg key. An abort only where a mark of this call may have landed:
\* a Tent that reported mine, that erred, or one of whose runs wrote (3.6, "each key where a mark of
\* this call landed"). A key whose Tent reported other terms, a decision or forgotten holds none.
Resolves(l, out, a) == {ResItem(k, {OwnEnd(l, out, a)}, l.i) : k \in IF out = "commit" THEN l.ks ELSE l.lk}
EditItem(l) == Rq(l.dk, "upd", [Arg(l) EXCEPT !.k = "edit", !.ek = l.ek, !.ends = RidesOn(l, l.dk),
                                              !.iid = IidOf(l, l.dk)])
\* An erase's request, or a Reset's (the same call path, cuts 3.1 to 3.3).
EraseItem(l) == Rq(l.dk, "upd", [Arg(l) EXCEPT !.k = IF l.m = "reset" THEN "reset" ELSE "erase", !.iid = IidOf(l, l.dk),
                                               !.ends = RidesOn(l, l.dk), !.dr = l.edr])
GetItem(k, ci) == Rq(k, "get", [A0 EXCEPT !.k = "get", !.c = ci])

\* The keys a call writes, and so needs an incarnation for.
CallKeys(e) == CASE e.m = "tx" -> LegKeys(e.t) [] e.m \in {"edit", "erase", "reset"} -> {e.k} [] OTHER -> {}

\* The first batch of a call in phase pc, built again once the call's ids are known.
Rebuild(l, pc, todo) ==
    CASE pc = "tent" -> Tents(l)
      [] pc = "edit" -> {EditItem(l)}
      [] pc = "erase" -> {EraseItem(l)}
      [] OTHER -> todo

\* Park the call's first batch while it reads the keys it has no incarnation for.
WithIds(s, l, keys) ==
    LET need == {k \in keys \cap Erasable : ic[Host(s)][k].m = "none"}
        l2 == [l EXCEPT !.iids = {[k |-> k, iid |-> ic[Host(s)][k]] : k \in keys \cap Erasable}]
    IN IF need = {} THEN [l2 EXCEPT !.todo = Rebuild(l2, l.pc, l.todo)]
       ELSE [l EXCEPT !.npc = l.pc, !.ntodo = l.todo, !.pc = "iread", !.todo = {GetItem(k, l.i) : k \in need}]

Begin0(s, i, e, l) ==
    CASE e.m = "seed" -> [l EXCEPT !.pc = "seed",
                                      !.todo = {Rq(e.k, "upd", [A0 EXCEPT !.k = "seed", !.sb = e.sb])}]
         [] e.m = "tx" -> LET l2 == [l EXCEPT !.dk = DOf(e.t), !.ks = LegKeys(e.t) \ {DOf(e.t)}] IN
                          IF e.retry THEN [l2 EXCEPT !.pc = "rread", !.slow = TRUE, !.todo = {GetItem(l2.dk, i)}]
                          ELSE [l2 EXCEPT !.pc = "tent", !.todo = Tents(l2)]
         [] e.m = "edit" -> LET l2 == [l EXCEPT !.dk = e.k, !.ek = e.ek] IN
                            [l2 EXCEPT !.pc = "edit", !.todo = {EditItem(l2)}]
         [] e.m = "touch" -> [l EXCEPT !.pc = "tread", !.dk = e.k, !.todo = {GetItem(e.k, i)}]
         [] e.m \in {"erase", "reset"} -> [l EXCEPT !.pc = "erase", !.dk = e.k, !.todo = {EraseItem([l EXCEPT !.dk = e.k])}]

Begin(s, i) ==
    LET e == Script[i]
        st == IF e.st = NONE THEN Clock(s) ELSE e.st
        l == [L0 EXCEPT !.i = i, !.m = e.m, !.n = e.n, !.t = e.t, !.st = st]
    IN WithIds(s, Begin0(s, i, e, l), CallKeys(e))

NextOf(s) ==
    LET open == {i \in Idx : Script[i].s = s /\ i \notin started} IN
    IF open = {} THEN 0 ELSE CHOOSE i \in open : \A j \in open : i <= j

\* The staging guards of a script call. They only stage a scenario.
Ready(i) ==
    /\ i # 0
    /\ ~Script[i].pre => \A j \in Idx : Script[j].pre => j \in finished
    /\ Script[i].wait # 0 => Script[i].wait \in finished
    /\ Script[i].q => calm

Start(s) ==
    LET i == NextOf(s) IN
    /\ up[s] /\ ls[s].pc = "" /\ Ready(i)
    /\ ls' = [ls EXCEPT ![s] = Begin(s, i)]
    /\ started' = started \cup {i}
    /\ UNCHANGED <<envVars, finished, ans, ic, gvars>>

\* Send one request of the batch, on a key the call has no request out on.
Send(s) ==
    LET l == ls[s] IN
    /\ \E it \in l.todo :
          /\ ~\E o \in l.out : o.ky = it.ky
          /\ CASE it.op = "upd" -> Issue(s, it.ky, it.arg)
               [] it.op = "get" -> IssueGet(s, it.ky, it.arg)
               \* Cuts 3.4 step 4: the sealer sends its removal only while its clock, read now, is at
               \* most RemoveSend past rt; RemoveLate counts from this read.
               [] it.op = "set" -> Clock(s) - it.arg.srt <= RemoveSend /\ IssueSet(s, it.ky, it.arg, Z)
          /\ ls' = [ls EXCEPT ![s].todo = @ \ {it},
                              ![s].out = @ \cup {[ky |-> it.ky, r |-> NextReq, it |-> it]},
                              ![s].cnt = @ + (IF it.op = "upd" THEN 1 ELSE 0)]
    /\ UNCHANGED <<started, finished, ans, ic, gvars>>

\* A removal whose moment passed before it was sent is not sent: the seal is left over (cuts 3.4 step 6).
DropLate(s) ==
    LET l == ls[s] IN
    /\ \E it \in l.todo :
          /\ it.op = "set" /\ Clock(s) - it.arg.srt > RemoveSend
          /\ ls' = [ls EXCEPT ![s].todo = @ \ {it}]
    /\ UNCHANGED <<envVars, started, finished, ans, ic, gvars>>

\* Hear the answer to one request. An error is sent again, with a fresh closure, up to Retries.
Hear(s) ==
    LET l == ls[s] IN
    \E o \in l.out, a \in Heard :
       /\ Reply(o.r, a)
       /\ LET nt == NoteOf(o.r)
              again == a = "err" /\ o.it.tr < Retries
              g == [ky |-> o.ky, op |-> o.it.op, arg |-> o.it.arg, a |-> a, nt |-> nt,
                    rd |-> IF o.it.op = "get" /\ a = "ok" THEN ReadOf(o.r).v ELSE Z]
          IN ls' = [ls EXCEPT ![s].out = @ \ {o},
                              ![s].todo = IF again
                                          THEN @ \cup {[o.it EXCEPT !.tr = @ + 1,
                                                                    !.arg.iid.m = IF FixCreateOnce /\ @ = "absent"
                                                                                  THEN "id" ELSE @]}
                                          ELSE @,
                              ![s].got = IF again THEN @ ELSE @ \cup {g},
                              ![s].wr = @ \/ a = "err" \/ (o.it.op = "upd" /\ nt.w),
                              ![s].er = @ \/ a = "err",
                              ![s].cw = @ \/ (o.it.arg.k = "commit" /\ (a = "err" \/ nt.w)),
                              ![s].lk = IF o.it.arg.k = "tent" /\ (a = "err" \/ nt.w \/ nt.r = "mine")
                                        THEN @ \cup {o.ky} ELSE @]
       /\ UNCHANGED <<started, finished, ans, ic, gvars>>

\* What a call does once its batch is heard (3.6, 4.2, 5.1).

NoRec == [i |-> 0, m |-> "", n |-> 0, t |-> 0, v |-> FALSE, r |-> "", rno |-> FALSE, unk |-> FALSE,
          fgt |-> FALSE, mis |-> FALSE, abs |-> FALSE, wr |-> 0, slow |-> FALSE, nam |-> NONE]
\* abs reads the truth, for MissingSaysAbsent only: some key the call named holds no value now.
Rec(l, v, r) == [i |-> l.i, m |-> l.m, n |-> l.n, t |-> l.t, v |-> v, r |-> r, rno |-> l.rno,
                 unk |-> l.er, fgt |-> l.fgt, mis |-> l.mis,
                 abs |-> \E k \in l.ks \cup {l.dk} : ~Cur(k).ex, wr |-> l.cnt, slow |-> l.slow,
                 nam |-> l.nam]
Go(l) == {[l |-> l, say |-> FALSE, rec |-> NoRec]}
\* Answer v, r and go on as l2. A call answers once.
Say(l, l2, v, r) == {[l |-> [l2 EXCEPT !.said = TRUE], say |-> ~l.said, rec |-> Rec(l2, v, r)]}
Fin(l) == [l EXCEPT !.pc = "fin"]
Rp(g) == IF g.a = "err" THEN "err" ELSE g.nt.r

\* Resolve every leg key but the decider, then end.
ResThen(l, out, a) == [l EXCEPT !.pc = "res", !.todo = Resolves(l, out, a)]
FenceFinal(l) == [l EXCEPT !.pc = "ff", !.slow = TRUE,
                           !.todo = {FenceItem(l.dk, l.n, l.a, TRUE, l.st, l.t, l.i)}]

\* What a read of a decider says of use n at attempt a: "commit" with its attempt, "abort", or
\* "none". Each is a fact that stays true (3.4).
DecOf(V, n, a, st) ==
    LET ps == Named(Pins(V), n)
        ds == {x \in V.T : x.c = "dec" /\ x.n = n}
        d == One(ds)
    IN IF ~V.ex THEN [d |-> "gone", a |-> 0]
       ELSE IF ps # {} THEN [d |-> "commit", a |-> One(ps).a]
       ELSE IF ds # {} /\ d.f = "took" THEN [d |-> "commit", a |-> d.a]
       ELSE IF ds # {} /\ d.f \in {"R", "F"} THEN [d |-> "abort", a |-> a]
       ELSE IF ds # {} /\ d.f = "fenced" /\ (d.fin \/ d.a >= a) THEN [d |-> "abort", a |-> a]
       ELSE IF Forgot(V, n, st) THEN [d |-> "abort", a |-> a]
       ELSE [d |-> "none", a |-> 0]

\* What a fence's report says of the use it fenced.
FenceSays(nt, a) ==
    CASE nt.r = "committed" -> [d |-> "commit", a |-> nt.fa]
      [] nt.r \in {"fenced", "refused", "forgotten"} -> [d |-> "abort", a |-> a]
      [] OTHER -> [d |-> "none", a |-> 0]

Younger(y, l) == y.st > l.st \/ (y.st = l.st /\ y.n > l.n)

\* Start helping past blockers B on key k (4.2): read the decider of one of them. gc is the clock
\* when the read is asked for, which the orphan rule reads.
Help(l, B, k, ret, clk) ==
    IF B = {} THEN Go(FenceFinal(l))
    ELSE {[l |-> [l EXCEPT !.pc = "hread", !.hb = y, !.hk = k, !.ret = ret, !.slow = TRUE, !.gc = clk,
                           !.todo = {GetItem(y.dk, l.i)}],
           say |-> FALSE, rec |-> NoRec] : y \in B}

\* Send again what was blocked, carrying the rides.
Resend(l, ride) ==
    LET l2 == [l EXCEPT !.rd = @ + 1, !.rides = @ \cup {[ky |-> l.hk, e |-> r] : r \in ride}] IN
    CASE l.ret = "tent"   -> [l2 EXCEPT !.pc = "tent", !.todo = {TentItem(l2, l.hk)}]
      [] l.ret = "commit" -> [l2 EXCEPT !.pc = "commit", !.todo = {CommitItem(l2, {})}]
      [] l.ret = "edit"   -> [l2 EXCEPT !.pc = "edit", !.todo = {EditItem(l2)}]
      [] l.ret = "touch"  -> IF ride = {} THEN Fin(l2)
                             ELSE [l2 EXCEPT !.pc = "fin2", !.todo = {ResItem(l.hk, ride, l.i)}]

BEnd(y, d) == EndRec(y.n, IF d.d = "commit" THEN d.a ELSE y.a, d.d, y.st, y.t, y.dk)

\* A verification (3.5): resolves of commit on the leg keys of each pinned record.
Verify(l, ps, pc) ==
    [l EXCEPT !.pc = pc, !.vp = ps, !.slow = TRUE,
              !.todo = UNION {{ResItem(k, {EndRec(p.n, p.a, "commit", p.st, p.t, p.dk)}, l.i) : k \in p.legs}
                              : p \in ps}]
\* A leg's Resolve of verification answered ok or done; or it reported missing.
LegDone(p, k, G) == \E g \in G : g.ky = k /\ p.n \in {e.n : e \in g.arg.ends}
                                 /\ (g.a = "ok" \/ (g.a = "nil" /\ g.nt.r = "done"))
LegMissing(p, k, G) == \E g \in G : g.ky = k /\ p.n \in {e.n : e \in g.arg.ends} /\ g.a # "err"
                                    /\ g.nt.r = "missing"
Verified(l, G) == {p \in l.vp : \A k \in p.legs : LegDone(p, k, G)}
\* Transaction 5.1 point 5: once every leg is done or missing and one is missing, a touch sends a
\* ProveGone to each missing one.
ProveLegs(l, G) ==
    IF FixPinProve /\ \A p \in l.vp : \A k \in p.legs : LegDone(p, k, G) \/ LegMissing(p, k, G)
    THEN {k \in UNION {p.legs : p \in l.vp} : \E p \in l.vp : k \in p.legs /\ LegMissing(p, k, G)}
    ELSE {}
ProveItem(k, ci) == Rq(k, "upd", [A0 EXCEPT !.k = "prove", !.c = ci])
\* The proof: a ProveGone that landed; without FixProveWrites, any answer that read the key absent.
Proved(g) == IF FixProveWrites THEN g.a = "ok" /\ g.nt.r = "proved" ELSE g.a # "err" /\ g.nt.r = "proved"
DropItem(l) == Rq(l.dk, "upd", [A0 EXCEPT !.k = "drop", !.c = l.i, !.dr = {p.n : p \in l.vp}])
\* The prover removes each seal it landed, as a sealer does (cuts 3.4 step 4).
Unseals(l, G) == {Rq(g.ky, "set", [A0 EXCEPT !.k = "remove", !.c = l.i, !.srt = g.nt.srt])
                  : g \in {h \in G : h.a = "ok" /\ h.nt.r = "proved"}}

Steps(s, l) ==
    LET G == l.got
        clk == Clock(s)
        g1 == One(G)
    IN
    CASE l.pc = "seed" -> Go(Fin(l))
      [] l.pc = "iread" ->
         \* Each read gives the key's id, or "absent" with a fresh id for a create. A failed read
         \* leaves the call to answer Unresolved: it sent nothing.
         IF \E g \in G : g.a # "ok" THEN Say(l, Fin([l EXCEPT !.er = TRUE]), FALSE, "Unresolved")
         ELSE LET got == {[k |-> g.ky, iid |-> IF g.rd.ex THEN [m |-> "id", v |-> g.rd.id]
                                               ELSE [m |-> "absent", v |-> [j |-> Job(s), n |-> l.i]]]
                          : g \in G}
                  have == {[k |-> k, iid |-> ic[Host(s)][k]] : k \in {k2 \in Erasable : ic[Host(s)][k2].m = "id"}}
                  l2 == [l EXCEPT !.iids = got \cup {x \in have : x.k \notin {y.k : y \in got}},
                                  !.pc = l.npc, !.npc = ""]
              IN Go([l2 EXCEPT !.todo = Rebuild(l2, l.npc, l.ntodo)])
      [] l.pc = "erase" ->
         LET r == Rp(g1)
             mine == g1.a = "ok" \/ (g1.a = "nil" /\ g1.nt.w)
         IN CASE r = "sealed" ->
                   \* The sealer, and only it, removes the seal once, within RemoveSend of rt (3.4 step 4).
                   LET l2 == [l EXCEPT !.nam = g1.nt.nam] IN
                   IF mine /\ g1.nt.sv = s /\ clk - g1.nt.srt <= RemoveSend
                   THEN Say(l, [l2 EXCEPT !.pc = "fin2", !.todo = {Rq(l.dk, "set", [A0 EXCEPT !.k = "remove", !.c = l.i, !.srt = g1.nt.srt])}],
                            TRUE, "")
                   ELSE Say(l, Fin(l2), TRUE, "")
              [] r = "missing" -> IF ~l.wr THEN Say(l, Fin([l EXCEPT !.mis = TRUE]), FALSE, "Missing")
                                  \* cuts 3.2: an erase whose key is gone answers true; a Reset, Unresolved.
                                  ELSE IF l.m = "reset" THEN Say(l, Fin([l EXCEPT !.mis = TRUE]), FALSE, "Unresolved")
                                  ELSE Say(l, Fin(l), TRUE, "")
              \* A Reset's reports (cuts 3.2): took, forgotten, and another cut's gate.
              [] r = "took" -> Say(l, Fin([l EXCEPT !.nam = g1.nt.nam]), TRUE, "")
              [] r = "forgotten" -> IF ~l.wr \/ ~FixCleanRule
                                    THEN Say(l, Fin([l EXCEPT !.fgt = TRUE]), FALSE, "Expired")
                                    ELSE Say(l, Fin([l EXCEPT !.fgt = TRUE]), FALSE, "Unresolved")
              [] r = "gatedBy" /\ l.rd < Retries -> Go([l EXCEPT !.rd = @ + 1, !.slow = TRUE, !.todo = {EraseItem(l)}])
              [] r = "gatedBy" -> Say(l, Fin([l EXCEPT !.er = TRUE]), FALSE, "Unresolved")
              [] r = "marks" /\ l.rd <= Retries ->
                   LET M == g1.nt.it
                       fences == {FenceItem(m.dk, m.n, m.a, FALSE, m.st, m.t, l.i) : m \in {x \in M : x.c # "pin"}}
                       vers == UNION {{ResItem(k, {EndRec(p.n, p.a, "commit", p.st, p.t, p.dk)}, l.i) : k \in p.legs}
                                      : p \in {x \in M : x.c = "pin"}}
                   IN Go([l EXCEPT !.pc = "edrain", !.slow = TRUE, !.vp = {x \in M : x.c = "pin"},
                                   !.hb = [It0 EXCEPT !.legs = {x \in M : x.c # "pin"}],
                                   !.todo = fences \cup vers])
              \* Cuts 3.2: marks still there past the retries: Unresolved, and the server keeps working the
              \* cut while it lives. The model stops; er marks the erase as still out.
              [] r = "marks" -> Say(l, Fin([l EXCEPT !.er = TRUE]), FALSE, "Unresolved")
              [] OTHER -> Say(l, Fin(l), FALSE, "Unresolved")
      [] l.pc = "tent" ->
         LET refs == {g \in G : Rp(g) = "refused" \/ (Rp(g) = "decided" /\ g.nt.df \in {"R", "F"})}
             stored == \E g \in refs : g.a = "ok" \/ Rp(g) = "decided"
             mk2 == l.mk \cup {g.ky : g \in {h \in G : Rp(h) = "mine"
                                                    \/ (~FixCommitAfterAll /\ Rp(h) = "err")}}
             l2 == [l EXCEPT !.mk = mk2]
             oth == \E g \in G : Rp(g) \in {"other", "superseded"}
                                 \/ (Rp(g) = "decided" /\ g.nt.df \in {"took", "aborted"})
             fgt == \E g \in G : Rp(g) = "forgotten"
             blk == {g \in G : Rp(g) \in {"blocked", "noroom"}}
             mis == \E g \in G : Rp(g) = "missing"
             gtd == {g \in G : Rp(g) = "gated"}
         IN IF refs # {}
            THEN Say(l, ResThen([l2 EXCEPT !.rno = stored], "abort", l.a) , FALSE, "Refused")
            ELSE IF l.ks \subseteq mk2 THEN Go([l2 EXCEPT !.pc = "commit", !.todo = {CommitItem(l2, {})}])
            ELSE IF oth THEN Go(FenceFinal(l2))
            ELSE IF fgt
                 THEN IF ~l.wr \/ ~FixCleanRule
                      THEN Say(l, Fin([l2 EXCEPT !.fgt = TRUE]), FALSE, "Expired")
                      ELSE Go(FenceFinal([l2 EXCEPT !.fgt = TRUE]))
            ELSE IF mis
                 THEN IF ~l.wr THEN Say(l, Fin([l2 EXCEPT !.mis = TRUE]), FALSE, "Missing")
                      ELSE Go(FenceFinal([l2 EXCEPT !.mis = TRUE]))
            ELSE IF gtd # {}
                 THEN IF l.rd < Retries
                      THEN Go([l2 EXCEPT !.pc = "gwait", !.ret = "tent", !.hk = One(gtd).ky, !.slow = TRUE,
                                         !.gat = One(One(gtd).nt.it).st])
                      ELSE Go(FenceFinal(l2))
            ELSE IF blk # {}
                 THEN IF l.rd < Retries THEN Help(l2, UNION {g.nt.it : g \in blk}, One(blk).ky, "tent", clk)
                      ELSE Go(FenceFinal(l2))
            ELSE Say(l, Fin(l2), FALSE, "Unresolved")
      [] l.pc = "ff" ->
         LET r == Rp(g1) IN
         CASE r = "committed" -> Say(l, ResThen(l, "commit", g1.nt.fa), TRUE, "")
           [] r = "fenced" -> Say(l, ResThen(l, "abort", l.a), FALSE, "Spent")
           [] r = "refused" -> Say(l, ResThen([l EXCEPT !.rno = TRUE], "abort", l.a), FALSE, "Refused")
           [] r = "forgotten" -> Say(l, ResThen([l EXCEPT !.fgt = TRUE], "abort", l.a), FALSE, "Unresolved")
           [] r = "missing" /\ l.rd < Retries -> Go([FenceFinal(l) EXCEPT !.rd = @ + 1, !.mis = TRUE])
           [] r = "missing" -> Say(l, Fin([l EXCEPT !.mis = TRUE]), FALSE, "Unresolved")
           [] OTHER -> Say(l, Fin(l), FALSE, "Unresolved")
      [] l.pc = "commit" ->
         LET r == Rp(g1) IN
         CASE r = "committed" -> Say(l, ResThen(l, "commit", g1.nt.fa), TRUE, "")
           [] r = "fenced" /\ ~g1.nt.rf /\ l.a < MaxAttempts ->
                LET l2 == [l EXCEPT !.a = @ + 1, !.mk = {}, !.slow = TRUE] IN
                Go([l2 EXCEPT !.pc = "tent", !.todo = Tents(l2)])
           [] r = "fenced" \/ r = "other" -> Say(l, ResThen(l, "abort", l.a), FALSE, "Spent")
           [] r = "refused" -> Say(l, ResThen([l EXCEPT !.rno = TRUE], "abort", l.a), FALSE, "Refused")
           [] r = "forgotten" -> Go(FenceFinal([l EXCEPT !.fgt = TRUE]))
           [] r = "missing" /\ g1.a = "nil" /\ ~g1.nt.w /\ ~l.cw /\ ~FixOwnEvidence ->
                \* The Commit never wrote and cannot run again (record 3.3): abort by own evidence (3.4).
                Say(l, ResThen([l EXCEPT !.mis = TRUE, !.gu = TRUE], "abort", l.a), FALSE, "Missing")
           [] r = "missing" -> Go(FenceFinal([l EXCEPT !.mis = TRUE]))
           [] r = "gated" -> IF l.rd < Retries
                             THEN Go([l EXCEPT !.pc = "gwait", !.ret = "commit", !.hk = l.dk, !.slow = TRUE,
                                               !.gat = One(g1.nt.it).st])
                             ELSE Go(FenceFinal(l))
           [] r = "owed" -> IF l.rd < Retries THEN Go(Verify(l, g1.nt.it, "ver")) ELSE Go(FenceFinal(l))
           [] r = "blocked" -> IF l.rd < Retries THEN Help(l, g1.nt.it, l.dk, "commit", clk) ELSE Go(FenceFinal(l))
           [] OTHER -> Say(l, Fin(l), FALSE, "Unresolved")
      [] l.pc = "ver" ->
         LET l2 == [l EXCEPT !.rd = @ + 1] IN
         Go([l2 EXCEPT !.pc = "commit", !.todo = {CommitItem(l2, {p.n : p \in Verified(l, G)})}])
      [] l.pc = "res" -> Go(Fin(l))
      [] l.pc = "rread" ->
         LET V == g1.rd
             d == DecOf(V, l.n, 1, l.st)
             tk == Named(Pins(V), l.n) \cup {x \in V.T : x.c = "dec" /\ x.n = l.n /\ x.f = "took"}
         IN IF g1.a = "ok" /\ d.d = "commit" /\ \A x \in tk : x.t = l.t THEN Say(l, Fin(l), TRUE, "")
            ELSE IF g1.a = "ok" /\ d.d = "commit" THEN Say(l, Fin(l), FALSE, "Spent")
            ELSE Go([l EXCEPT !.pc = "tent", !.todo = Tents(l)])
      [] l.pc = "edit" ->
         LET r == Rp(g1) IN
         CASE r = "took" -> Say(l, Fin(l), TRUE, "")
           [] r = "refused" -> Say(l, Fin([l EXCEPT !.rno = TRUE]), FALSE, "Refused")
           [] r = "other" -> Say(l, Fin(l), FALSE, "Spent")
           [] r = "forgotten" -> IF ~l.wr \/ ~FixCleanRule
                                 THEN Say(l, Fin([l EXCEPT !.fgt = TRUE]), FALSE, "Expired")
                                 ELSE Say(l, Fin([l EXCEPT !.fgt = TRUE]), FALSE, "Unresolved")
           [] r = "missing" -> IF ~l.wr THEN Say(l, Fin([l EXCEPT !.mis = TRUE]), FALSE, "Missing")
                               ELSE Say(l, Fin([l EXCEPT !.mis = TRUE]), FALSE, "Unresolved")
           \* Record 5.1, last row: an op with no fate by B_op answers Unresolved and the writer keeps
           \* sending it, so it may still take. The model stops sending after Retries rounds; unk marks
           \* the op as still out, which is what makes the answer true in the design.
           [] r = "blocked" -> IF l.rd < Retries THEN Help(l, g1.nt.it, l.dk, "edit", clk)
                               ELSE Say(l, Fin([l EXCEPT !.er = TRUE]), FALSE, "Unresolved")
           [] OTHER -> Say(l, Fin(l), FALSE, "Unresolved")
      [] l.pc = "hread" ->
         LET y == l.hb
             d == DecOf(g1.rd, y.n, y.a, y.st)
         IN IF g1.a # "ok" THEN Go(Resend(l, {}))
            ELSE IF d.d = "gone" \/ g1.rd.sl
            THEN \* Transaction 5.1: a decider that reads absent or sealed decides nothing before
                 \* OrphanAge. After it, a read asked for then is the orphan evidence, at a touch,
                 \* and a blocked writer's read is a touch (5.1: "a touch, read or write").
                 IF (l.ret = "touch" \/ FixWriterOrphan) /\ (l.gc - y.st >= OrphanAge \/ ~FixOrphanAge)
                 THEN Go(Resend(l, {EndRec(y.n, y.a, "orphan", y.st, y.t, y.dk)}))
                 ELSE Go(Resend(l, {}))
            ELSE IF d.d # "none" THEN Go(Resend(l, {BEnd(y, d)}))
            ELSE IF ~FixFenceFirst THEN Go(Resend(l, {BEnd(y, [d |-> "abort", a |-> y.a])}))
            ELSE IF Younger(y, l) \/ clk - y.st >= SettleAge
                 THEN Go([l EXCEPT !.pc = "hfence", !.todo = {FenceItem(y.dk, y.n, y.a, FALSE, y.st, y.t, l.i)}])
            ELSE Go([l EXCEPT !.pc = "hwait"])
      [] l.pc = "edrain" ->
         \* Each fence report is a fact that stays true; a pinned record goes with a verified drop.
         LET fe(m) == {g \in G : g.arg.k = "fence" /\ g.arg.n = m.n /\ g.ky = m.dk}
             ends == UNION {{BEnd(m, FenceSays(g.nt, m.a)) : g \in {h \in fe(m) : h.a # "err"
                                                                 /\ FenceSays(h.nt, m.a).d # "none"}}
                            : m \in l.hb.legs}
             l2 == [l EXCEPT !.rd = @ + 1, !.edr = @ \cup {p.n : p \in Verified(l, G)},
                             !.rides = @ \cup {[ky |-> l.dk, e |-> e] : e \in ends}]
             gone == {m \in l.hb.legs : \E g \in fe(m) : g.a # "err" /\ g.nt.r = "missing"
                                                          /\ clk - m.st >= OrphanAge}
         IN IF FixCutOrphan /\ gone # {}
            THEN Go([l2 EXCEPT !.pc = "eread", !.gc = clk, !.hb = [It0 EXCEPT !.legs = gone],
                               !.todo = {GetItem(m.dk, l.i) : m \in gone}])
            ELSE Go([l2 EXCEPT !.pc = "erase", !.todo = {EraseItem(l2)}])
      \* Cuts 3.2: the read of each gone decider is the orphan evidence when asked OrphanAge past the
      \* mark's stamp and it shows the decider absent or sealed (transaction 5.1).
      [] l.pc = "eread" ->
         LET shown(m) == {g \in G : g.ky = m.dk /\ g.a = "ok"
                                     /\ (DecOf(g.rd, m.n, m.a, m.st).d = "gone" \/ g.rd.sl)}
             ends == {EndRec(m.n, m.a, "orphan", m.st, m.t, m.dk)
                      : m \in {x \in l.hb.legs : shown(x) # {} /\ l.gc - x.st >= OrphanAge}}
             l2 == [l EXCEPT !.rides = @ \cup {[ky |-> l.dk, e |-> e] : e \in ends}]
         IN Go([l2 EXCEPT !.pc = "erase", !.todo = {EraseItem(l2)}])
      [] l.pc = "gwait"
 -> IF clk - l.gat >= SettleAge THEN Go(Resend(l, {})) ELSE {}
      [] l.pc = "hwait" -> IF clk - l.hb.st >= SettleAge
                           THEN Go([l EXCEPT !.pc = "hfence",
                                             !.todo = {FenceItem(l.hb.dk, l.hb.n, l.hb.a, FALSE, l.hb.st, l.hb.t, l.i)}])
                           ELSE {}
      [] l.pc = "hfence" ->
         LET d == FenceSays(g1.nt, l.hb.a) IN
         IF g1.a # "err" /\ d.d # "none" THEN Go(Resend(l, {BEnd(l.hb, d)}))
         ELSE IF ~FixFenceNotEvidence /\ l.ret = "touch" /\ g1.a # "err" /\ g1.nt.r = "missing"
                 /\ clk - l.hb.st >= OrphanAge
              THEN Go(Resend(l, {EndRec(l.hb.n, l.hb.a, "orphan", l.hb.st, l.hb.t, l.hb.dk)}))
         ELSE Go(Resend(l, {}))
      [] l.pc = "tread" ->
         LET V == g1.rd
             old == {m \in V.P : clk - m.st >= SettleAge}
         IN IF g1.a # "ok" \/ old = {} THEN Go(Fin(l))
            ELSE {[l |-> IF m.c = "pin" THEN Verify(l, {m}, "tver")
                         ELSE [l EXCEPT !.pc = "hread", !.hb = m, !.hk = l.dk, !.ret = "touch", !.gc = clk,
                                        !.todo = {GetItem(m.dk, l.i)}],
                   say |-> FALSE, rec |-> NoRec] : m \in old}
      [] l.pc = "tver" ->
         IF Verified(l, G) = l.vp
         THEN Go([l EXCEPT !.pc = "fin2", !.todo = {DropItem(l)}])
         ELSE IF ProveLegs(l, G) # {}
         THEN Go([l EXCEPT !.pc = "tprove", !.todo = {ProveItem(k, l.i) : k \in ProveLegs(l, G)}])
         ELSE Go(Fin(l))
      [] l.pc = "tprove" ->
         IF \A g \in G : Proved(g)
         THEN Go([l EXCEPT !.pc = "fin2", !.todo = {DropItem(l)} \cup Unseals(l, G)])
         ELSE Go([l EXCEPT !.pc = "fin2", !.todo = Unseals(l, G)])
      [] l.pc = "fin2" -> Go(Fin(l))

Proceed(s) ==
    LET l == ls[s] IN
    /\ up[s] /\ l.pc # "" /\ l.todo = {} /\ l.out = {}
    /\ \E nx \in Steps(s, l) :
          /\ ls' = [ls EXCEPT ![s] = IF nx.l.pc = "fin" THEN L0 ELSE [nx.l EXCEPT !.got = {}]]
          /\ finished' = IF nx.l.pc = "fin" THEN finished \cup {l.i} ELSE finished
          /\ ans' = IF nx.say THEN ans \cup {nx.rec} ELSE ans
          /\ ic' = IF l.pc = "iread"
                   THEN [ic EXCEPT ![Host(s)] = [k \in Keys |->
                           IF \E x \in nx.l.iids : x.k = k /\ x.iid.m = "id"
                           THEN (CHOOSE x \in nx.l.iids : x.k = k).iid ELSE ic[Host(s)][k]]]
                   ELSE IF LearnAtEnd /\ nx.l.pc = "fin"
                   THEN [ic EXCEPT ![Host(s)] = [k \in Keys |->
                           IF \E x \in l.iids : x.k = k /\ x.iid.m = "id"
                           THEN (CHOOSE x \in l.iids : x.k = k).iid ELSE ic[Host(s)][k]]]
                   ELSE ic
          \* The coordinator's own evidence of 3.4: its Commit answered missing while clean, so it sends
          \* no Commit of this attempt again. A ghost fact, as a fence is; a Commit of it landing after
          \* is CommitAfterNever.
          /\ gave' = IF nx.l.gu /\ ~l.gu THEN gave \cup {[n |-> l.n, a |-> l.a, dk |-> l.dk]} ELSE gave
    /\ UNCHANGED <<envVars, started, dec, comAt, comT, committer, applied, fenced, finF, refd, made, edTook,
                   edBy, bad, edIds, late, lossOf, orph, incN>>

\* The ghost observer: it reads the fx of each landing and nothing else.

\* The decider of use n shows it forgotten and holds no decision of it. Read from the truth.
DForgot(n, dk, st) == LET V == Cur(dk) IN V.ex /\ Forgot(V, n, st)
NeverCommits(n, a, dk, st) ==
    \/ fenced[n][dk] >= a \/ finF[n][dk] \/ refd[n][dk] \/ orph[n][dk]
    \/ [n |-> n, a |-> a, dk |-> dk] \in gave
    \/ dec[n] = "commit" /\ comAt[n] # a
    \/ DForgot(n, dk, st)

ObsFx(k, fx) ==
    LET cs == {e \in fx : e.e = "commit"}
        aps == {e \in fx : e.e = "apply"}
        rms == {e \in fx : e.e = "rm"}
        fes == {e \in fx : e.e = "fence"}
        rjs == {e \in fx : e.e \in {"Rleg", "Rdec"}}
        eds == {e \in fx : e.e = "edit"}
        sds == {e \in fx : e.e = "seed"}
        ers == {e \in fx : e.e = "erase"}
        rcs == {e \in fx : e.e = "cut"}
        lts == {e \in fx : e.e = "late"}
        ors == {e \in fx : e.e = "orphan"}
        crs == {e \in fx : e.e = "create"}
        inc2 == incN[k] + (IF crs # {} THEN 1 ELSE 0)
        com(n) == {e \in cs : e.n = n}
        dec2 == [n \in Names |-> IF com(n) # {} THEN "commit" ELSE dec[n]]
        comAt2 == [n \in Names |-> IF com(n) # {} THEN One(com(n)).a ELSE comAt[n]]
    IN
    /\ dec' = dec2
    /\ comAt' = comAt2
    /\ comT' = [n \in Names |-> IF com(n) # {} THEN One(com(n)).t ELSE comT[n]]
    /\ committer' = [n \in Names |-> IF com(n) # {} THEN One(com(n)).c ELSE committer[n]]
    /\ applied' = [n \in Names |-> [kk \in Keys |->
                     applied[n][kk] + (IF kk = k THEN Cardinality({e \in cs \cup aps : e.n = n}) ELSE 0)]]
    /\ fenced' = [n \in Names |-> [d \in Keys |->
                     IF \E e \in fes : e.n = n /\ e.dk = d /\ e.a > fenced[n][d]
                     THEN (CHOOSE e \in fes : e.n = n /\ e.dk = d).a ELSE fenced[n][d]]]
    /\ finF' = [n \in Names |-> [d \in Keys |-> finF[n][d] \/ \E e \in fes : e.n = n /\ e.dk = d /\ e.fin]]
    /\ refd' = [n \in Names |-> [d \in Keys |-> refd[n][d] \/ \E e \in rjs : e.n = n /\ e.dk = d]]
    /\ made' = made + SumAmt(eds) + SumAmt(sds) + SumAmt(ers) + SumAmt(rcs)
    /\ incN' = [incN EXCEPT ![k] = inc2]
    /\ gave' = gave
    /\ edIds' = [n \in Names |-> edIds[n] \cup (IF \E f \in eds : f.n = n THEN {<<k, inc2>>} ELSE {})]
    /\ late' = late \cup {e.n : e \in lts}
    /\ lossOf' = [n \in Names |-> IF \E e \in ers \cup rcs : e.n = n THEN (CHOOSE e \in ers \cup rcs : e.n = n).amt
                                  ELSE lossOf[n]]
    /\ orph' = [n \in Names |-> [d \in Keys |-> orph[n][d] \/ \E e \in ors : e.n = n /\ e.dk = d]]
    /\ edTook' = [n \in Names |-> edTook[n] + Cardinality({e \in eds : e.n = n})]
    /\ edBy' = [n \in Names |-> IF \E e \in eds : e.n = n THEN (CHOOSE e \in eds : e.n = n).c ELSE edBy[n]]
    /\ bad' = bad
              \cup (IF \E e \in cs : NeverCommits(e.n, e.a, k, e.st) THEN {"CommitAfterNever"} ELSE {})
              \cup (IF \E e \in cs : dec[e.n] = "commit" THEN {"CommitTwice"} ELSE {})
              \cup (IF \E e \in aps : dec2[e.n] # "commit" \/ comAt2[e.n] # e.a THEN {"ApplyAttempt"} ELSE {})
              \cup (IF \E e \in rms : ~NeverCommits(e.n, e.a, e.dk, e.st) THEN {"EndUndecided"} ELSE {})
              \cup (IF \E e \in ers \cup rcs : lossOf[e.n] # NONE THEN {"CutTwice"} ELSE {})

Obs ==
    LET kk == {k \in Keys : ver'[k] # ver[k]} IN
    IF kk = {} THEN UNCHANGED gvars
    ELSE LET k == CHOOSE k \in kk : TRUE IN ObsFx(k, hist'[k][ver'[k]].fx)

Init ==
    /\ EnvInit(Z, 0)
    /\ ls = [s \in Servers |-> L0]
    /\ started = {}
    /\ finished = {}
    /\ ans = {}
    /\ ic = [s \in Servers |-> [k \in Keys |-> NoIc]]
    /\ dec = [n \in Names |-> "none"]
    /\ comAt = [n \in Names |-> 0]
    /\ comT = [n \in Names |-> 0]
    /\ committer = [n \in Names |-> 0]
    /\ applied = [n \in Names |-> [k \in Keys |-> 0]]
    /\ fenced = [n \in Names |-> [d \in Keys |-> 0]]
    /\ finF = [n \in Names |-> [d \in Keys |-> FALSE]]
    /\ refd = [n \in Names |-> [d \in Keys |-> FALSE]]
    /\ made = 0
    /\ edTook = [n \in Names |-> 0]
    /\ edBy = [n \in Names |-> 0]
    /\ bad = {}
    /\ edIds = [n \in Names |-> {}]
    /\ late = {}
    /\ lossOf = [n \in Names |-> NONE]
    /\ orph = [n \in Names |-> [d \in Keys |-> FALSE]]
    /\ incN = [k \in Keys |-> 0]
    /\ gave = {}

\* The two platform bounds safety rests on (section 5.1, cuts 3.4 step 6), as constraints on the
\* environment a config may switch off with NONE. RemoveLate: a RemoveAsync lands no later than
\* RemoveLate ticks after it was sent. ReadLag: a GetAsync reads a version that was current no more
\* than ReadLag ticks before the tick it reads at.
RemoveLateOK ==
    RemoveLate = NONE \/
    \A r \in DOMAIN req' :
        (req'[r].kind = "set" /\ req'[r].made # {} /\ (r \notin DOMAIN req \/ req[r].made = {}))
            => now - req'[r].at <= RemoveLate
ReadLagOK ==
    ReadLag = NONE \/
    \A r \in DOMAIN req' :
        (req'[r].kind = "get" /\ req'[r].ph = "read" /\ r \in DOMAIN req /\ req[r].ph = "sent")
            => \/ req'[r].rv = ver[req'[r].key]
               \/ curAt[req'[r].key][req'[r].rv + 1] >= now - ReadLag

\* Only the environment lands a write or fixes a read, so the bounds constrain its step alone.
EnvStep == EnvNext(Tf, MsTf, FALSE) /\ RemoveLateOK /\ ReadLagOK /\ Obs /\ UNCHANGED lvars

Next ==
    \/ EnvStep
    \/ \E s \in Servers : /\ Crash(s)
                          /\ ls' = [ls EXCEPT ![s] = L0]
                          /\ ic' = [ic EXCEPT ![s] = [k \in Keys |-> NoIc]]
                          /\ UNCHANGED <<started, finished, ans, gvars>>
    \/ /\ CrashAll
       /\ ls' = [s \in Servers |-> L0]
       /\ ic' = [s \in Servers |-> [k \in Keys |-> NoIc]]
       /\ UNCHANGED <<started, finished, ans, gvars>>
    \/ \E s \in Servers : Restart(s) /\ UNCHANGED <<lvars, gvars>>
    \/ \E s \in Servers : Start(s) \/ Send(s) \/ DropLate(s) \/ Hear(s) \/ Proceed(s)

Spec == Init /\ [][Next]_vars

\* The properties.

\* A key's balance counts the escrow marks of legs that committed and are not yet resolved: those
\* legs took effect at the commit (S4's note).
Bal(k) ==
    LET V == Cur(k) IN
    IF ~V.ex THEN 0
    ELSE V.g + SumAmt({m \in V.P : m.c = "esc" /\ dec[m.n] = "commit" /\ m.a = comAt[m.n]})

RECURSIVE SumBal(_)
SumBal(S) == IF S = {} THEN 0 ELSE LET k == One(S) IN Bal(k) + SumBal(S \ {k})

\* S1
Conservation == SumBal(Keys) = made

\* S8, in the form of the game's one rule: no balance goes below 0.
NonNeg == \A k \in Keys : Bal(k) >= 0

MarkStands(n, a, k) == \E m \in Cur(k).P : m.c \in {"esc", "exc"} /\ m.n = n /\ m.a = a

\* S4. A committed leg is taken, or its mark of the committed attempt still stands.
AllOrNone ==
    \A n \in Names :
        /\ \A k \in Keys : applied[n][k] <= 1
        /\ dec[n] # "commit" => \A k \in Keys : applied[n][k] = 0
        /\ dec[n] = "commit" =>
              \A k \in Keys :
                 IF k \in LegKeys(comT[n])
                 THEN applied[n][k] = 1 \/ MarkStands(n, comAt[n], k)
                 ELSE applied[n][k] = 0
DecideOnce == "CommitAfterNever" \notin bad /\ "CommitTwice" \notin bad
MarkEndsDecided == "EndUndecided" \notin bad
ApplyRight == "ApplyAttempt" \notin bad
\* S5 for cuts (B43, B54): a cut's name takes effect once; a retry never cuts twice.
CutOnce == "CutTwice" \notin bad

\* S5, for names that carry a first send time: every name here does.
\* An edit takes effect at most once on each incarnation of its key.
AtMostOnce == \A n \in Names : edTook[n] <= Cardinality(edIds[n]) /\ \A k \in Keys : applied[n][k] <= 1

\* A2 and S7
TrueCommitted == \A a \in ans : a.m = "tx" /\ a.v => dec[a.n] = "commit" /\ comT[a.n] = a.t
TrueEdit == \A a \in ans : a.m = "edit" /\ a.v => edTook[a.n] >= 1

Definite == {"Refused", "Spent", "Full", "Expired", "NoRoom", "Missing", "Behind", "Busy"}

\* A3
NoMeansNever == \A a \in ans : a.r \in Definite => committer[a.n] # a.i /\ edBy[a.n] # a.i
NoForName ==
    \A a \in ans : a.r \in {"Refused", "Spent", "Full"} =>
        /\ a.m = "tx" => dec[a.n] # "commit" \/ (a.r = "Spent" /\ comT[a.n] # a.t)
        /\ a.m = "edit" => edTook[a.n] = 0 \/ a.r = "Spent"
RulesSaidNo == \A a \in ans : a.r = "Refused" => a.rno
ExpiredForgot == \A a \in ans : a.r = "Expired" => a.fgt

\* A5
\* A report of missing from a cancel counts as not knowing: a run may read a version from before
\* the key was made (design rule 2, D7), however often it is sent again.
UnresolvedOnlyWhenUnknown == \A a \in ans : a.r = "Unresolved" => a.unk \/ a.fgt \/ a.mis

\* The meaning record 5.1 gives Missing: the key holds no value it may write. Not part of Safety:
\* it is a check of that row against design rule 2, and a cancel may have read an old version.
MissingSaysAbsent == \A a \in ans : a.r = "Missing" => a.abs

\* C3: a transaction of N legs that met nothing, and whose requests heard no error, answers true
\* after N writes. A request that errs is sent again, which C3's "with no faults" leaves out.
CostBound == \A a \in ans : a.m = "tx" /\ a.v /\ ~a.slow /\ ~a.unk => a.wr = Len(Legs(a.t))

Safety ==
    /\ Conservation /\ NonNeg /\ AllOrNone /\ DecideOnce /\ MarkEndsDecided /\ ApplyRight
    /\ AtMostOnce /\ TrueCommitted /\ TrueEdit /\ NoMeansNever /\ NoForName /\ RulesSaidNo
    /\ ExpiredForgot /\ UnresolvedOnlyWhenUnknown /\ CostBound

\* design rule 32: a create that brings an erased key back, applying its op a second time, warns
\* LateCreate. Here: a name that took effect on two incarnations of a key was warned. An incarnation is
\* counted by the creations of its key, since a create that runs again makes the key under the same id.
LateCreateWarned == \A n \in Names : Cardinality(edIds[n]) >= 2 => n \in late

\* S5 across an erase, for requests sent before it too: an edit's name takes effect once in all.
\* The design keeps it only for requests sent after the erase (design rule 32); FixCreateOnce is checked
\* against it.
OnceAcrossErase == \A n \in Names : edTook[n] <= 1

\* S2 for an erase (design rule 29): an erase that answers true with namings names exactly what its
\* seal destroyed.
EraseNamed == \A a \in ans : a.m = "erase" /\ a.v /\ a.nam # NONE => lossOf[a.n] = -a.nam

\* A probe, not a property: it fails once some edit answers true, so a fix that passes is not
\* passing by refusing every edit.
NoEditTrue == ~\E a \in ans : a.m = "edit" /\ a.v

\* A probe, not a property: it fails once some behaviour runs the whole script.
\* OrphanWrite: the edit the orphaned mark blocks never takes. Without FixWriterOrphan it holds,
\* since only a read touch ends the mark; with it, the edit takes once the writer's read is old enough.
OrphanEditBlocked == edTook[2] = 0
ScriptUnfinished == ~(Idx \subseteq finished)
\* Probes, not properties. PinErased: use 1's pinned record stays on c after its leg key a is gone.
\* Without FixPinProve it holds; with it, the record leaves once a ProveGone lands on a.
PinStays == ~(dec[1] = "commit" /\ ~Cur("a").ex /\ Cur("c").ex /\ Pins(Cur("c")) = {})
\* CutOrphan: no orphan end of use 1 lands. Without FixCutOrphan it holds, since nothing but the cut
\* touches a; with it, the cut's read of c ends the mark.
CutNoOrphan == ~orph[1]["c"]

\* Debug probe (not in EXPECT), for OrphanMade: fails once a touch ended use 1's mark on a by the
\* orphan rule (orph is by decider) and its decider c then exists.
DbgOrphanMade == ~(orph[1]["c"] /\ Cur("c").ex)
DbgOrphan == ~orph[1]["c"]
DbgMadeC == ~Cur("c").ex
\* Debug probes (not in EXPECT), for Reset: a Reset answers true; a Reset's gate stands over a mark;
\* a Reset took after its gate made it wait (the name in K of a key that once held its gate).
DbgResetTrue == ~\E a \in ans : a.m = "reset" /\ a.v
DbgResetGate == ~\E k \in Keys : Cur(k).ex /\ Cur(k).G.kd = "reset" /\ Marks(Cur(k)) # {}
DbgResetAfterGate == ~\E k \in Keys : \E i \in 1..ver[k] :
    hist[k][i].G.kd = "reset" /\ \E x \in Cur(k).K : x.n = hist[k][i].G.n

=============================================================================
