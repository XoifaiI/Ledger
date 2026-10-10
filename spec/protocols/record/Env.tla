-------------------------------- MODULE Env --------------------------------
\* Env is the one environment every protocol spec builds on. It models
\* what Roblox promises about the datastore, MemoryStore, servers and
\* clocks. Where Roblox promises nothing, it assumes the worst case, and a
\* switch or a bound can narrow it. A check that narrows it says so. Each
\* fact it uses has an id in the platform facts, given in brackets.
\*
\* WHAT A PROTOCOL ADDS
\*
\* A protocol EXTENDS Env. Its own type aliases replace the three defaults
\* below: val for a stored value, arg for the argument a call carries, and
\* item for a MemoryStore item. Then it adds these:
\*   1. One datastore transform Tf(c, v). Here v is the value the
\*      transform read. c holds the rest of what it gets. c.srv is the
\*      server it runs on. c.arg is the argument the server gave the call.
\*      c.note is what the last run of the call's closure left, and before
\*      any run the argument of the call that made the closure. c.info is
\*      the UpdatedTime stamp of the version it read, or NoStamp when that
\*      version holds z [D17]. Tf may read Clock(c.srv), Job(c.srv) and
\*      the protocol's own variables of c.srv as they are when it runs,
\*      since a Luau transform reads its upvalues then [D3]. Tf writes
\*      nothing. Write(c, x) writes x, and Cancel(c, x) writes nothing and
\*      hands x back. Both leave the note at c.arg, so a transform that
\*      uses only them resets its note on every run. WriteNote(x, n) and
\*      CancelNote(x, n) leave note n instead. A Luau transform that
\*      returns nil cancels, and so does one that throws [D6]. A protocol
\*      models both with Cancel or CancelNote, and x does not matter then,
\*      since a server reads res only after an "ok". So no UpdateAsync
\*      removes a key, and only IssueSet does [D6, D18]. A protocol with
\*      several kinds of call dispatches on c.arg.
\*      z means no value, and nothing else. So z lies outside every value
\*      a transform of the protocol writes and every value it passes to
\*      SetAsync. On Roblox a transform that returns the default record,
\*      or the number 0, writes a version, and GetAsync answers that value
\*      with key info [D6, D17]. Env would read such a version as a
\*      removed key. So a protocol picks a z no reducer of its own can
\*      compute, such as a record with a flag every write sets. Env does
\*      not turn a write of z into anything else. The run records it, and
\*      EnvNoZWrite fails in that state. A protocol checks EnvNoZWrite, or
\*      EnvHolds, which holds it. The one lawful z a protocol passes is to
\*      IssueSet, as RemoveAsync.
\*   2. One MemoryStore transform MsTf(c, it), in the same form [M10].
\*      Here it is the item the transform read. MsWrite(c, x) writes the
\*      value x, and the item holds it for the expiry its call carries,
\*      which the server fixed when it sent the call [M4]. So a run cannot
\*      choose the expiry, or choose to remove the item, from what it
\*      read. MsCancel(c, it) writes nothing. MsWriteNote(x, n) and
\*      MsCancelNote(it, n) leave note n. MsThrow(c) writes nothing and
\*      leaves the note at c.arg, and MsThrowNote(n) leaves note n. A
\*      MemoryStore transform that throws raises TransformCallbackFailed
\*      to the caller, unlike a datastore transform [M10]. So after a
\*      throw the call ends, and it answers only "err", at no fault. A
\*      write the call applied before, under LoseCommit, keeps its effect.
\*      A transform may run under a guard that throws on a throw or a
\*      yield. So a protocol models with MsThrow a transform that may
\*      throw, that may yield under such a guard, or that may decode an
\*      item the service mangled [M4, D27]. c.info is 0. A protocol that
\*      sends no MemoryStore UpdateAsync defines MsTf(c, it) ==
\*      MsCancel(c, it).
\*   3. Init == EnvInit(z, zi) /\ its own init. Every key starts at z,
\*      which stands for a key that does not exist, and which no write of
\*      the protocol makes but a RemoveAsync. Every MemoryStore key
\*      starts with no item. zi is the value a read of a missing item
\*      shows.
\*   4. A Next with these disjuncts:
\*         EnvNext(Tf, MsTf, Hold) /\ UNCHANGED its own variables;
\*         \E s \in Servers: Crash(s) /\ its reset of what s knew;
\*         CrashAll /\ its reset of what every server knew;
\*         \E s \in Servers: Restart(s) /\ its start of s;
\*         its own steps.
\*      A step that calls the platform conjoins one of Issue, IssueAgain,
\*      IssueSet, IssueGet, Reply, ListAsk, ListPage, MsIssue, MsIssueSet,
\*      MsIssueGet or MsReply. Each of these sends or answers one call. It
\*      changes req, mreq or lst, and it keeps the other two. So two of
\*      them in one step contradict each other, and that step has no
\*      successor. A step therefore makes one call at most, and no step
\*      reads two keys at one instant [D5]. ListStart only opens a listing
\*      and sends nothing. Every other step conjoins UNCHANGED envVars.
\*      Hold is a state predicate over the protocol's variables. Once
\*      calm, Tick waits while Hold is TRUE. A protocol that bounds a
\*      chain of its own steps in ticks makes Hold TRUE while such a step
\*      is enabled, such as the send of the next call of a chain. That is
\*      a bound for liveness: once calm, a step Hold names takes no tick.
\*      Hold names only a step that sends a call or makes no call. It
\*      never names a step that conjoins Reply, MsReply or ListPage. Time
\*      would then wait for the answer, and the answer would come in 0
\*      ticks with no platform bound behind it. Only DelayAfterCalm bounds
\*      when an answer comes. A safety check passes FALSE. Hold is best
\*      written as ENABLED of the step it names, so that it turns FALSE
\*      when a guard of Env, such as MaxReqs or a server that is down,
\*      disables that step. A Hold that stays TRUE while its step cannot
\*      run stops time for ever.
\*   5. For liveness, EnvFair(Tf, MsTf, Hold) with the same Hold, and weak
\*      fairness on its own steps. A liveness config of a model with
\*      MaxTime above 0 checks EnvTimeMoves under that fairness. A bounded
\*      liveness check over ticks means nothing without it, since it holds
\*      in every state once time stops.
\* A protocol may INSTANCE Env instead, if it declares the same constants
\* and variables. Env reads nothing else.
\*
\* WHAT A SERVER STEP MAY READ
\*
\* A server step reads only what its server knows. That is its own
\* variables, Up(s), Clock(s), Job(s), SetOut(s, k) and Budget(s, t).
\* Budget(s, t) is what GetRequestBudgetForRequestType hands s for request
\* type t [D22]. A design may read it to choose a path, such as skipping
\* optional work or putting work off. So a design that decides Busy from
\* its budget reads Budget(s, t), and nothing else, to decide it [D23].
\* Job(s) names the current life of s. A server that restarts is a new
\* process with a new job id [S1]. So a name that must not pass to the
\* next life, such as the holder of a lease or a claim, is Job(s) and not
\* s. A name a design takes from game.JobId is such a name. Of a datastore
\* call or a MemoryStore call its own incarnation issued, a server step
\* reads the fields srv, key, kind, arg, clo and ttl it gave, and the
\* answer ans. Of a datastore call r it reads what the closure of r told
\* it through TfOf(r), SeenOf(r) and NoteOf(r). For a call sent with Issue
\* those are the fields tf, seen and note of r. Of a MemoryStore call it
\* reads the fields tf, seen and note. After an "ok" to an UpdateAsync of
\* either store it reads res, the value its write made, since UpdateAsync
\* hands that value back [D17, M10]. It reads res at no other time. After
\* an error UpdateAsync hands back nothing, and a Luau caller learns what
\* a run returned only through the upvalues of the closure [D12]. Those
\* are tf, seen and note, and under IssueAgain the tries of a closure
\* share them [D3]. A transform that must report the value it returned
\* leaves it in its note with WriteNote or CancelNote. After an "ok" to an
\* UpdateAsync of the datastore it also reads u, the stamp of the version
\* its write made [D17]. After an "ok" to a GetAsync of the datastore it
\* reads ReadOf(r), the value and the stamp the read handed back. For a
\* MemoryStore GetAsync, seen is the item the read hands back once it
\* answers "ok". Of its listing it reads the key that ListPage gives it.
\* Everything else is the truth, for invariants and ghost variables only:
\* the fields inc, at, ph, rv, by, made and cur of a call, u and seen of a
\* GetAsync before its "ok", u and res of an UpdateAsync that did not
\* answer "ok", res of a set, hist, upd, curAt, ver, ext, inc, Cur,
\* Written, now, skew, calm, calmAt, faults, dsReach, lst, ms, msPrev,
\* msVer, msAt, msReach, msZero and the budget of any other server, and
\* every operator built on them. No server step names them. So after an
\* "err" a server cannot tell which outcome happened [D12], and it sees no
\* counter of versions [D17]. A toy may read now or calm in a guard that
\* only stages its scenario, and says so.
\*
\* A life name and a call id are handles, and nothing more. A server step
\* or a transform may test a life name for equality with Job(s), or with
\* another name it read, and do nothing else with it. It never reads the
\* parts of a name, compares a name with a server, or orders two names. On
\* Roblox a job id is an opaque GUID. So a new life cannot tell a name of
\* an earlier life of its own server from a name of another server, and it
\* cannot tell a live holder from a dead one [S1]. A call id is the number
\* NextReq or NextMsReq gives a call when it is sent. A server step keeps
\* the id of a call of its own and passes it to Reply, MsReply,
\* IssueAgain, Waiting, MsWaiting, TfOf, SeenOf, NoteOf and ReadOf, and it
\* may test two ids for equality. It never orders two ids, does arithmetic
\* on one, or puts one into an argument, a note or a value. The ids count
\* every call of every server in the order they were sent, and Roblox
\* gives no such counter [D17]. Env cannot stop either read, as it cannot
\* stop a read of now. The control JobPeek reads the parts of a life name,
\* and its new life takes the lease of its dead life at once, which no
\* server on Roblox can do. The control IdOrder orders two events by call
\* id, and it passes where the same order by clocks fails.
\*
\* CONSTANTS
\*
\* Servers, Keys and MKeys are the servers, the datastore keys and the
\* MemoryStore keys. MaxReqs bounds the datastore calls of a behaviour,
\* each GetAsync among them. MaxVers, which is 2 * MaxReqs + MaxFaults,
\* bounds the versions of a key. It is derived and not set: a call lands
\* at most twice, a set at most once, and each revert costs a fault, so no
\* key runs out of versions. MaxMsReqs bounds the MemoryStore calls.
\* MaxTime bounds true time in ticks.
\* MaxSkew bounds how far a server's clock reads from true time before
\* calm, and SkewAfterCalm bounds it once calm [C1]. MaxFaults bounds the
\* faults of a behaviour. Each BOOLEAN turns one platform behaviour on. A
\* switch marked "fault" costs one fault each time it acts. No fault
\* happens once calm is TRUE or faults reaches MaxFaults.
\*   FailBefore     fault: a datastore call fails before it takes effect
\*                  [D11]. A GetAsync and a page of a listing are such
\*                  calls.
\*   LoseAnswer     fault: a datastore call takes effect and its server
\*                  hears an error [D10].
\*   LoseCommit     fault: a write of the datastore lands, or a write of
\*                  MemoryStore applies, and the engine does not learn
\*                  that it did. It goes on as it does after a conflict,
\*                  and it runs the transform again while its server waits
\*                  [D10, D13, M6]. That run may cancel, and the call then
\*                  answers "nil" although its write took effect. Or the
\*                  run may write, and the call may land a second version,
\*                  or apply a second change, before it answers "ok".
\*   LateLand       fault: a datastore write lands after its server heard
\*                  an error or crashed [D13, S2]. The fault is the error
\*                  or the crash.
\*   DsSplit        fault: one server loses the datastore. Until Heal or
\*                  DsMend, each call it makes may then answer an error at
\*                  no more cost. That error stands for no effect, and for
\*                  every outcome LoseAnswer, LateLand and RunAfterAnswer
\*                  allow [D10, D11, D13, S3, D23].
\*   DsOutage       fault: the same for every server at once [D11].
\*   Reverts        fault: a party outside the servers writes an older
\*                  value of a key as a new version [D28].
\*   Crashes        fault: a server crashes at any step [S1].
\*   Shutdowns      fault: every live server crashes at once, as when a
\*                  publish or an empty game closes every server [S1, S3].
\*                  It is one fault, as DsOutage is for the datastore and
\*                  MsOutage for MemoryStore.
\*   ClockJumps     fault: a server's clock jumps within MaxSkew [C2].
\*   ClockSteps     a server's clock steps within MaxSkew, and within
\*                  SkewAfterCalm once calm, at no fault and after calm as
\*                  well [C2].
\*   MsFail         fault: a MemoryStore call fails with no effect [M6].
\*   MsMaybe        fault: a MemoryStore write answers an error, and it
\*                  applied before the error, applies later or never
\*                  applies [M6, M11]. A write whose server crashed may
\*                  also apply later, and the fault is the crash.
\*   MsVanish       fault: a MemoryStore item vanishes before its expiry
\*                  [M7]. It stops at calm, like every fault.
\*   MsEvict        a MemoryStore item vanishes before its expiry, at any
\*                  step, at no fault, and after calm as well [M7]. No
\*                  source promises that an item lives to its expiry, and
\*                  eviction is no refusal that load causes, so the load
\*                  premise does not stop it. Once calm, an item is
\*                  evicted only after it lived LifeAfterCalm ticks. With
\*                  MsEvict TRUE, MsVanish adds no behaviour. A check that
\*                  sets MsEvict FALSE lets every item live its full
\*                  expiry once calm, and it names that as a narrowing of
\*                  M7.
\*   MsOutage       fault: MemoryStore goes down for every server, and it
\*                  may lose every item it holds at the same time [M5,
\*                  M8].
\*   MsSplit        fault: one server loses MemoryStore while others keep
\*                  it [M9]. Each call it makes then answers an error at
\*                  no more cost, and that error stands for no effect and
\*                  for every outcome MsMaybe allows.
\*   StaleGet       a GetAsync reads an older version [D8, D9].
\*   StaleRun       a run of a transform reads an older version, whether
\*                  it then writes or cancels [D7]. A write still lands
\*                  only on the current version, so only a write that
\*                  lands shows that its read was current.
\*   StaleList      a listing may end without a key written before it
\*                  began [D20].
\*   MsStale        a MemoryStore read or transform run sees the state of
\*                  its key before the last change, or an item as it read
\*                  before it expired [M12]. An expiry is a change of what
\*                  a read sees.
\*   RunAfterAnswer a transform may run again after its call answered an
\*                  error, while the incarnation that issued it lives,
\*                  whether or not the write of the call landed [D10, D12,
\*                  D13]. It needs no other switch: a run that cancels
\*                  writes nothing, and it still changes what the closure
\*                  tells its server. A write from such a run lands only
\*                  under LateLand, since it lands late. That write may
\*                  land on a version written after the error, and a call
\*                  whose write landed may land a second version. A
\*                  MemoryStore transform does the same after an error,
\*                  whether or not its write applied, and a write from
\*                  such a run applies only under MsMaybe [M6, M11].
\*   KeyInfo        each version gets an UpdatedTime stamp, any tick in
\*                  0..MaxTime, not rising and possibly repeated [D17,
\*                  C3]. With FALSE every stamp is 0. That is one choice
\*                  among the stamps TRUE allows, so FALSE narrows Env.
\*                  A step still reads the stamp 0 in c.info, in ReadOf(r)
\*                  and in u, and it cannot tell 0 from a real stamp. So
\*                  a design that reads a stamp, such as one that ages a
\*                  record by Clock(s) minus its stamp, is checked with
\*                  TRUE. Either way a version that holds z has the stamp
\*                  NoStamp, since Roblox hands back no key info for a key
\*                  that does not exist or was removed.
\*   MsOn           MemoryStore is up. With FALSE every MemoryStore call
\*                  fails for the whole behaviour, and nothing applies.
\*   Budgets        each server has a request budget for each type in
\*                  BudgetTypes, from 0 to MaxBudget, and Budget(s, t)
\*                  reads it [D22]. An UpdateAsync spends one read and one
\*                  write. A GetAsync spends one read, a SetAsync one
\*                  write, a RemoveAsync one remove, and each page a
\*                  listing asks for one list. A cached GetAsync spends
\*                  nothing on Roblox, and Env spends one for every
\*                  GetAsync. A call past its budget is still sent, and
\*                  its budget stays at 0. On Roblox that call waits in
\*                  its queue until the budget refills [D23]. Env leaves
\*                  the queue out: the wait is part of the delay Env
\*                  allows before calm, and DelayAfterCalm bounds it once
\*                  calm, under the load premise. A full queue refuses a
\*                  call, and that is FailBefore or DsSplit, a fault. Each
\*                  tick refills a budget by any amount, none included.
\*                  Before calm, other code on the server may spend any
\*                  budget down to 0 at any step. Once calm, the load
\*                  premise gives the floor BudgetAfterCalm. With FALSE
\*                  every budget reads MaxBudget for ever and no call
\*                  spends. Nothing in Env but Budget reads a budget, so a
\*                  design whose steps never read Budget loses nothing
\*                  with FALSE.
\* The four stale switches, ClockSteps, RunAfterAnswer, MsEvict and
\* Budgets are not faults. A stale read costs nothing, and it goes on
\* after calm, since Roblox bounds no read's lag [D8]. A clock step costs
\* nothing either, since no source promises a steady clock [C2]. So a
\* safety check needs no fault for one. A safety check sets RunAfterAnswer
\* and LoseCommit TRUE, or it names the assumption it makes instead [D13,
\* D14]. RunAfterAnswer acts with LateLand and MsMaybe off as well, so
\* such a check still gets every run after an answer that writes nothing.
\* A safety check with MemoryStore up sets MsEvict TRUE, or it names the
\* narrowing of M7. A design whose steps read Budget checks safety with
\* Budgets TRUE. Two numbers set the scale of a model:
\*   MaxBudget      the most a budget holds in the model. It stands for
\*                  the per minute numbers of D22, cut to the model.
\*   MaxExpiry      the longest expiry a MemoryStore call may carry, in
\*                  ticks of the model's scale. It stands for 3,888,000
\*                  seconds, which is 45 days [M4]. A call that carries a
\*                  longer expiry is sent, never runs or applies, and
\*                  answers "err" at no fault, each time it is sent.
\* Five numbers are bounds, for liveness only:
\*   LagAfterCalm   once calm, a GetAsync, a transform run, a page of a
\*                  listing and a MemoryStore read see the current state,
\*                  or a state that stopped being current less than
\*                  LagAfterCalm ticks ago. 0 means they see the current
\*                  state. A read happens between the issue of its call
\*                  and the answer, so what the server hears may be older
\*                  by the call's own delay. Roblox bounds no lag, and the
\*                  4 second read cache alone makes a read lag with no
\*                  fault [D8].
\*   DelayAfterCalm once calm, a call its server waits on runs on the
\*                  current state, lands, cancels, applies or reads, and
\*                  its server hears the answer, no later than
\*                  DelayAfterCalm ticks after the later of its issue and
\*                  calm. A GetAsync and a page of a listing are such
\*                  calls. So is a MemoryStore call whose server does not
\*                  reach MemoryStore, which after calm happens only with
\*                  MsOn FALSE. Its answer is an error, and DelayAfterCalm
\*                  bounds when its server hears it. Tick waits for each
\*                  such call. The bound rests on the load premise below.
\*   SkewAfterCalm  once calm, each clock reads within SkewAfterCalm of
\*                  true time. Heal moves every clock that reads further
\*                  off into that range, and a clock step or a restart
\*                  after calm stays in it [C1]. It is at most MaxSkew.
\*   BudgetAfterCalm once calm, Heal and each tick leave every budget at
\*                  least BudgetAfterCalm, and other code on the server
\*                  never spends one below it. The server's own calls may
\*                  still spend it lower between two ticks. It is at most
\*                  MaxBudget. 0 puts no floor, and a budget may then read
\*                  0 for ever after calm. The floor rests on the load
\*                  premise below [D22].
\*   LifeAfterCalm  once calm, MsEvict takes an item only after it lived
\*                  LifeAfterCalm ticks since the later of its applying
\*                  and calm. 0 lets an item go at any step. MaxTime + 1
\*                  or more lets no item go once calm. Roblox gives no
\*                  such bound [M7].
\* A bound of MaxTime + 1 or more on lag or delay puts no bound in the
\* model. A safety check sets both to that, SkewAfterCalm to MaxSkew, and
\* BudgetAfterCalm and LifeAfterCalm to 0. A K1, L7 or L10 check with
\* MemoryStore up sets MsEvict TRUE and names the LifeAfterCalm it uses.
\* A design that needs a bound names the parameter, for liveness only.
\* Hold is a bound of the same kind, and so is the weak fairness in
\* EnvFair. The fairness says a step Env can take is taken, and it says
\* nothing about when in ticks. A duration that one server measures on its
\* own clock is off its true length by at most 2 * MaxSkew ticks. It is
\* off by at most 2 * SkewAfterCalm ticks when it starts once calm. A
\* design that times anything on one clock uses that bound for liveness
\* only [C1, C2].
\*
\* THE LOAD PREMISE
\*
\* Env gives each refusal that load causes as a fault: a full queue [D23],
\* a game budget that is spent while the server budget shows room [D22],
\* a key past its bytes a minute [D24], a map or a partition past its rate
\* [M2, M3], and the memory quota [M4]. A server budget that runs out
\* refuses nothing: the call waits in its queue, and Budgets lets a server
\* read how low the budget is. Faults stop at calm. So once calm no call
\* is refused, every server budget is refilled to at least
\* BudgetAfterCalm at each tick, and every call on a hot
\* key finishes within DelayAfterCalm, however many calls contend. On
\* Roblox those refusals go on for as long as the load lasts. A key takes
\* 4 MB of writes a minute, and the fifth write of 1 MB in a minute waited
\* 15 seconds [D24]. A value past 4,194,304 characters fails every write
\* for good [D1]. So DelayAfterCalm holds only while each key, server, map
\* and partition stays under its ceilings, and each value fits D1 and M4.
\* That is the load premise. A design that names DelayAfterCalm names the
\* load premise with it, and the contention notes gives the load that
\* keeps it. So does a design that names BudgetAfterCalm above 0. On
\* Roblox a call past its budget waits for the next refill, and Env
\* answers it within DelayAfterCalm like any other call. So a design that
\* names DelayAfterCalm 0 keeps its own calls in each tick under
\* BudgetAfterCalm. While a call is overdue, Tick waits. No tick then
\* passes for any server, no item expires and no clock moves, so every
\* step taken in that time happens inside the bound. That is sound only
\* under the load premise.
\*
\* VARIABLES
\*
\* hist[k][i] is the value of version i of key k, upd[k][i] is its stamp,
\* and curAt[k][i] is the tick it became current. ver[k] is the current
\* version. Version 0 holds z, and its stamp is NoStamp. Each write that
\* lands adds one version. ext[k] counts the versions of k that a party
\* outside the servers wrote. req is every datastore call so far, in the
\* order servers issued them. A call is a record with these fields:
\*   srv, inc  the server that issued the call, and its incarnation.
\*   key, arg  the key, and the argument the server gave it. The argument
\*             of a GetAsync is only a tag.
\*   clo       the call that made its transform closure: the call itself
\*             if Issue, IssueSet or IssueGet sent it, and the first call
\*             of the closure if IssueAgain sent it.
\*   kind      "upd" for UpdateAsync. "set" for SetAsync or RemoveAsync.
\*             "get" for GetAsync.
\*   at        the tick the call was issued. For invariants only.
\*   ph        the truth of where the call is at the datastore. "sent": no
\*             transform ran yet, or a GetAsync has not read. "ran": a
\*             transform returned a write that has not landed. "cancel": a
\*             transform cancelled. "landed": the write landed. "read": a
\*             GetAsync read a version. "gone": the call ended, and it has
\*             no effect beyond the versions in made. For invariants only.
\*   rv        the version the last run read, or the version a GetAsync
\*             read. For invariants only.
\*   tf        on the call that made a closure, what the last run of any
\*             call of the closure returned: "write" or "cancel". It is
\*             "none" before any run, on every other call, and always for
\*             a set or a get.
\*   seen      on the call that made a closure, the value that run read.
\*             On a GetAsync, the value it read.
\*   note      on the call that made a closure, what that run left for the
\*             server, and arg before any run.
\*   by        on the call that made a closure, the call whose run that
\*             was, and 0 before any run. For invariants only.
\*   res       the value the last run of this call returned. For a write,
\*             and for a set, it is the value to write. A server reads it
\*             only after an "ok", when it is the value the write made.
\*   made      the versions this call's write made. It holds two once a
\*             call that landed ran again and landed again, after an error
\*             or under LoseCommit, and never more. For invariants only.
\*   u         the stamp of the last version this call made, and NoStamp
\*             before one. On a GetAsync, the stamp of the version it
\*             read.
\*   ans       what the server heard: "none" yet, "ok", "nil" for a
\*             cancel, or "err".
\* tf, seen and note are what a transform can keep in its upvalues, and
\* the upvalues belong to the closure. A retry that passes the same Luau
\* function shares them. So a run of any call of the closure changes what
\* every call of it reads, and under RunAfterAnswer a late run of an
\* earlier try can change them after a later try answered [D3, D13]. A
\* protocol models a closure that retries share with IssueAgain, and a
\* fresh closure with Issue. up[s] is FALSE while server s is down. inc[s]
\* counts its crashes, so each restart starts a new incarnation, and
\* Job(s) names it. now is true time. skew[s] is how far the clock of s
\* reads from now. calm turns TRUE once, at tick calmAt, and then the
\* faults stop. faults counts the faults so far. dsReach[s] is FALSE while
\* server s has lost the datastore. lst[s] is the listing s has open: on,
\* ex, whether it passed excludeDeleted, from, the keys it must return,
\* and got, the keys it returned. It also holds the page s waits on: ask,
\* whether a page is asked for, at, the tick it was asked, read, whether
\* the page is fixed, page, the key it holds, and end, whether it ends the
\* listing. from is every key a write reached before the listing began,
\* and with ex, only those that did not hold z then. skip is the keys of
\* from the fixed page passed over, and passed is the keys of from that a
\* page which answered "ok" passed over.
\*
\* ms[mk] is the MemoryStore item under mk: has, the value v, and exp, the
\* tick it expires at. msPrev[mk] is the item before the last change of
\* mk. msVer[mk] counts the changes of mk, and msAt[mk] is the tick of the
\* last one. A change is a write that applies, a vanish, or an outage that
\* loses the item. An expiry changes what a read sees and not msVer, so a
\* write that read an item as it was before it expired still applies. mreq
\* is every MemoryStore call so far. A MemoryStore call has the fields of
\* a datastore call, with these differences. kind is "upd" for
\* UpdateAsync, "set" for SetAsync or RemoveAsync, and "get" for GetAsync.
\* ph is "applied" where a datastore call has "landed", and "read" once a
\* get read its item. ttl is the expiry the server gave an UpdateAsync or
\* a SetAsync. rv is the count of changes the last run read. cur says the
\* last run read the item as it reads now. It is for invariants only. seen
\* is the item the last run read, and res is the item to write with its
\* time to live. made counts the changes the call's write applied. It is
\* 2 once a call that applied ran again and applied again. For invariants
\* only. msReach[s] is TRUE while server s reaches MemoryStore.
\* msZero is zi. bud[s][t] is the budget server s has left for request
\* type t, in 0..MaxBudget. With Budgets FALSE it stays at MaxBudget.
\*
\* OPERATORS A PROTOCOL READS
\*
\* Up(s) is up[s]. Clock(s) is now + skew[s], the time server s reads.
\* Job(s) is <<s, inc[s]>>, the name of the current life of s. NextReq and
\* NextMsReq are the ids the next datastore call and the next MemoryStore
\* call get. A life name and a call id are handles, as WHAT A SERVER STEP
\* MAY READ says: a server step tests them for equality and reads nothing
\* else of them. TfOf(r), SeenOf(r) and NoteOf(r) read the closure of
\* datastore call r. ReadOf(r) is the read GetAsync r handed back: a
\* record of the value v and its stamp u. NoStamp is the stamp of a
\* version with no key info. Absent(k, x) says value x of k is z.
\* Waiting(s, r) says s is waiting on datastore call r, and MsWaiting(s,
\* r) says the same of MemoryStore call r. SetOut(s, k) says s has a blind
\* write to k out. Budget(s, t) is bud[s][t], the budget s has left for
\* request type t, which is one of BudgetTypes: "read", "write", "list"
\* and "remove" [D22]. Item(x, t) is a write of an item that holds x for t
\* ticks from when it applies [M4]. NoItem is a removal. Heard, MsHeard,
\* ListHeard, Write, Cancel, WriteNote, CancelNote, MsWrite, MsCancel,
\* MsWriteNote, MsCancelNote, MsThrow, MsThrowNote and Faulty are as
\* above. For invariants only: Cur(k) is the current value of k, and
\* Written is the keys any write reached. MsView(mk) is the item under mk
\* now, as a read that sees it shows it, MsLooks(mk) is every state a
\* MemoryStore read or run of mk may see now, and MsReads(mk) is the set
\* of items among them. envVars is the tuple of Env's variables.
\* EnvTimeMoves says time reaches MaxTime, and a liveness config checks
\* it.
\*
\* ACTIONS A PROTOCOL STEP CONJOINS
\*
\* Issue(s, k, a) sends UpdateAsync(k) with argument a and a closure of
\* its own. IssueAgain(s, r, a) sends UpdateAsync again on the key of the
\* earlier call r of the same incarnation, with argument a and the closure
\* of r. IssueSet(s, k, a, x) sends a blind write of x. That is SetAsync,
\* or RemoveAsync when x is z [D18, D19]. IssueGet(s, k, a) sends
\* GetAsync(k), and a is only a tag. Reply(r, a) gives answer a to
\* datastore call r. To a write, "ok" means the write landed, and "nil"
\* means the transform cancelled on its last run. "err" says nothing.
\* Behind one "err" Env picks one of these outcomes, and the server cannot
\* tell them apart: the call ended with no effect, it landed, its write
\* may still land, or, under RunAfterAnswer, its transform may still run,
\* whether or not its write landed. "ok" to an UpdateAsync hands back u,
\* the stamp of the version the write made [D17]. To a GetAsync, "ok"
\* means it read, and ReadOf(r) holds the read. "err" to a GetAsync means
\* no read. ListStart(s, ex) opens a ListKeysAsync, with excludeDeleted
\* when ex is TRUE. ListAsk(s) asks for the next page of it. ListPage(s,
\* k, a) is the answer: "ok" with key k, "end" once the listing is done,
\* or "err" [D20]. A page holds one key, and pages come in any order. On
\* Roblox a page reads up to 50 keys at one moment, and the cursor then
\* passes them for good. So when a page is fixed, each key of from that
\* has not come and that the listing may miss at that moment is passed
\* over, once the page answers "ok". The listing may end without a key it
\* passed over, even when a write reached that key again later. A key
\* written after the listing began, or written again after a removal, may
\* come or not. Without excludeDeleted a page may return any key a write
\* reached, a removed key included. With it, a page returns a key only if
\* the key held a value when the listing began, or the listing may judge
\* it by a version that holds one [D20]. MsIssue(s, mk, a, t) sends a
\* MemoryStore UpdateAsync of mk with argument a and expiry t. A removal
\* through UpdateAsync is a call with t = 0, since an item with expiry 0
\* is gone on the next read [M4]. MsIssueSet(s, mk, a, p) sends SetAsync
\* of p, or RemoveAsync when p is NoItem. MsIssueGet(s, mk, a) sends
\* GetAsync, and a is only a tag. MsReply(r, a) gives answer a to
\* MemoryStore call r. "ok" means the write applied, or for a get that
\* seen holds the item it read. "nil" means the transform cancelled. "err"
\* stands for every outcome MsFail and MsMaybe allow, and for a transform
\* that threw. Crash(s) stops s and starts its next incarnation. CrashAll
\* stops every live server at once and starts the next incarnation of
\* each. Restart(s) brings s up again with a clock inside the bound. The
\* protocol conjoins its own reset with each of the three. Each send
\* spends from the budget of its server under Budgets, as the switch says,
\* and ListAsk spends one list. A MemoryStore call whose expiry t, or
\* whose item's time to live, is past MaxExpiry is sent, and it never runs
\* or applies. It answers "err" at no fault, each time it is sent [M4]. So
\* a design whose item must live past 45 days errors on every call, as it
\* does on Roblox.
\*
\* ACTIONS OF THE ENVIRONMENT, IN EnvNext
\*
\* Run(r, Tf) runs the transform of datastore call r. It runs only on the
\* incarnation that issued r. It runs while that server waits on r and the
\* write of r has not landed. Under LoseCommit it may run once more after
\* the write landed, while the server still waits, for one fault. Under
\* RunAfterAnswer it may run after r answered "err", even when its write
\* landed. Its write then lands only under LateLand. A run follows a
\* landing only while the call made one version, so a call lands at most
\* twice. It may run again before the write lands, after a conflict or
\* with none [D3]. Each run reads the current version, or under StaleRun
\* an older one. It reads and leaves the note of its closure. A run whose
\* transform writes z records that write, and EnvNoZWrite fails. Land(r)
\* lands a write, stamps the new version, and records the stamp in the
\* call. An UpdateAsync write lands only on the version its last run read
\* [D2, D14]. A blind write lands on whatever version is current. Without
\* LateLand, a write lands only while its server waits on it. Fetch(r)
\* reads a version for GetAsync r while its server waits on it: the
\* current one, or under StaleGet an older one [D8]. ListFetch(s) fixes
\* the page the listing of s asked for: a key the listing may return, or
\* the end once it may end, and the keys the page passes over [D20].
\* MsRun(r, MsTf) runs the transform of MemoryStore call r in the same
\* way, or reads the item for a get [M10]. It needs its server to reach
\* MemoryStore. Under MsStale it may see the state before the last change,
\* or the item as it read before it expired. Under LoseCommit it may run
\* once after the write applied, while the server waits, for one fault.
\* Under RunAfterAnswer it may run after an "err", even when its write
\* applied. Its write then applies only under MsMaybe. A run after the
\* write applied that cancels keeps the change, and one that writes may
\* apply a second one. A run whose transform throws ends the call, which
\* then answers "err" at no fault, and a change it applied before stays.
\* MsApply(r) applies the item of a MemoryStore write. An UpdateAsync
\* applies only if the key has not changed since its last run read it. A
\* SetAsync or RemoveAsync applies on whatever is there. Without MsMaybe,
\* a MemoryStore write applies only while its server waits on it and
\* reaches MemoryStore. Any number of ticks may fall between the issue,
\* the runs, the landing and the answer of a call. Revert(k) writes an
\* older value of k as a new version. Tick(Hold) moves true time. Jump(s)
\* and ClockStep(s) move a clock within MaxSkew, or within SkewAfterCalm
\* once calm. Heal sets calm, gives every server the datastore back, sets
\* MemoryStore as MsOn says, and moves every clock that reads more than
\* SkewAfterCalm off into that range. DsCut, DsDown and DsMend change
\* which servers reach the datastore. MsVanishStep, MsEvictStep, MsDown,
\* MsMend and MsCut change MemoryStore. MsVanishStep takes one live item
\* for a fault. MsEvictStep takes one live item at no fault, once calm
\* only after it lived LifeAfterCalm ticks. MsDown keeps every item, or
\* loses every live item at once. An item lives its time to live from when
\* it applies [M4]. Under Budgets, Tick refills each budget by any amount,
\* and once calm to at least BudgetAfterCalm. Heal lifts each budget to at
\* least BudgetAfterCalm. BudgetDrop(s) is other code on s that spends one
\* of its budgets, down to 0 before calm and down to BudgetAfterCalm once
\* calm. Restart(s) gives s a fresh budget, at least BudgetAfterCalm once
\* calm.
\* EnvFair makes Tick, Heal, each page fetch, and each run, landing,
\* fetch, applying or read of a call its server waits on, weakly fair. A
\* run after an answer, a landing or an applying, and a late write, get no
\* fairness, so each may happen at any time or never. So do an eviction
\* and a drop of a budget.
\*
\* RULES A PROTOCOL KEEPS
\*
\* A server has at most one blind write to a key out at once. Roblox
\* cancels a queued SetAsync when a later one on the same key is sent, and
\* does not say what the cancelled call answers [D19]. Env leaves that
\* out, so a protocol that uses IssueSet checks EnvSetsApart. A design
\* that needs a read to catch up, or a call to finish, names LagAfterCalm
\* or DelayAfterCalm. A design that names DelayAfterCalm names the load
\* premise with it. No transform of a protocol writes z, and no SetAsync
\* sends it, and a protocol checks EnvNoZWrite. Under DelayAfterCalm a
\* server that waits on a call has a step enabled that hears its answer,
\* or time stops. A design that bounds its own steps in ticks passes a
\* Hold and names it. That Hold names only steps that send a call or make
\* no call, and never a step that conjoins Reply, MsReply or ListPage. A
\* server step reads a life name and a call id only as a handle. A safety
\* check passes FALSE for Hold. Time stops for ever when a Hold stays TRUE
\* while its step cannot run, or when a call stays overdue. Every bounded
\* liveness check over ticks then holds, although the work never ends. So
\* every liveness config of a model with MaxTime above 0 checks
\* EnvTimeMoves under EnvFair and the protocol's own fairness, and a
\* bounded liveness pass counts only beside a pass of EnvTimeMoves.
\* A design that decides Busy, or chooses a path, from its budget reads
\* Budget(s, t), and it checks with Budgets TRUE. Its liveness names
\* BudgetAfterCalm, and it states the floor it needs. A design that sets
\* an expiry by a symbol states ASSUME that the expiry is at most
\* MaxExpiry and names M4. A design that needs an item to live through a
\* round once calm names LifeAfterCalm.
\*
\* WHAT IS LEFT OUT, AND WHY
\*
\* The game budgets, MemoryStore units, the queues of 30 and the bytes a
\* key moves a minute [D22, D23, D24, M1] set cost. A call they turn away
\* fails before it takes effect. FailBefore and MsFail cover one such call
\* before calm, and DsSplit and MsSplit a run of them. Once calm none
\* comes, which is the load premise. The server budgets are in Env, since
\* a server reads them, but the length of each queue is not. A call past
\* its budget is sent, and its wait is part of its delay. The budget of an
\* ordered store and of RemoveVersionAsync are left out, since no Env call
\* spends them. The 30 second shutdown [S3] bounds how long a closing
\* server lives and when its calls start to fail. Crash, CrashAll and
\* DsSplit cover every safety consequence of it. IncrementAsync,
\* KeyInfo.Version, versions [D21], metadata, user ids, ordered stores and
\* MemoryStore sorted maps and queues are left out. A protocol that needs
\* one adds it to Env first. The version id that SetAsync returns, and the
\* value and key info from before the removal that RemoveAsync returns,
\* are left out. A server's own read cache is a case of StaleGet. Value
\* sizes and key names [D1, M4] belong to cost and to the encoder. So do a
\* listing's page size, its cursor and the empty pages of excludeDeleted.
\* Without excludeDeleted a listing may return every key any write
\* reached, since a removed key stays listed for 30 days and no model runs
\* 30 days [D20].
\*
\* With every switch on, both bounds at MaxTime + 1, SkewAfterCalm at
\* MaxSkew, BudgetAfterCalm and LifeAfterCalm at 0 and Hold FALSE, Env
\* leaves out no behaviour the platform facts allow, inside the cuts
\* of a model. Every model states its cuts. MaxReqs, MaxMsReqs, MaxTime,
\* MaxSkew and MaxFaults leave out every behaviour with more calls, more
\* time, more skew or more faults. MaxBudget leaves out every budget above
\* it. A stale MemoryStore read sees the state before the last change of
\* its key, where an expiry counts as a change, and not older ones. So an
\* item that expired before the next write to its key is not shown live
\* after that write. A MemoryStore call has a closure of its own, so a
\* retry that shares a closure is left out for MemoryStore. A MemoryStore
\* transform runs at most once after its write applied, so a MemoryStore
\* call applies at most two changes. In the same way a datastore transform
\* runs after a landing only while its call made one version, so a
\* datastore call lands at most twice. A third landing of one call is left
\* out, under LoseCommit and RunAfterAnswer alike. A second landing is
\* kept, and so is every write that lands on top of it. The versions of a
\* key are not a cut: MaxVers leaves room for every landing the other cuts
\* allow, so no write that ran loses its landing to a full key, and
\* EnvVersLeft checks that. A server has one listing open at a time, and
\* one page of it asked at a time.
EXTENDS Integers, Sequences, FiniteSets

