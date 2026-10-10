------------------------------ MODULE ListPass ------------------------------
\* A toy that shows a listing with excludeDeleted may end without a key
\* that held a value when it began and holds one when it ends. On Roblox a
\* page reads up to 50 keys at one moment, and the cursor then passes them
\* for good [D20]. A key removed when the page that covers it is read, and
\* written again before the listing ends, is not listed.
\*
\* A writer writes two keys with an UpdateAsync each. Once both answer
\* "ok", a lister opens a listing with excludeDeleted and pages until it
\* ends. Meanwhile the writer writes the first key again. With Removes it
\* first removes that key with a RemoveAsync, so the key is removed for a
\* while and then holds a value again.
\*
\* FoundAll says a listing that ended returned every key that held a value
\* both when it began and when it ended. With Removes it fails: a page
\* that returns the second key while the first is removed passes over the
\* first, and the listing ends without it after the key is written again.
\* So a pass that must find every key that holds a value at its end needs
\* a second pass. Without Removes the first key never lacks a value, no
\* page passes over it, and FoundAll holds.
EXTENDS Env

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
ListPass_typedefs == TRUE

CONSTANTS
    \* @type: Bool;
    Removes,
    \* @type: Str;
    Wr,
    \* @type: Str;
    Ls,
    \* @type: Str;
    K1,
    \* @type: Str;
    K2

VARIABLES
    \* @type: Str;
    wpc,
    \* @type: Int;
    wq,
    \* @type: Str;
    lpc,
    \* @type: Set(Str);
    listed,
    \* @type: Set(Str);
    began,
    \* @type: Set(Str);
    ended

vars == <<envVars, wpc, wq, lpc, listed, began, ended>>

\* Every write writes 1.
\* @type: ($ctx, $val) => $out;
Tf(c, v) == Write(c, 1)

\* No MemoryStore UpdateAsync is sent.
\* @type: ($ctx, $view) => $mout;
MsTf(c, it) == MsCancel(c, it)

\* The keys that hold a value now.
Held == {k \in Keys : ~Absent(k, Cur(k))}

Init ==
    /\ EnvInit(0, 0)
    /\ wpc = "one" /\ wq = 0
    /\ lpc = "wait" /\ listed = {} /\ began = {} /\ ended = {}

\* The writer writes K1, then K2, then removes K1 when Removes, then writes K1 again.
WSend ==
    /\ wpc \in {"one", "two", "remove", "again"}
    /\ CASE wpc = "one" -> Issue(Wr, K1, 1)
         [] wpc = "two" -> Issue(Wr, K2, 1)
         [] wpc = "remove" -> IssueSet(Wr, K1, 0, 0)
         [] OTHER -> Issue(Wr, K1, 1)
    /\ wq' = NextReq
    /\ wpc' = CASE wpc = "one" -> "oneWait" [] wpc = "two" -> "twoWait"
                 [] wpc = "remove" -> "removeWait" [] OTHER -> "againWait"
    /\ UNCHANGED <<lpc, listed, began, ended>>

WHear ==
    /\ wpc \in {"oneWait", "twoWait", "removeWait", "againWait"}
    /\ \E a \in Heard :
          /\ Reply(wq, a)
          /\ wpc' = IF a # "ok" THEN "stop"
                    ELSE CASE wpc = "oneWait" -> "two"
                           [] wpc = "twoWait" -> IF Removes THEN "remove" ELSE "again"
                           [] wpc = "removeWait" -> "again"
                           [] OTHER -> "done"
    /\ UNCHANGED <<wq, lpc, listed, began, ended>>

\* The lister begins once both keys hold a value.
Begin ==
    /\ lpc = "wait"
    /\ wpc \in {"remove", "again"}
    /\ ListStart(Ls, TRUE)
    /\ began' = Held
    /\ lpc' = "page"
    /\ UNCHANGED <<wpc, wq, listed, ended>>

Ask ==
    /\ lpc = "page"
    /\ ListAsk(Ls)
    /\ lpc' = "paging"
    /\ UNCHANGED <<wpc, wq, listed, began, ended>>

Page ==
    /\ lpc = "paging"
    /\ \E k \in Keys, a \in ListHeard :
          /\ ListPage(Ls, k, a)
          /\ CASE a = "ok" -> listed' = listed \cup {k} /\ lpc' = "page" /\ UNCHANGED ended
               [] a = "end" -> lpc' = "end" /\ ended' = Held /\ UNCHANGED listed
               [] OTHER -> lpc' = "stop" /\ UNCHANGED <<listed, ended>>
    /\ UNCHANGED <<wpc, wq, began>>

Next ==
    \/ EnvNext(Tf, MsTf, FALSE) /\ UNCHANGED <<wpc, wq, lpc, listed, began, ended>>
    \/ WSend \/ WHear \/ Begin \/ Ask \/ Page

FoundAll == lpc = "end" => began \cap ended \subseteq listed
=============================================================================
