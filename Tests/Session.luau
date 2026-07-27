--!strict

-- session suite, Apply vs Commit, observers, backpressure and reducer purity

local Harness = require("./Harness")
local Log = require("../src/Log")
local MakeOp = require("../src/MakeOp")
local Session = require("../src/Session")
local Testing = require("./Testing")

local Expect = Testing.Expect
local P = Harness.Print
local W = Harness.Store
local Key = Harness.Key
local Race = Harness.Race
local Reducer = Harness.Reducer
local INIT = Harness.INIT
local TR = Harness.TR
local FoldRecord = Harness.FoldRecord

local Suite = {}

function Suite.ExactlyOnce()
	local K = Key("once")
	local Sess = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 50 }) })
	Sess:Flush():Wait()
	Sess:Flush():Wait()
	Sess:Flush():Wait()

	Expect(Sess:Get().Gold).ToBe(50)
end

function Suite.ApplyDuringFlush()
	local K = Key("applyflush")
	local Sess = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()
	local Applied = 0
	local Flushing = true
	task.spawn(function()
		while Flushing do
			Sess:Flush():Wait()
		end
	end)
	for _ = 1, 40 do
		if Sess:Apply("Add", { Amount = 1 }) then Applied += 1 end
		task.wait()
	end
	Flushing = false
	Sess:Flush():Wait()

	Expect(FoldRecord(K).Gold).ToBe(Applied)
end

function Suite.CrashRecovery()
	local K = Key("crash")
	local S1 = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()
	for _ = 1, 5 do S1:Apply("Add", { Amount = 10 }) end
	S1:Flush():Wait()
	local Persisted = S1:Get().Gold
	for _ = 1, 3 do S1:Apply("Add", { Amount = 10 }) end
	S1 = nil :: any

	local S2 = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	Expect(S2:Get().Gold).ToBe(Persisted)
end

function Suite.SplitBrain()
	local K = Key("split")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 100 }) })
	local A = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()
	local B = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()
	local a = A:Apply("Spend", { Amount = 100 })
	local b = B:Apply("Spend", { Amount = 100 })
	A:Flush():Wait()
	B:Flush():Wait()
	local G = FoldRecord(K).Gold
	P(string.format("SplitBrain: A=%s B=%s (both true = SIDE-EFFECT DUPE) storedGold=%d (corruption if <0)",
		tostring(a), tostring(b), G))
end

function Suite.CommitDupeSafe()
	local K = Key("commit")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 100 }) })
	local A = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()
	local B = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	local Ra, Rb = false, false
	Race("CommitDupeSafe", {
		function() Ra = A:Commit("Spend", { Amount = 100 }):Wait() end,
		function() Rb = B:Commit("Spend", { Amount = 100 }):Wait() end
	})

	local Accepts = (Ra and 1 or 0) + (Rb and 1 or 0)

	Expect(Accepts).ToBe(1)
	Expect(FoldRecord(K).Gold).ToBe(0)
end

function Suite.BasketEditToSession()
	local K = Key("basket")
	local Sess = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 250 }) })
	local Before = Sess:Get().Gold

	Sess:Flush():Wait()
	local After = Sess:Get().Gold

	Expect(Before).ToBe(0)
	Expect(After).ToBe(250)
end

function Suite.EditOfflineReload()
	local K = Key("offline")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 30 }) })
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 20 }) })

	local Sess = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	Expect(Sess:Get().Gold).ToBe(50)
end

function Suite.PendingOverlayFlush()
	local K = Key("overlay")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	local F = S:Flush()
	local Applied = S:Apply("Add", { Amount = 10 })
	F:Wait()

	Expect(Applied).ToBe(true)
	Expect(S:Get().Gold).ToBe(110)
end

function Suite.ReleasedSessionRejects()
	local K = Key("released")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()
	S:Release():Wait()

	local Applied = S:Apply("Add", { Amount = 50 })
	local Committed = S:Commit("Add", { Amount = 50 }):Wait()

	Expect(Applied).ToBe(false)
	Expect(Committed).ToBe(false)
	Expect(FoldRecord(K).Gold).ToBe(100)
	Expect(S:Get().Gold).ToBe(100)
end

function Suite.YieldingReducerSkipped()
	local K = Key("yieldy")

	local function Yieldy(State: any, Op: any): any?
		if Op.Kind == "Yieldy" then
			task.wait()
			return { Gold = State.Gold + Op.Amount, N = State.N }
		end
		return Reducer(State, Op)
	end

	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(Log.New(W()), Log.Shape(Yieldy, INIT), K):Wait()

	Expect(function()
		S:Apply("Yieldy", { Amount = 50 })
	end).ToThrow()

	Log.New(W()):Append(K, { MakeOp("Yieldy", { Amount = 50 }) })
	S:Flush():Wait()
	local AfterFlush = S:Get().Gold

	local Compacting = S:Compact()
	Compacting:Wait()
	local CompactOk = Compacting:Happened()
	local AfterCompact = FoldRecord(K).Gold

	Expect(AfterFlush).ToBe(100)
	Expect(CompactOk).ToBe(true)
	Expect(AfterCompact).ToBe(100)