\* @typeAlias: val = Int;
\* @typeAlias: arg = Int;
\* @typeAlias: item = Int;
\* @typeAlias: ctx = { srv: Str, arg: $arg, note: $arg, info: Int };
\* @typeAlias: out = { w: Bool, v: $val, n: $arg };
\* @typeAlias: call = { srv: Str, inc: Int, key: Str, kind: Str, arg: $arg, at: Int, ph: Str, rv: Int, tf: Str, seen: $val, note: $arg, res: $val, ans: Str, clo: Int, by: Int, u: Int, made: Set(Int) };
\* @typeAlias: read = { v: $val, u: Int };
\* @typeAlias: slot = { has: Bool, v: $item, exp: Int };
\* @typeAlias: put = { has: Bool, v: $item, ttl: Int };
\* @typeAlias: view = { has: Bool, v: $item };
\* @typeAlias: mout = { w: Bool, v: $item, n: $arg, t: Bool };
\* @typeAlias: mcall = { srv: Str, inc: Int, key: Str, kind: Str, arg: $arg, ttl: Int, at: Int, ph: Str, rv: Int, cur: Bool, tf: Str, seen: $view, note: $arg, res: $put, ans: Str, made: Int };
\* @typeAlias: look = { it: $view, cur: Bool, rv: Int };
\* @typeAlias: walk = { on: Bool, ex: Bool, from: Set(Str), got: Set(Str), ask: Bool, at: Int, read: Bool, page: Set(Str), end: Bool, skip: Set(Str), passed: Set(Str) };
Env_typedefs == TRUE

