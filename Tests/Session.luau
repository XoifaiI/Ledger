--!strict

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
	local Sess = Session.Load(W(), K, Reducer, INIT):Wait()
	Log.Append(W(), K, { MakeOp("Add", { Amount = 50 }) })
	Sess:Flush():Wait()
	Sess:Flush():Wait()
	Sess:Flush():Wait()

	Expect(Sess:Get().Gold).ToBe(50)
end

function Suite.ApplyDuringFlush()
	local K = Key("applyflush")
	local Sess = Session.Load(W(), K, Reducer, INIT):Wait()
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
	local S1 = Session.Load(W(), K, Reducer, INIT):Wait()
	for _ = 1, 5 do S1:Apply("Add", { Amount = 10 }) end
	S1:Flush():Wait()
	local Persisted = S1:Get().Gold
	for _ = 1, 3 do S1:Apply("Add", { Amount = 10 }) end
	S1 = nil :: any

	local S2 = Session.Load(W(), K, Reducer, INIT):Wait()

	Expect(S2:Get().Gold).ToBe(Persisted)
end

function Suite.SplitBrain()
	local K = Key("split")
	Log.Append(W(), K, { MakeOp("Add", { Amount = 100 }) })
	local A = Session.Load(W(), K, Reducer, INIT):Wait()
	local B = Session.Load(W(), K, Reducer, INIT):Wait()
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
	Log.Append(W(), K, { MakeOp("Add", { Amount = 100 }) })
	local A = Session.Load(W(), K, Reducer, INIT):Wait()
	local B = Session.Load(W(), K, Reducer, INIT):Wait()

	local Ra, Rb = false, false
	Race("CommitDupeSafe", {
		function() Ra = A:Commit("Spend", { Amount = 100 }):Wait() end,
		function() Rb = B:Commit("Spend", { Amount = 100 }):Wait() end,
	})

	local Accepts = (Ra and 1 or 0) + (Rb and 1 or 0)

	Expect(Accepts).ToBe(1)
	Expect(FoldRecord(K).Gold).ToBe(0)
end

function Suite.BasketEditToSession()
	local K = Key("basket")
	local Sess = Session.Load(W(), K, Reducer, INIT):Wait()

	Log.Append(W(), K, { MakeOp("Add", { Amount = 250 }) })
	local Before = Sess:Get().Gold

	Sess:Flush():Wait()
	local After = Sess:Get().Gold

	Expect(Before).ToBe(0)
	Expect(After).ToBe(250)
end

function Suite.EditOfflineReload()
	local K = Key("offline")
	Log.Append(W(), K, { MakeOp("Add", { Amount = 30 }) })
	Log.Append(W(), K, { MakeOp("Add", { Amount = 20 }) })

	local Sess = Session.Load(W(), K, Reducer, INIT):Wait()

	Expect(Sess:Get().Gold).ToBe(50)
end

function Suite.PendingOverlayFlush()
	local K = Key("overlay")
	Log.Append(W(), K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(W(), K, Reducer, INIT):Wait()

	local F = S:Flush()
	local Applied = S:Apply("Add", { Amount = 10 })
	F:Wait()

	Expect(Applied).ToBe(true)
	Expect(S:Get().Gold).ToBe(110)
end

function Suite.ReleasedSessionRejects()
	local K = Key("released")
	Log.Append(W(), K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(W(), K, Reducer, INIT):Wait()
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

	Log.Append(W(), K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(W(), K, Yieldy, INIT):Wait()

	Expect(function()
		S:Apply("Yieldy", { Amount = 50 })
	end).ToThrow()

	Log.Append(W(), K, { MakeOp("Yieldy", { Amount = 50 }) })
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
	Log.Append(W(), K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(W(), K, TR, INIT):Wait()

	local Applied = S:Apply("__TransferDeliver", { Tid = "forge", Amount = 1000000 })
	local Committed = S:Commit("__TransferDeliver", { Tid = "forge2", Amount = 1000000 }):Wait()
	S:Flush():Wait()

	Expect(Applied).ToBe(false)
	Expect(Committed).ToBe(false)
	Expect(FoldRecord(K).Gold).ToBe(100)
end

function Suite.EscapeOpRejected()
	local K = Key("escop")
	Log.Append(W(), K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(W(), K, Reducer, INIT):Wait()

	local Blob = string.rep("\1", 300000)
	local Ok = S:Apply("Add", { Amount = 1, Blob = Blob })

	Expect(Ok).ToBe(false)
	Expect(S:Get().Gold).ToBe(100)
end

function Suite.LargeOpRejected()
	local K = Key("bigop")
	Log.Append(W(), K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(W(), K, Reducer, INIT):Wait()

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
	Log.Append(W(), K, { MakeOp("Add", { Amount = 100 }) })
	local S = Session.Load(W(), K, Reducer, INIT):Wait()

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

return table.freeze(Suite)