end

function Suite.InternalKindRejected()
	local K = Key("reserved")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(Log.New(W()), Log.Shape(TR, INIT), K):Wait()

	local Applied = S:Apply("__TransferDeliver", { Tid = "forge", Amount = 1000000 })
	local Committed = S:Commit("__TransferDeliver", { Tid = "forge2", Amount = 1000000 }):Wait()
	S:Flush():Wait()

	Expect(Applied).ToBe(false)
	Expect(Committed).ToBe(false)
	Expect(FoldRecord(K).Gold).ToBe(100)
end

function Suite.EscapeOpRejected()
	local K = Key("escop")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	local Blob = string.rep("\1", 300000)
	local Ok = S:Apply("Add", { Amount = 1, Blob = Blob })

	Expect(Ok).ToBe(false)
	Expect(S:Get().Gold).ToBe(100)
end

function Suite.LargeOpRejected()
	local K = Key("bigop")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	local Pad = {}
	for i = 1, 200000 do
		Pad[i] = i
	end
	local Ok = S:Apply("Add", { Amount = 1, Pad = Pad })

	Expect(Ok).ToBe(false)
	Expect(S:Get().Gold).ToBe(100)
end

function Suite.BacklogByteBudget()
	local K = Key("backlog")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	local Pad = {}
	for i = 1, 12000 do
		Pad[i] = i
	end
	local Accepted = 0
	local Rejected = false
	for _ = 1, 40 do
		if S:Apply("Add", { Amount = 1, Pad = Pad }) then
			Accepted += 1
		else
			Rejected = true
			break
		end
	end

	Expect(Rejected).ToBe(true)
	Expect(Accepted).ToBeGreaterThan(0)
	Expect(Accepted).ToBeLessThan(40)
end