CONSTANTS
    \* @type: Set(Str);
    Servers,
    \* @type: Set(Str);
    Keys,
    \* @type: Set(Str);
    MKeys,
    \* @type: Int;
    MaxReqs,
    \* @type: Int;
    MaxMsReqs,
    \* @type: Int;
    MaxTime,
    \* @type: Int;
    MaxSkew,
    \* @type: Int;
    MaxFaults,
    \* @type: Bool;
    FailBefore,
    \* @type: Bool;
    LoseAnswer,
    \* @type: Bool;
    LoseCommit,
    \* @type: Bool;
    LateLand,
    \* @type: Bool;
    DsSplit,
    \* @type: Bool;
    DsOutage,
    \* @type: Bool;
    Reverts,
    \* @type: Bool;
    Crashes,
    \* @type: Bool;
    Shutdowns,
    \* @type: Bool;
    ClockJumps,
    \* @type: Bool;
    ClockSteps,
    \* @type: Bool;
    MsFail,
    \* @type: Bool;
    MsMaybe,
    \* @type: Bool;
    MsVanish,
    \* @type: Bool;
    MsEvict,
    \* @type: Bool;
    MsOutage,
    \* @type: Bool;
    MsSplit,
    \* @type: Bool;
    StaleGet,
    \* @type: Bool;
    StaleRun,
    \* @type: Bool;
    StaleList,
    \* @type: Bool;
    MsStale,
    \* @type: Bool;
    RunAfterAnswer,
    \* @type: Bool;
    KeyInfo,
    \* @type: Bool;
    MsOn,
    \* @type: Bool;
    Budgets,
    \* @type: Int;
    LagAfterCalm,
    \* @type: Int;
    DelayAfterCalm,
    \* @type: Int;
    SkewAfterCalm,
    \* @type: Int;
    MaxBudget,
    \* @type: Int;
    BudgetAfterCalm,
    \* @type: Int;
    LifeAfterCalm,
    \* @type: Int;
    MaxExpiry

