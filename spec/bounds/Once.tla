-------------------------------- MODULE Once --------------------------------
\* Once checks bounds T06 and T07 over every design of a bounded class.
\* It is not a design. Each initial state is one design, and TLC checks
\* every one of them.
\*
\* WHAT IT MODELS
\*
\* One key receives named ops. Its value is one of the memory values in
\* Mem. A design is an initial value m0 and a transform d. The transform
\* reads the value and the op, and returns whether the op takes effect and
\* the next value. It runs on the value it read and the argument its
\* server gave it, and it reads no other key [D2, D5]. D3 also lets a
\* transform read its server's clock, its server's memory and the note its
\* last run left. This class leaves those out: every run on the same value
\* and argument returns the same result. So the class holds every dedupe
\* rule without clocks or server memory that a key can run inside a value
\* of |Mem| states. T06 steps A.3 and C.3 carry the bound to the rest,
\* since in their paired runs the clock and the memory read the same.
\*
\* An op is a name and a flag. Names are sent in the order 1, 2, and so
\* on, so a name stands for its first send time too, and a design may use
\* that order. Flag 0 marks the first request of a name and flag 1 a
\* retry. With Flags = {0} an op carries its name alone.
\*
\* A history is a sequence of arrivals at the key, in the key's write
\* order [D4]. Any request may fail before it takes effect [D11], so a
\* name may never arrive, or arrive first as a retry. A request may land
\* late by any amount [D13], so arrivals of one name may come in any order
\* and after other names. Late bounds how late an arrival may be: the
\* number of names sent after it that arrived before it. With two names,
\* Late = 1 leaves lateness unbounded.
\*
\* A design breaks a history when a name takes effect twice, which S5
\* forbids, or when an arrival that must take effect does not. Fresh says
\* which arrivals must:
\*   "all"        the first arrival of every name. This is exactly once.
\*   "newest"     the first arrival of a name when no name sent after it
\*                arrived before it. Late first arrivals may be refused.
\*   "originals"  the first arrival of a name when it is the first
\*                request, flag 0. Every retry may be refused.
\*
\* SomeHistoryBreaks says the design in this state breaks some history.
\* A pass means every design of the class breaks. A violation means some
\* design survives every history, and TLC prints it.
\*
\* WHAT IT LEAVES OUT
\*
\* Conflicts and reruns: the key applies one arrival at a time, which is
\* what D2 to D4 give. Stale cancels [D7]: a design that skips on a stale
\* read only has less to go on. The server's own memory: a retry comes
\* from a server that heard an error, which says nothing [D12], or from a
\* new process that knows nothing [S1]. MemoryStore, which can lose any
\* item [M7]. Other keys, which a transform cannot read [D5]. The game's
\* state: it is part of the value, so Mem stands for the whole value.
\* Sizes: two or three names, two or three values, histories of at most
\* MaxLen arrivals. Bounds T06 and T07 give the argument at every size.
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Mem,    \* the values the key can hold
    Names,  \* the names, as 1..n, in the order they were first sent
    Flags,  \* {0}, or {0, 1} when an op says whether it is a retry
    MaxLen, \* the longest history
    Late,   \* how late an arrival may be, in names sent after it
    Fresh   \* which arrivals must take effect

ASSUME
    /\ Mem # {} /\ Names \subseteq Nat \ {0} /\ Names # {}
    /\ Flags \in {{0}, {0, 1}}
    /\ MaxLen \in Nat \ {0} /\ Late \in Nat
    /\ Fresh \in {"all", "newest", "originals"}

Op == Names \X Flags

\* Every transform on this key: from the value read and the op, to whether
\* the op takes effect and the value written.
Design == [Mem \X Names \X Flags -> BOOLEAN \X Mem]

VARIABLES d, m0
vars == <<d, m0>>

Init == d \in Design /\ m0 \in Mem
Next == UNCHANGED vars

\* The histories.

Seqs == UNION {[1..k -> Op] : k \in 1..MaxLen}

\* The names sent after the name of arrival i that arrived before it.
Lateness(h, i) ==
    Cardinality({n \in Names : n > h[i][1] /\ \E j \in 1..(i - 1) : h[j][1] = n})

\* A name has one first request. Retries may be many.
OneFirst(h) ==
    1 \in Flags => \A n \in Names : Cardinality({i \in DOMAIN h : h[i] = <<n, 0>>}) <= 1

Hist == {h \in Seqs : OneFirst(h) /\ \A i \in DOMAIN h : Lateness(h, i) <= Late}

\* One design run on one history.

\* The value the key holds when arrival i comes.
RECURSIVE ValueAt(_, _, _, _)
ValueAt(dd, mm, h, i) ==
    IF i = 1 THEN mm
    ELSE dd[<<ValueAt(dd, mm, h, i - 1), h[i - 1][1], h[i - 1][2]>>][2]

\* Arrival i takes effect.
Takes(dd, mm, h, i) == dd[<<ValueAt(dd, mm, h, i), h[i][1], h[i][2]>>][1]

FirstOf(h, i) == \A j \in 1..(i - 1) : h[j][1] # h[i][1]

\* Arrival i must take effect.
Must(h, i) ==
    /\ FirstOf(h, i)
    /\ CASE Fresh = "all"       -> TRUE
         [] Fresh = "newest"    -> \A j \in 1..(i - 1) : h[j][1] < h[i][1]
         [] Fresh = "originals" -> h[i][2] = 0

Breaks(dd, mm, h) ==
    \/ \E n \in Names :
          Cardinality({i \in DOMAIN h : h[i][1] = n /\ Takes(dd, mm, h, i)}) > 1
    \/ \E i \in DOMAIN h : Must(h, i) /\ ~Takes(dd, mm, h, i)

SomeHistoryBreaks == \E h \in Hist : Breaks(d, m0, h)
=============================================================================