function Suite.CommitOpForgedRefused()
	local K = Key("forgeop")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(Log.New(W()), Log.Shape(TR, INIT), K):Wait()

	local SystemForge = S:CommitOp({ Id = "forge1", Kind = "__TransferDeliver", Tid = "x", Amount = 1000000 } :: any):Wait()
	local TxForge = S:CommitOp({ Id = "forge2", Kind = "Add", Amount = 5, Tx = "hax" } :: any):Wait()
	S:Flush():Wait()

	Expect(SystemForge).ToBe(false)
	Expect(TxForge).ToBe(false)
	Expect(#Log.New(W()):Read(K).Ops).ToBe(1)
	Expect(FoldRecord(K).Gold).ToBe(100)
end

function Suite.ObserveMapChangedChain()
	local K = Key("obschain")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 10 }) })
	local S = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	local Seen: { number } = {}
	local Connection = S:Observe()
		:Map(function(State: any): number
			return State.Gold
		end)
		:Changed()
		:Subscribe(function(Gold: number)
			table.insert(Seen, Gold)
		end)

	S:Apply("Add", { Amount = 5 })
	S:Apply("Spend", { Amount = 100 })
	S:Apply("Add", { Amount = 0 })
	S:Apply("Add", { Amount = 5 })

	Connection:Disconnect()
	S:Apply("Add", { Amount = 5 })

	Expect(#Seen).ToBe(2)
	Expect(Seen[1]).ToBe(15)
	Expect(Seen[2]).ToBe(20)
	Expect(S:Get().Gold).ToBe(25)
end

function Suite.ObserveFilterDropsUnwanted()
	local K = Key("obsfilter")
	local S = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	local Rich = 0
	S:Observe()
		:Filter(function(State: any): boolean
			return State.Gold >= 20
		end)
		:Subscribe(function()
			Rich += 1
		end)

	S:Apply("Add", { Amount = 5 })
	S:Apply("Add", { Amount = 5 })
	S:Apply("Add", { Amount = 15 })

	Expect(Rich).ToBe(1)
end

local function Bag(Count: number): { [string]: any }
	local Items = {}
	for Index = 1, Count do
		Items[`item{Index}`] = { Count = Index, Tag = "probe" }
	end
	return Items
end

local function Tick(State: any, Op: any): any?
	if Op.Kind ~= "Tick" then
		return nil
	end
	local Next = table.clone(State)
	Next.Gold += 1
	return Next
end

local function SeedProfile(K: string, BagSize: number)
	W():UpdateAsync(K, function()
		return { Snapshot = { Gold = 0, Bag = Bag(BagSize) }, Ops = {} }
	end)
end

function Suite.ApplyCostFlatInProfileSize()
	local function TimeApplies(BagSize: number, Count: number): number
		local K = Key(`applycost{BagSize}`)
		SeedProfile(K, BagSize)
		local Active = Session.Load(Log.New(W()), Log.Shape(Tick, { Gold = 0, Bag = {} }), K):Wait()

		local Start = os.clock()
		for _ = 1, Count do
			Active:Apply("Tick")
		end
		return (os.clock() - Start) / Count * 1e6
	end

	local Applies = 150
	local Small = TimeApplies(0, Applies)
	local Large = TimeApplies(2500, Applies)
	local Ratio = if Small > 0 then Large / Small else 0

	P(string.format("ApplyCost: empty bag %.1f us/Apply, large bag %.1f us/Apply (%.1fx)", Small, Large, Ratio))

	Expect(Ratio).ToBeLessThan(10)
end

function Suite.LargeProfileStillApplies()
	local K = Key("largeprofile")
	SeedProfile(K, 2000)

	local Active = Session.Load(Log.New(W()), Log.Shape(Tick, { Gold = 0, Bag = {} }), K):Wait()
	local Accepted = 0
	for _ = 1, 25 do
		if Active:Apply("Tick") then
			Accepted += 1
		end
	end
	Active:Flush():Wait()

	local Reloaded = Session.Load(Log.New(W()), Log.Shape(Tick, { Gold = 0, Bag = {} }), K):Wait()
	local State = Reloaded:Get()

	Expect(Accepted).ToBe(25)
	Expect(Active:Get().Gold).ToBe(25)
	Expect(State.Gold).ToBe(25)
	Expect(State.Bag.item2000.Count).ToBe(2000)
end

function Suite.ApplyRefusedIsTheReducer()
	local K = Key("aprf")
	local Active = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	local Funded, FundedWhy = Active:Apply("Add", { Amount = 10 })
	local Broke, BrokeWhy = Active:Apply("Spend", { Amount = 999 })

	Expect(Funded).ToBe(true)
	Expect(FundedWhy).ToBeNil()
	Expect(Broke).ToBe(false)
	Expect(BrokeWhy).ToBe("Refused")
end

function Suite.ApplyClosedAfterRelease()
	local K = Key("apcl")
	local Active = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()
	Active:Release():Wait()

	local Ok, Why = Active:Apply("Add", { Amount = 10 })

	Expect(Ok).ToBe(false)
	Expect(Why).ToBe("Closed")
end

function Suite.ApplyBacklogAndInvalidDiffer()
	local K = Key("apbk")
	local Active = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	local Junk, JunkWhy = Active:Apply("Add", { Amount = 0 / 0 })

	local Big = string.rep("x", 64 * 1024)
	local Backlogged, BacklogWhy = false, nil :: any
	for _ = 1, 40 do
		Backlogged, BacklogWhy = Active:Apply("Add", { Amount = 1, Pad = Big })
		if not Backlogged then
			break
		end
	end

	Expect(Junk).ToBe(false)
	Expect(JunkWhy).ToBe("Invalid")
	Expect(Backlogged).ToBe(false)
	Expect(BacklogWhy).ToBe("Backlog")
end

function Suite.CommitCarriesReason()
	local K = Key("cmrs")
	local Active = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()

	local Granted, GrantedWhy = Active:Commit("Add", { Amount = 25 }):Wait()
	local Broke, BrokeWhy = Active:Commit("Spend", { Amount = 999 }):Wait()

	Active:Release():Wait()
	local Closed, ClosedWhy = Active:Commit("Add", { Amount = 1 }):Wait()

	Expect(Granted).ToBe(true)
	Expect(GrantedWhy).ToBeNil()
	Expect(Broke).ToBe(false)
	Expect(BrokeWhy).ToBe("Refused")
	Expect(Closed).ToBe(false)
	Expect(ClosedWhy).ToBe("Closed")
end

function Suite.ImpureReducerIsCaught()
	local K = Key("purity")

	local function Impure(State: any, Op: any): any?
		if Op.Kind ~= "Add" then
			return nil
		end
		return { Gold = State.Gold + Op.Amount, N = State.N + 1, Stamp = os.clock() }
	end

	local Active = Session.Load(Log.New(W()), Log.Shape(Impure, { Gold = 0, N = 0, Stamp = 0 } :: any), K):Wait()
	Active:Apply("Add", { Amount = 5 })

	local Caught = Harness.Warnings(function()
		Active:Flush():Wait()
	end)

	Expect(Harness.Mentioning(Caught, "not deterministic")).ToBe(1)
	Expect(Active:Get().Gold).ToBe(5)
end

function Suite.PureReducerIsNotFlagged()
	local K = Key("purityok")
	local Active = Session.Load(Log.New(W()), Log.Shape(Reducer, INIT), K):Wait()
	Active:Apply("Add", { Amount = 5 })
	Active:Apply("Add", { Amount = 7 })

	local Caught = Harness.Warnings(function()
		Active:Flush():Wait()
		Active:Apply("Add", { Amount = 3 })
		Active:Flush():Wait()
	end)

	Expect(Harness.Mentioning(Caught, "not deterministic")).ToBe(0)
	Expect(Active:Get().Gold).ToBe(15)
end

return table.freeze(Suite)