VARIABLES
    \* @type: Str -> (Int -> $val);
    hist,
    \* @type: Str -> (Int -> Int);
    upd,
    \* @type: Str -> (Int -> Int);
    curAt,
    \* @type: Str -> Int;
    ver,
    \* @type: Str -> Int;
    ext,
    \* @type: Seq($call);
    req,
    \* @type: Str -> Bool;
    up,
    \* @type: Str -> Int;
    inc,
    \* @type: Int;
    now,
    \* @type: Str -> Int;
    skew,
    \* @type: Bool;
    calm,
    \* @type: Int;
    calmAt,
    \* @type: Int;
    faults,
    \* @type: Str -> Bool;
    dsReach,
    \* @type: Str -> $walk;
    lst,
    \* @type: Str -> $slot;
    ms,
    \* @type: Str -> $slot;
    msPrev,
    \* @type: Str -> Int;
    msVer,
    \* @type: Str -> Int;
    msAt,
    \* @type: Seq($mcall);
    mreq,
    \* @type: Str -> Bool;
    msReach,
    \* @type: $item;
    msZero,
    \* @type: Str -> (Str -> Int);
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

\* The versions a key may reach. A call lands at most twice, and a set at most once, and each
\* revert costs a fault. So no key passes MaxVers, and a write that ran always finds a version
\* left. EnvVersLeft checks that.
MaxVers == 2 * MaxReqs + MaxFaults

\* Operators a protocol reads.

Phases == {"sent", "ran", "cancel", "landed", "read", "gone"}
MsPhases == {"sent", "ran", "cancel", "threw", "read", "applied", "gone"}
Runs == {"none", "write", "cancel"}
MsRuns == Runs \cup {"throw"}
Heard == {"ok", "nil", "err"}
MsHeard == {"ok", "nil", "err"}
ListHeard == {"ok", "end", "err"}

\* The stamp of a version that has no key info: a key that does not exist or was removed [D17].
NoStamp == -1

\* @type: (Int, Int) => Int;
Max(a, b) == IF a >= b THEN a ELSE b

\* A fault may happen at this step.
Faulty == ~calm /\ faults < MaxFaults

\* @type: Str => Bool;
Up(s) == up[s]

\* @type: Str => Int;
Clock(s) == now + skew[s]

\* The name of the current life of server s. A restarted server is a new process with a new job
\* id [S1], so a name that must not pass to the next life is this one and not s. A job id is an
\* opaque GUID, so a server step tests a name only for equality and never reads its parts.
\* @type: Str => <<Str, Int>>;
Job(s) == <<s, inc[s]>>

\* The skews a clock may take now: within MaxSkew before calm, and within SkewAfterCalm once calm.
\* @type: Set(Int);
SkewRange == IF calm THEN -SkewAfterCalm..SkewAfterCalm ELSE -MaxSkew..MaxSkew

\* The value key k holds now. For invariants, not for server steps.
\* @type: Str => $val;
Cur(k) == hist[k][ver[k]]

\* Value x of key k stands for a key that does not exist: it is z, the value version 0 holds.
\* @type: (Str, $val) => Bool;
Absent(k, x) == x = hist[k][0]

\* A write of x that leaves no note. x is never z, which means no value: a run that writes z
\* breaks the rule EnvNoZWrite checks. A transform that returns nil or throws is a Cancel [D6].
\* @type: ($ctx, $val) => $out;
Write(c, x) == [w |-> TRUE, v |-> x, n |-> c.arg]

\* A cancel that hands back x and leaves no note. It is a Luau transform that returns nil, or
\* throws, and the call answers "nil" [D6]. x matters to no server, which reads res only after "ok".
\* @type: ($ctx, $val) => $out;
Cancel(c, x) == [w |-> FALSE, v |-> x, n |-> c.arg]

\* @type: ($val, $arg) => $out;
WriteNote(x, m) == [w |-> TRUE, v |-> x, n |-> m]

\* @type: ($val, $arg) => $out;
CancelNote(x, m) == [w |-> FALSE, v |-> x, n |-> m]

\* A MemoryStore write of value x, for the expiry its call carries, that leaves no note.
\* @type: ($ctx, $item) => $mout;
MsWrite(c, x) == [w |-> TRUE, v |-> x, n |-> c.arg, t |-> FALSE]

\* A MemoryStore cancel after reading it, which leaves no note.
\* @type: ($ctx, $view) => $mout;
MsCancel(c, it) == [w |-> FALSE, v |-> it.v, n |-> c.arg, t |-> FALSE]

\* @type: ($item, $arg) => $mout;
MsWriteNote(x, m) == [w |-> TRUE, v |-> x, n |-> m, t |-> FALSE]

\* @type: ($view, $arg) => $mout;
MsCancelNote(it, m) == [w |-> FALSE, v |-> it.v, n |-> m, t |-> FALSE]

\* A MemoryStore transform that throws, and leaves no note. It writes nothing, and the call raises
\* TransformCallbackFailed to its server, which hears "err" at no fault [M10]. v is not read.
\* @type: $ctx => $mout;
MsThrow(c) == [w |-> FALSE, v |-> msZero, n |-> c.arg, t |-> TRUE]

\* @type: $arg => $mout;
MsThrowNote(m) == [w |-> FALSE, v |-> msZero, n |-> m, t |-> TRUE]

\* The id the next call gets. A server step keeps it only to name its own call, and it never
\* orders two ids, does arithmetic on one, or puts one into an argument, a note or a value, since
\* the ids count every call of every server and Roblox gives no such counter [D17].
NextReq == Len(req) + 1
NextMsReq == Len(mreq) + 1

\* Server s waits on datastore call r: its current incarnation issued r, and r has no answer yet.
\* @type: (Str, Int) => Bool;
Waiting(s, r) ==
    /\ r \in DOMAIN req
    /\ req[r].srv = s
    /\ req[r].inc = inc[s]
    /\ req[r].ans = "none"

\* Server s waits on MemoryStore call r.
\* @type: (Str, Int) => Bool;
MsWaiting(s, r) ==
    /\ r \in DOMAIN mreq
    /\ mreq[r].srv = s
    /\ mreq[r].inc = inc[s]
    /\ mreq[r].ans = "none"

\* Server s has a blind write to key k out.
\* @type: (Str, Str) => Bool;
SetOut(s, k) == \E r \in DOMAIN req : req[r].kind = "set" /\ req[r].key = k /\ Waiting(s, r)

\* The request types of a server budget that an Env call spends [D22].
\* @type: Set(Str);
BudgetTypes == {"read", "write", "list", "remove"}

\* What GetRequestBudgetForRequestType hands server s for request type t: the budget s has left
\* [D22]. With Budgets FALSE it reads MaxBudget for ever.
\* @type: (Str, Str) => Int;
Budget(s, t) == bud[s][t]

\* Every budget full. The budgets with Budgets FALSE.
\* @type: Str -> (Str -> Int);
BudFull == [s \in Servers |-> [t \in BudgetTypes |-> MaxBudget]]

\* The least a budget holds after a refill: BudgetAfterCalm once calm, and 0 before.
\* @type: Int;
BudFloor == IF calm THEN BudgetAfterCalm ELSE 0

\* The budgets after server s sends a call of the types in ts: one less of each, and never below 0.
\* A call past its budget is still sent, and it waits in its queue on Roblox [D23].
\* @type: (Str, Set(Str)) => Str -> (Str -> Int);
Spend(s, ts) ==
    IF Budgets
    THEN [bud EXCEPT ![s] = [t \in BudgetTypes |-> IF t \in ts THEN Max(bud[s][t] - 1, 0) ELSE bud[s][t]]]
    ELSE bud

\* What the transform closure of datastore call r last told its server: what its last run
\* returned, the value it read, and the note it left. A call sent with Issue has a closure of its
\* own, so these are its own fields. A call sent with IssueAgain shares the closure of an earlier
\* call, and every run of any call in the closure changes them [D3].
\* @type: Int => Str;
TfOf(r) == req[req[r].clo].tf
\* @type: Int => $val;
SeenOf(r) == req[req[r].clo].seen
\* @type: Int => $arg;
NoteOf(r) == req[req[r].clo].note

\* What GetAsync r read: the value and its stamp. A server reads it once r answered "ok".
\* @type: Int => $read;
ReadOf(r) == [v |-> req[r].seen, u |-> req[r].u]

\* The versions of k written so far.
\* @type: Str => Set(Int);
Vers(k) == {i \in 0..MaxVers : i <= ver[k]}

\* The keys any write reached. For invariants, not for server steps.
\* @type: Set(Str);
Written == {k \in Keys : ver[k] > 0}

\* The ticks since the later of tick t and calm.
\* @type: Int => Int;
Age(t) == now - Max(t, calmAt)

\* The versions of k a stale read may see now. Before calm, any. Once calm, the current one, and
\* each one that stopped being current less than LagAfterCalm ticks ago.
\* @type: Str => Set(Int);
Lagged(k) ==
    {i \in Vers(k) : \/ i = ver[k]
                     \/ ~calm
                     \/ i < ver[k] /\ curAt[k][i + 1] > now - LagAfterCalm}

\* Datastore call r is past its bound: calm, its server waits on it, and DelayAfterCalm ticks
\* passed since the later of its issue and calm. A write has not landed, or a GetAsync has not
\* read, or the call landed, cancelled or read and its server has not heard. Tick waits for it,
\* and its runs and its read see the current version.
\* @type: Int => Bool;
Overdue(r) ==
    /\ calm
    /\ Waiting(req[r].srv, r)
    /\ \/ req[r].kind \in {"upd", "set"} /\ req[r].ph \in {"sent", "ran"}
       \/ req[r].kind = "get" /\ req[r].ph = "sent"
       \/ req[r].ph \in {"landed", "cancel", "read"}
    /\ Age(req[r].at) >= DelayAfterCalm

\* The versions a run of the transform of call r may read now.
\* @type: Int => Set(Int);
RunVers(r) == IF StaleRun /\ ~Overdue(r) THEN Lagged(req[r].key) ELSE {ver[req[r].key]}

\* The versions GetAsync r may read now.
\* @type: Int => Set(Int);
GetVers(r) == IF StaleGet /\ ~Overdue(r) THEN Lagged(req[r].key) ELSE {ver[req[r].key]}

\* The stamps a version of k that holds x may get when it is written. A version that holds z has
\* no key info [D17].
\* @type: (Str, $val) => Set(Int);
Stamps(k, x) == IF Absent(k, x) THEN {NoStamp} ELSE IF KeyInfo THEN 0..MaxTime ELSE {0}

\* A MemoryStore slot holds an item that has not expired.
\* @type: $slot => Bool;
Live(sl) == sl.has /\ now < sl.exp

\* What a read of slot sl shows at tick t. A missing or expired item shows msZero, so no read
\* learns what it held.
\* @type: ($slot, Int) => $view;
ShowAt(sl, t) == [has |-> sl.has /\ t < sl.exp, v |-> IF sl.has /\ t < sl.exp THEN sl.v ELSE msZero]

\* What a read of slot sl shows now.
\* @type: $slot => $view;
Show(sl) == ShowAt(sl, now)

\* The item under mk now.
\* @type: Str => $view;
MsView(mk) == Show(ms[mk])

\* The item under mk as it read just before its last change.
\* @type: Str => $view;
MsPrevView(mk) == ShowAt(msPrev[mk], msAt[mk])

\* A read of mk may see the state before its last change: MsStale is on, mk changed at least once,
\* and either calm has not come or that change came less than LagAfterCalm ticks ago.
\* @type: Str => Bool;
MsLagged(mk) == MsStale /\ msVer[mk] > 0 /\ (~calm \/ msAt[mk] > now - LagAfterCalm)

\* A read of mk may see the item under mk as it read before it expired: MsStale is on, the item
\* was live after its last change and has expired, and either calm has not come or it expired
\* less than LagAfterCalm ticks ago. An expiry is a change of what a read sees.
\* @type: Str => Bool;
MsExpiredLag(mk) ==
    /\ MsStale
    /\ ms[mk].has
    /\ msAt[mk] < ms[mk].exp
    /\ ms[mk].exp <= now
    /\ \/ ~calm
       \/ ms[mk].exp > now - LagAfterCalm

\* The current state of mk as a read sees it: the item, that it is current, and the change count.
\* @type: Str => $look;
MsNow(mk) == [it |-> MsView(mk), cur |-> TRUE, rv |-> msVer[mk]]

\* Every state a MemoryStore read or transform run of mk may see now.
\* @type: Str => Set($look);
MsLooks(mk) ==
    {MsNow(mk)}
    \cup (IF MsLagged(mk) THEN {[it |-> MsPrevView(mk), cur |-> FALSE, rv |-> msVer[mk] - 1]} ELSE {})
    \cup (IF MsExpiredLag(mk) THEN {[it |-> ShowAt(ms[mk], msAt[mk]), cur |-> FALSE, rv |-> msVer[mk]]} ELSE {})

\* The items a MemoryStore read of mk may see now.
\* @type: Str => Set($view);
MsReads(mk) == {l.it : l \in MsLooks(mk)}

\* A write of an item that holds x for t ticks from when it applies.
\* @type: ($item, Int) => $put;
Item(x, t) == [has |-> TRUE, v |-> x, ttl |-> t]

\* A removal.
\* @type: $put;
NoItem == [has |-> FALSE, v |-> msZero, ttl |-> 0]

\* An empty slot.
\* @type: $slot;
Gone == [has |-> FALSE, v |-> msZero, exp |-> 0]

\* What a MemoryStore write leaves when it applies now.
\* @type: $put => $slot;
Stored(p) == [has |-> p.has, v |-> IF p.has THEN p.v ELSE msZero, exp |-> now + p.ttl]

\* MemoryStore call r is past its bound, as Overdue says of a datastore call. If its server reaches
\* MemoryStore, its runs, its write and its answer go on. If not, which once calm happens only with
\* MsOn FALSE, its answer is an error, and Tick waits for that error in the same way.
\* @type: Int => Bool;
MsOverdue(r) ==
    /\ calm
    /\ MsWaiting(mreq[r].srv, r)
    /\ Age(mreq[r].at) >= DelayAfterCalm

\* No listing open.
\* @type: $walk;
NoWalk == [on |-> FALSE, ex |-> FALSE, from |-> {}, got |-> {}, ask |-> FALSE, at |-> 0,
           read |-> FALSE, page |-> {}, end |-> FALSE, skip |-> {}, passed |-> {}]

\* The page server s asked for is past its bound, as Overdue says of a call. Tick waits for it,
\* and it judges each key by its current version.
\* @type: Str => Bool;
ListOverdue(s) ==
    /\ calm
    /\ up[s]
    /\ lst[s].ask
    /\ Age(lst[s].at) >= DelayAfterCalm

\* The initial state.

\* @type: ($val, $item) => Bool;
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

\* The datastore, as a protocol step calls it.

\* @type: (Str, Str, $arg, Str, Str, $val, Int) => $call;
NewCall(s, k, a, kind, ph, x, c) ==
    [srv |-> s, inc |-> inc[s], key |-> k, kind |-> kind, arg |-> a, at |-> now,
     ph |-> ph, rv |-> -1, tf |-> "none", seen |-> hist[k][0], note |-> a,
     res |-> x, ans |-> "none", clo |-> c, by |-> 0, u |-> NoStamp, made |-> {}]

\* Server s sends UpdateAsync(k) with a transform closure of its own. Its transform will get
\* argument a. It spends one read and one write [D22].
\* @type: (Str, Str, $arg) => Bool;
Issue(s, k, a) ==
    /\ up[s]
    /\ Len(req) < MaxReqs
    /\ req' = Append(req, NewCall(s, k, a, "upd", "sent", hist[k][0], NextReq))
    /\ bud' = Spend(s, {"read", "write"})
    /\ UNCHANGED <<store, host, settle, faults, access, memory>>

\* Server s sends UpdateAsync again on the key of its earlier call r, with the transform closure of
\* r, as a retry that passes the same Luau function does. Its transform will get argument a, and
\* every run of either call reads and leaves the one note of that closure [D3].
\* @type: (Str, Int, $arg) => Bool;
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

\* Server s sends a blind write of x to k: SetAsync, or RemoveAsync when x is z. A SetAsync spends
\* one write and a RemoveAsync one remove [D22].
\* @type: (Str, Str, $arg, $val) => Bool;
IssueSet(s, k, a, x) ==
    /\ up[s]
    /\ Len(req) < MaxReqs
    /\ req' = Append(req, NewCall(s, k, a, "set", "ran", x, NextReq))
    /\ bud' = Spend(s, IF Absent(k, x) THEN {"remove"} ELSE {"write"})
    /\ UNCHANGED <<store, host, settle, faults, access, memory>>

\* Server s sends GetAsync(k). The argument a is only a tag. It spends one read, as a GetAsync the
\* cache does not answer does [D22].
\* @type: (Str, Str, $arg) => Bool;
IssueGet(s, k, a) ==
    /\ up[s]
    /\ Len(req) < MaxReqs
    /\ req' = Append(req, NewCall(s, k, a, "get", "sent", hist[k][0], NextReq))
    /\ bud' = Spend(s, {"read"})
    /\ UNCHANGED <<store, host, settle, faults, access, memory>>

\* The outcomes an error to call q may stand for beyond no effect, by the switches that allow
\* them: the answer was lost, the write may still land, or the transform may still run. A run
\* after the answer needs RunAfterAnswer alone, and a write it returns lands only under LateLand.
\* @type: $call => Set(Str);
LatePhases(q) ==
    (IF LoseAnswer /\ q.ph = "landed" THEN {"landed"} ELSE {})
    \cup (IF (LateLand \/ (RunAfterAnswer /\ q.kind = "upd")) /\ q.ph = "ran" THEN {"ran"} ELSE {})
    \cup (IF RunAfterAnswer /\ q.kind = "upd" /\ q.ph = "sent" THEN {"sent"} ELSE {})

\* The outcomes an error to call q may stand for when it costs a fault.
\* @type: $call => Set(Str);
ErrPhases(q) ==
    (IF FailBefore /\ q.ph \in {"sent", "ran", "cancel", "read"} THEN {"gone"} ELSE {})
    \cup LatePhases(q)

\* The outcomes an error to call q may stand for when its server has lost the datastore.
\* @type: $call => Set(Str);
CutPhases(q) ==
    (IF q.ph \in {"sent", "ran", "cancel", "read"} THEN {"gone"} ELSE {}) \cup LatePhases(q)

\* The server that issued call r hears answer a. "ok" to a write means it landed, and to a get
\* that it read.
\* @type: (Int, Str) => Bool;
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

\* Server s opens a ListKeysAsync. It sends nothing: ListAsk sends each page. With ex TRUE it
\* passes excludeDeleted, and a key that holds z when the listing begins is not among the keys it
\* must return.
\* @type: (Str, Bool) => Bool;
ListStart(s, ex) ==
    /\ up[s]
    /\ lst' = [lst EXCEPT ![s] = [NoWalk EXCEPT !.on = TRUE, !.ex = ex,
                                  !.from = {k \in Written : ~ex \/ ~Absent(k, Cur(k))}]]
    /\ UNCHANGED <<store, req, servers, settle, faults, dsReach, memory>>

\* Server s asks for the next page of its listing. The page spends one list [D22].
\* @type: Str => Bool;
ListAsk(s) ==
    /\ up[s]
    /\ lst[s].on
    /\ ~lst[s].ask
    /\ lst' = [lst EXCEPT ![s].ask = TRUE, ![s].at = now, ![s].read = FALSE, ![s].page = {},
                          ![s].end = FALSE, ![s].skip = {}]
    /\ bud' = Spend(s, {"list"})
    /\ UNCHANGED <<store, req, host, settle, faults, dsReach, memory>>

\* The versions of k the page server s asked for may judge k by now.
\* @type: (Str, Str) => Set(Int);
ListVers(s, k) == IF StaleList /\ ~ListOverdue(s) THEN Lagged(k) ELSE {ver[k]}

\* The listing of s may end without key k. Without excludeDeleted, only under StaleList when a
\* stale read may show k unwritten, since a removed key stays listed. With it, when a version the
\* listing may judge k by holds z.
\* @type: (Str, Str) => Bool;
Missable(s, k) ==
    IF lst[s].ex
    THEN \E i \in ListVers(s, k) : Absent(k, hist[k][i])
    ELSE StaleList /\ 0 \in ListVers(s, k)

\* The listing of s may end now: each key it must return came, a page that answered "ok" passed
\* over it, or it may miss it now.
\* @type: Str => Bool;
ListDone(s) == \A k \in lst[s].from \ (lst[s].got \cup lst[s].passed) : Missable(s, k)

\* The keys of the listing of s that a page fixed now passes over: each key it must return that
\* has not come and that it may miss now. On Roblox a page reads its keys at one moment, and the
\* cursor then passes them for good, so such a key need not come later [D20]. Pages come in any
\* order, so a page may pass over any key.
\* @type: Str => Set(Str);
Passes(s) == {k \in lst[s].from \ lst[s].got : Missable(s, k)}

\* A page of the listing of s may return key k: a write reached k, k has not come yet, and with
\* excludeDeleted, k held a value when the listing began or a version the listing may judge k by
\* holds one.
\* @type: (Str, Str) => Bool;
Listable(s, k) ==
    /\ k \in Written \ lst[s].got
    /\ \/ ~lst[s].ex
       \/ k \in lst[s].from
       \/ \E i \in ListVers(s, k) : ~Absent(k, hist[k][i])

\* The answer to the page s asked for: key k on "ok", the end on "end", or a failure on "err".
\* The listing stays open after an error, and s may ask again.
\* @type: (Str, Str, Str) => Bool;
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

\* The datastore, as the environment moves it.

\* The transform of call r runs on its server. It reads and leaves the note of its closure, and
\* records in the closure what it returned and read. A write of z is recorded like any other
\* write, and EnvNoZWrite fails in that state, since z means no value and no protocol writes it.
\* A Luau transform that returns nil or throws is a Cancel [D6]. Under LoseCommit a run may follow a landing while the
\* server waits, for one fault: the engine did not learn that its write landed [D10, D13]. Under
\* RunAfterAnswer a run may follow an "err", whether or not the write landed, and Land lands its
\* write only under LateLand. A run follows a landing only while the call made one version, so a
\* call lands at most twice.
\* @type: (Int, ($ctx, $val) => $out) => Bool;
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

\* The write of call r lands, and the new version gets a stamp, which the call records.
\* @type: Int => Bool;
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

\* GetAsync r reads a version of its key while its server waits on it: the current one, or under
\* StaleGet an older one [D8]. Its server hears the read when it hears "ok".
\* @type: Int => Bool;
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

\* The page server s asked for is fixed: a key the listing may return, or the end once it may end.
\* A page that holds a key notes in skip the keys it passes over, and ListPage records them as
\* passed once the page answers "ok".
\* @type: Str => Bool;
ListFetch(s) ==
    /\ up[s]
    /\ lst[s].ask
    /\ ~lst[s].read
    /\ \/ \E k \in Keys :
             /\ Listable(s, k)
             /\ lst' = [lst EXCEPT ![s].read = TRUE, ![s].page = {k}, ![s].skip = Passes(s) \ {k}]
       \/ ListDone(s) /\ lst' = [lst EXCEPT ![s].read = TRUE, ![s].end = TRUE]
    /\ UNCHANGED <<store, req, servers, settle, faults, dsReach, memory>>

\* A party outside the servers writes an older value of k as a new version: a revert
\* in the Data Stores Manager, a deletion or a restore [D28].
\* @type: Str => Bool;
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

\* Server s loses the datastore.
\* @type: Str => Bool;
DsCut(s) ==
    /\ DsSplit
    /\ Faulty
    /\ dsReach[s]
    /\ dsReach' = [dsReach EXCEPT ![s] = FALSE]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, servers, settle, lst, memory>>

\* Every server loses the datastore.
DsDown ==
    /\ DsOutage
    /\ Faulty
    /\ \E s \in Servers : dsReach[s]
    /\ dsReach' = [s \in Servers |-> FALSE]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, servers, settle, lst, memory>>

\* Every server reaches the datastore again.
DsMend ==
    /\ \E s \in Servers : ~dsReach[s]
    /\ dsReach' = [s \in Servers |-> TRUE]
    /\ UNCHANGED <<store, req, servers, settle, faults, lst, memory>>

\* Servers, time and faults.

\* Server s crashes. It forgets everything, and its next life is a new incarnation.
\* @type: Str => Bool;
Crash(s) ==
    /\ up[s]
    /\ Crashes
    /\ Faulty
    /\ up' = [up EXCEPT ![s] = FALSE]
    /\ inc' = [inc EXCEPT ![s] = @ + 1]
    /\ lst' = [lst EXCEPT ![s] = NoWalk]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, now, skew, bud, settle, dsReach, memory>>

\* Every live server crashes at once, for one fault, as a publish or an empty game closes every
\* server [S1, S3]. Each one forgets everything, and its next life is a new incarnation.
CrashAll ==
    /\ Shutdowns
    /\ Faulty
    /\ \E s \in Servers : up[s]
    /\ up' = [s \in Servers |-> FALSE]
    /\ inc' = [s \in Servers |-> IF up[s] THEN inc[s] + 1 ELSE inc[s]]
    /\ lst' = [s \in Servers |-> NoWalk]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, now, skew, bud, settle, dsReach, memory>>

\* Server s starts again, with a clock inside the bound. It is a new process, and under Budgets its
\* budgets start anywhere from the floor to MaxBudget.
\* @type: Str => Bool;
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

\* Time moves, unless a call or a page is past its bound under DelayAfterCalm, or calm has come
\* and the protocol holds time for a step of its own. Under Budgets each budget refills by any
\* amount, none included, and once calm to at least BudgetAfterCalm [D22].
\* @type: Bool => Bool;
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

\* Other code on server s spends one of its budgets: another store, or the game's own calls [D22].
\* Before calm it may take the budget to 0. Once calm the load premise keeps it at BudgetAfterCalm
\* or above. It costs no fault.
\* @type: Str => Bool;
BudgetDrop(s) ==
    /\ Budgets
    /\ \E t \in BudgetTypes, n \in 0..MaxBudget :
          /\ BudFloor <= n /\ n < bud[s][t]
          /\ bud' = [bud EXCEPT ![s][t] = n]
    /\ UNCHANGED <<store, req, host, settle, faults, access, memory>>

\* The clock of s jumps within MaxSkew, at the cost of a fault.
\* @type: Str => Bool;
Jump(s) ==
    /\ ClockJumps
    /\ Faulty
    /\ \E d \in SkewRange \ {skew[s]} : skew' = [skew EXCEPT ![s] = d]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, up, inc, now, bud, settle, access, memory>>

\* The clock of s steps within MaxSkew, or within SkewAfterCalm once calm. It costs no fault and
\* goes on after calm.
\* @type: Str => Bool;
ClockStep(s) ==
    /\ ClockSteps
    /\ up[s]
    /\ \E d \in SkewRange \ {skew[s]} : skew' = [skew EXCEPT ![s] = d]
    /\ UNCHANGED <<store, req, up, inc, now, bud, settle, faults, access, memory>>

\* The faults stop. Every server reaches the datastore, MemoryStore is as MsOn says, every clock
\* that reads more than SkewAfterCalm off true time moves into that range, and every budget below
\* BudgetAfterCalm rises to it.
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

\* MemoryStore, as a protocol step calls it.

\* @type: (Str, Str, $arg, Str, Str, $put, Int) => $mcall;
NewMsCall(s, mk, a, kind, ph, p, t) ==
    [srv |-> s, inc |-> inc[s], key |-> mk, kind |-> kind, arg |-> a, ttl |-> t, at |-> now,
     ph |-> ph, rv |-> -1, cur |-> FALSE, tf |-> "none",
     seen |-> [has |-> FALSE, v |-> msZero], note |-> a, res |-> p, ans |-> "none", made |-> 0]

\* Server s sends a MemoryStore UpdateAsync of mk with expiry t. Its transform will get argument a,
\* and a write it returns holds for t ticks from when it applies. The expiry is fixed when the
\* call is sent [M4, M10]. A call with t past MaxExpiry never runs, and it answers "err" [M4].
\* @type: (Str, Str, $arg, Int) => Bool;
MsIssue(s, mk, a, t) ==
    /\ up[s]
    /\ t >= 0
    /\ Len(mreq) < MaxMsReqs
    /\ mreq' = Append(mreq, NewMsCall(s, mk, a, "upd", "sent", NoItem, t))
    /\ UNCHANGED <<store, req, servers, settle, faults, access, mslots, msReach, msZero>>

\* Server s sends a MemoryStore SetAsync of p under mk, or RemoveAsync when p is NoItem. A SetAsync
\* whose time to live is past MaxExpiry never applies, and it answers "err" [M4].
\* @type: (Str, Str, $arg, $put) => Bool;
MsIssueSet(s, mk, a, p) ==
    /\ up[s]
    /\ Len(mreq) < MaxMsReqs
    /\ mreq' = Append(mreq, NewMsCall(s, mk, a, "set", "ran", p, p.ttl))
    /\ UNCHANGED <<store, req, servers, settle, faults, access, mslots, msReach, msZero>>

\* Server s sends a MemoryStore GetAsync of mk. The argument a is only a tag.
\* @type: (Str, Str, $arg) => Bool;
MsIssueGet(s, mk, a) ==
    /\ up[s]
    /\ Len(mreq) < MaxMsReqs
    /\ mreq' = Append(mreq, NewMsCall(s, mk, a, "get", "sent", NoItem, 0))
    /\ UNCHANGED <<store, req, servers, settle, faults, access, mslots, msReach, msZero>>

\* The outcomes an error to MemoryStore call q may stand for beyond no effect: under MsMaybe the
\* write applied or may still apply, and under RunAfterAnswer the transform may still run. A write
\* such a run returns applies only under MsMaybe.
\* @type: $mcall => Set(Str);
MsLatePhases(q) ==
    (IF MsMaybe /\ q.ph \in {"applied", "ran"} THEN {q.ph} ELSE {})
    \cup (IF RunAfterAnswer /\ q.kind = "upd" /\ q.ph \in {"sent", "ran"} THEN {q.ph} ELSE {})

\* The outcomes an error to MemoryStore call q may stand for when it costs a fault.
\* @type: $mcall => Set(Str);
MsErrPhases(q) ==
    (IF MsFail /\ q.ph \in {"sent", "ran", "cancel", "read"} THEN {"gone"} ELSE {})
    \cup MsLatePhases(q)

\* The outcomes an error to MemoryStore call q may stand for when its server does not reach
\* MemoryStore.
\* @type: $mcall => Set(Str);
MsCutPhases(q) ==
    (IF q.ph \in {"sent", "ran", "cancel", "read"} THEN {"gone"} ELSE {}) \cup MsLatePhases(q)

\* The server that issued MemoryStore call r hears answer a. A call whose transform threw answers
\* only "err", at no fault, and ends with no effect beyond the changes it made [M10]. A call whose
\* expiry is past MaxExpiry answers only "err", at no fault, and ends with no effect [M4].
\* @type: (Int, Str) => Bool;
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

\* MemoryStore, as the environment moves it.

\* The transform of MemoryStore call r runs on its server, or a get reads its item. A run reads
\* the current state, or under MsStale the state before the last change, or an item as it read
\* before it expired. A write it returns holds for the expiry of its call. Under LoseCommit a run
\* may follow the applying while the server waits, for one fault: the engine did not learn that
\* its write applied [D10, M6]. Under RunAfterAnswer a run may follow an "err" whether or not the
\* write applied. A call runs at most once after its write applied, so it applies at most twice.
\* A run whose transform throws ends the call at "threw": it runs no more, applies nothing more,
\* and its server hears "err". A change it applied before stays [M10].
\* @type: (Int, ($ctx, $view) => $mout) => Bool;
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

\* The write of MemoryStore call r applies. An UpdateAsync applies only if mk has not changed
\* since its last run read it.
\* @type: Int => Bool;
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

\* The item under mk vanishes before its expiry.
\* @type: Str => Bool;
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

\* The item under mk is evicted before its expiry, at no fault [M7]. Before calm it may go at any
\* step. Once calm it goes only after it lived LifeAfterCalm ticks since the later of its applying
\* and calm. msAt[mk] is the tick it applied, since a live item's last change is its applying.
\* @type: Str => Bool;
MsEvictStep(mk) ==
    /\ MsEvict
    /\ Live(ms[mk])
    /\ ~calm \/ Age(msAt[mk]) >= LifeAfterCalm
    /\ ms' = [ms EXCEPT ![mk] = Gone]
    /\ msPrev' = [msPrev EXCEPT ![mk] = ms[mk]]
    /\ msVer' = [msVer EXCEPT ![mk] = @ + 1]
    /\ msAt' = [msAt EXCEPT ![mk] = now]
    /\ UNCHANGED <<store, req, servers, settle, faults, access, mreq, msReach, msZero>>

\* MemoryStore goes down for every server. It keeps its items, or it loses every live item at
\* once, and each lost item is a change of its key [M5, M8].
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

\* @type: Str => Bool;
MsCut(s) ==
    /\ MsSplit
    /\ Faulty
    /\ msReach[s]
    /\ msReach' = [msReach EXCEPT ![s] = FALSE]
    /\ faults' = faults + 1
    /\ UNCHANGED <<store, req, servers, settle, access, mslots, mreq, msZero>>

\* What a protocol puts in its Next and its fairness.

\* Hold is a state predicate the protocol gives: once calm, Tick waits while it is TRUE.
\* @type: (($ctx, $val) => $out, ($ctx, $view) => $mout, Bool) => Bool;
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

\* The transform of datastore call r runs while its server still waits on it and its write has
\* not landed. A run after a landing costs a fault, so it gets no fairness.
\* @type: (Int, ($ctx, $val) => $out) => Bool;
RunWaited(r, Tf(_, _)) ==
    /\ r \in DOMAIN req
    /\ Waiting(req[r].srv, r)
    /\ req[r].ph \in {"sent", "ran"}
    /\ Run(r, Tf)

\* The transform of MemoryStore call r runs, or its get reads, while its server still waits on it
\* and its write has not applied. A run after the applying costs a fault, so it gets no fairness.
\* @type: (Int, ($ctx, $view) => $mout) => Bool;
MsRunWaited(r, MsTf(_, _)) ==
    /\ r \in DOMAIN mreq
    /\ MsWaiting(mreq[r].srv, r)
    /\ mreq[r].ph \in {"sent", "ran"}
    /\ MsRun(r, MsTf)

\* The write of datastore call r lands while its server still waits on it.
\* @type: Int => Bool;
Serve(r) == Land(r) /\ Waiting(req[r].srv, r) /\ up[req[r].srv]

\* The write of MemoryStore call r applies while its server still waits on it.
\* @type: Int => Bool;
MsServe(r) == MsApply(r) /\ MsWaiting(mreq[r].srv, r)

\* Time moves, the faults stop, and every call a server waits on runs, lands, reads or applies,
\* and every page asked for is fixed. A run after an answer, a landing or an applying, and a late
\* write, get no fairness.
\* @type: (($ctx, $val) => $out, ($ctx, $view) => $mout, Bool) => Bool;
EnvFair(Tf(_, _), MsTf(_, _), Hold) ==
    /\ WF_envVars(Tick(Hold))
    /\ WF_envVars(Heal)
    /\ \A r \in 1..MaxReqs :
          WF_envVars(RunWaited(r, Tf)) /\ WF_envVars(Serve(r)) /\ WF_envVars(Fetch(r))
    /\ \A r \in 1..MaxMsReqs : WF_envVars(MsRunWaited(r, MsTf)) /\ WF_envVars(MsServe(r))
    /\ \A s \in Servers : WF_envVars(ListFetch(s))

\* Invariants of Env itself. Every one but EnvSetsApart and EnvNoZWrite
\* holds by construction, so no control breaks it without an edit of Env.
\* They catch such an edit. EnvSetsApart and EnvNoZWrite are rules a
\* protocol keeps. The controls ZWrite and EraseCond break EnvNoZWrite.

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

\* "ok" means landed, applied or read, and "nil" means the last run cancelled. Without LoseCommit,
\* "nil" also means no write of the call landed or applied, and "ok" to a write means exactly one
\* did. A read a GetAsync hands back is a version its key had.
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

\* No transform writes z. z means no value, so it lies outside every value a protocol writes. On
\* Roblox a transform that returns a value writes it, whatever it is, and GetAsync answers it with
\* key info [D6, D17]. Env would take a version that holds z for a removed key, so a protocol whose
\* reducer can compute z fails here, in the state where the run returned it. So no UpdateAsync
\* removes a key. Only a blind write, which is RemoveAsync, or a write from outside makes a version
\* that holds z [D18, D28]. A rule the protocol keeps, as EnvSetsApart is. The control ZWrite
\* breaks it with a counter whose z is 0.
EnvNoZWrite ==
    \A r \in DOMAIN req :
        req[r].kind = "upd" =>
            /\ \A i \in req[r].made : ~Absent(req[r].key, hist[req[r].key][i])
            /\ req[r].ph \in {"ran", "landed"} => ~Absent(req[r].key, req[r].res)

\* The name an earlier Env gave the same check.
EnvNoUpdRemoval == EnvNoZWrite

\* Every UpdateAsync write that stands landed made the version after the one it read.
EnvLandsOnRead ==
    \A r \in DOMAIN req :
        req[r].kind = "upd" /\ req[r].ph = "landed" =>
            /\ req[r].rv + 1 \in req[r].made
            /\ hist[req[r].key][req[r].rv + 1] = req[r].res

\* Each version after 0 is one landing of one call, or one write from outside. A call that ran
\* again after its write landed may land a second time [D10, D13].
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

\* No write starves for want of a version. Each call made at most two versions, and a write
\* that ran and has not landed finds a version left under MaxVers. It holds by the count behind
\* MaxVers. An edit of Env that lets a key run out of versions fails here, so no model is cut
\* short in silence. The capped configs of controls/DoubleLand make that edit: they set MaxVers to
\* MaxReqs, as an earlier Env did, and EnvVersLeft fails there.
EnvVersLeft ==
    /\ \A k \in Keys : ver[k] <= MaxVers
    /\ \A r \in DOMAIN req :
          /\ Cardinality(req[r].made) <= IF req[r].kind = "upd" THEN 2 ELSE 1
          /\ req[r].ph = "ran" => ver[req[r].key] < MaxVers

\* What a server hears of its transform matches what the transform did. The note, what the last
\* run returned and what it read live with the closure, which is the call itself unless the call
\* was sent with IssueAgain. by names the call whose run last changed them.
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

\* A version that holds z has no stamp, and every other version has one. No stamp but 0 without
\* KeyInfo, and no outside write without Reverts. A call that landed records the stamp of the
\* last version it made. A GetAsync records the stamp of the version it read.
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

\* Versions became current in the order they were written, and no later than now.
EnvTimes ==
    \A k \in Keys :
        /\ \A i \in 1..ver[k] : curAt[k][i - 1] <= curAt[k][i]
        /\ curAt[k][ver[k]] <= now

\* An error means no effect, unless a switch lets it mean more. Under LoseCommit a call can end
\* with no more effect after a landing or an applying the engine did not learn of.
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

\* With MemoryStore off, nothing applies, nothing is read, and no call answers "ok".
EnvMemoryOff ==
    ~MsOn =>
        /\ \A mk \in MKeys : ~ms[mk].has
        /\ \A r \in DOMAIN mreq : mreq[r].ph \in {"sent", "ran", "gone"} /\ mreq[r].ans # "ok"

\* A missing item holds msZero, so no read hands a server what an expired or removed item held.
EnvNoGhostItem ==
    /\ \A mk \in MKeys : ~ms[mk].has => ms[mk].v = msZero
    /\ \A mk \in MKeys : ~msPrev[mk].has => msPrev[mk].v = msZero
    /\ \A mk \in MKeys : \A it \in MsReads(mk) : ~it.has => it.v = msZero
    /\ \A r \in DOMAIN mreq : ~mreq[r].seen.has => mreq[r].seen.v = msZero

\* No call or page waits past DelayAfterCalm once calm, while it can still finish: its write
\* lands, cancels or applies, it reads, and its server hears the answer. A MemoryStore call whose
\* server does not reach MemoryStore finishes with an error, and the same bound holds for it.
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

\* A MemoryStore call whose expiry is past MaxExpiry never runs, applies or answers "ok" [M4].
EnvExpiry ==
    \A r \in DOMAIN mreq :
        mreq[r].ttl > MaxExpiry =>
            /\ mreq[r].made = 0
            /\ mreq[r].ans \in {"none", "err"}
            /\ mreq[r].tf = "none"

\* With Budgets FALSE every budget stays full. With it TRUE, no budget passes MaxBudget.
EnvBudgets ==
    /\ ~Budgets => bud = BudFull
    /\ \A s \in Servers, t \in BudgetTypes : Budget(s, t) \in 0..MaxBudget

\* Only a fault takes a service away, and calm gives it back.
EnvReach ==
    /\ (\E s \in Servers : ~dsReach[s]) => DsSplit \/ DsOutage
    /\ (\E s \in Servers : msReach[s] # MsOn) => MsSplit \/ MsOutage
    /\ calm => \A s \in Servers : dsReach[s] /\ msReach[s] = MsOn

\* Every clock reads within MaxSkew of true time, and within SkewAfterCalm once calm [C1].
EnvClocks ==
    /\ skew \in [Servers -> -MaxSkew..MaxSkew]
    /\ calm => \A s \in Servers : -SkewAfterCalm <= skew[s] /\ skew[s] <= SkewAfterCalm

\* A server has at most one blind write to a key out at once. The rule a protocol keeps [D19].
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

\* Time reaches MaxTime. A liveness config of a model with MaxTime above 0 checks it under
\* EnvFair and the protocol's own fairness. It fails when time stops for ever: a Hold that stays
\* TRUE while the step it names cannot run, or a call that stays overdue because its server has
\* no step that hears the answer. A bounded liveness check over ticks passes in silence when time
\* stops, so its pass counts only beside a pass of EnvTimeMoves. The controls DelayLiveStuck and
\* DelayLiveDeaf show it failing, one for each cause.
EnvTimeMoves == <>(now = MaxTime)

=============================================================================
