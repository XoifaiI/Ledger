--!strict

-- transfers suite, conservation under chaos, escrow recovery and dedupe by id

local HttpService = game:GetService("HttpService")

local Harness = require("./Harness")
local DataStoreWrapper = require("../src/Util/DataStoreWrapper")
local Log = require("../src/Log")
local Fold = require("../src/Fold")
local MakeOp = require("../src/MakeOp")
local Transfer = require("../src/Transfer")
local Tx = require("../src/Tx")
local Testing = require("./Testing")

local Expect = Testing.Expect
local W = Harness.Store
local Race = Harness.Race
local Uid = Harness.Uid
local INIT = Harness.INIT
local TR = Harness.TR
local RNG = Harness.RNG
local FoldRecord = Harness.FoldRecord
local HeldSum = Harness.HeldSum

local function FoldId(Id: number): any
	return FoldRecord(tostring(Id), TR)
end

local Suite = {}

function Suite.TransferHappy()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })

	local Ok = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 50)
	local Sa, Sb = FoldId(A), FoldId(B)
	local Total = Sa.Gold + Sb.Gold + HeldSum(Sa)

	Expect(Ok).ToBeTruthy()
	Expect(Sa.Gold).ToBe(50)
	Expect(Sb.Gold).ToBe(50)
	Expect(HeldSum(Sa)).ToBe(0)
	Expect(Total).ToBe(100)
end

function Suite.TransferInsufficient()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 30 }) })

	local Ok = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 50)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Ok).ToBeFalsy()
	Expect(Sa.Gold).ToBe(30)
	Expect(Sb.Gold).ToBe(0)
	Expect(HeldSum(Sa)).ToBe(0)
end

function Suite.TransferCrashRecover()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })

	Transfer.Reserve(Log.New(W()), Log.Shape(TR, INIT), A, B, 50)
	local Sa1 = FoldId(A)

	Expect(Sa1.Gold).ToBe(50)
	Expect(HeldSum(Sa1)).ToBe(50)
	Expect(FoldId(B).Gold).ToBe(0)

	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, Sa1._Held)
	local Sa2, Sb2 = FoldId(A), FoldId(B)
	local Total = Sa2.Gold + Sb2.Gold + HeldSum(Sa2)

	Expect(Sa2.Gold).ToBe(50)
	Expect(Sb2.Gold).ToBe(50)
	Expect(HeldSum(Sa2)).ToBe(0)
	Expect(Total).ToBe(100)
end

function Suite.TransferDoubleRecover()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	Transfer.Reserve(Log.New(W()), Log.Shape(TR, INIT), A, B, 50)
	local Held = FoldId(A)._Held

	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, Held)
	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, Held)
	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, Held)

	local Sb = FoldId(B)

	Expect(Sb.Gold).ToBe(50)
end

function Suite.TransferConcurrentConserve()
	local Accts = {}
	for i = 1, 4 do
		Accts[i] = Uid()
		Log.New(W()):Append(tostring(Accts[i]), { MakeOp("Add", { Amount = 100 }) })
	end

	local Thunks = {}
	for i = 1, 8 do
		Thunks[i] = function()
			local From = Accts[RNG:NextInteger(1, 4)]
			local To = Accts[RNG:NextInteger(1, 4)]
			if From ~= To then
				pcall(function() return Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), From, To, RNG:NextInteger(1, 30)) end)
			end
		end
	end
	Race("TransferConcurrentConserve", Thunks)

	for _ = 1, 3 do
		for _, A in Accts do
			pcall(function() Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, FoldId(A)._Held) end)
		end
	end

	local Total, Held = 0, 0
	for _, A in Accts do
		local S = FoldId(A)
		Total += S.Gold
		Held += HeldSum(S)
	end

	Expect(Held).ToBe(0)
	Expect(Total).ToBe(400)
end

function Suite.TransferWindowMint()
	local B = Uid()
	local T0 = HttpService:GenerateGUID(false)

	local Batch: { any } = { { Id = `del:{T0}`, Kind = "__TransferDeliver", Tid = T0, Amount = 100 } }
	for _ = 1, 1030 do
		local U = HttpService:GenerateGUID(false)
		table.insert(Batch, { Id = `del:{U}`, Kind = "__TransferDeliver", Tid = U, Amount = 0 })
	end
	Log.New(W()):Append(tostring(B), Batch)
	local G1 = FoldId(B).Gold

	local Redeliver: any = { Id = `del2:{T0}`, Kind = "__TransferDeliver", Tid = T0, Amount = 100 }
	Log.New(W()):Append(tostring(B), { Redeliver })
	local G2 = FoldId(B).Gold

	Expect(G1).ToBe(100)
	Expect(G2).ToBe(100)
end

function Suite.TransferHeldSurvivesEdit()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	Transfer.Reserve(Log.New(W()), Log.Shape(TR, INIT), A, B, 40)
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 10 }) })

	local S = FoldId(A)

	Expect(HeldSum(S)).ToBe(40)
	Expect(S.Gold).ToBe(70)
end

function Suite.TransferRecoverCompletes()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Tid = Transfer.Reserve(Log.New(W()), Log.Shape(TR, INIT), A, B, 60) :: string
	local DeliverOp: any = { Id = `del:{Tid}`, Kind = "__TransferDeliver", Tid = Tid, From = A, Amount = 60 }
	Log.New(W()):Append(tostring(B), { DeliverOp })
	local Sa1, Sb1 = FoldId(A), FoldId(B)

	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, Sa1._Held)
	local Sa2, Sb2 = FoldId(A), FoldId(B)
	local Total = Sa2.Gold + Sb2.Gold + HeldSum(Sa2)

	Expect(Sa1.Gold).ToBe(40)
	Expect(HeldSum(Sa1)).ToBe(60)
	Expect(Sb1.Gold).ToBe(60)
	Expect(Sa2.Gold).ToBe(40)
	Expect(HeldSum(Sa2)).ToBe(0)
	Expect(Sb2.Gold).ToBe(60)
	Expect(Total).ToBe(100)
end

function Suite.ReserveReadRace()
	local From, To = Uid(), Uid()
	Log.New(W()):Append(tostring(From), { MakeOp("Add", { Amount = 100 }) })

	local Tid = HttpService:GenerateGUID(false)
	local ReserveOp: any = { Id = `res:{Tid}`, Kind = "__TransferReserve", To = To, Amount = 30, Tid = Tid }
	local AppendReturn = Log.New(W()):Append(tostring(From), { ReserveOp })

	local DeliverOp: any = { Id = `del:{Tid}`, Kind = "__TransferDeliver", From = From, Amount = 30, Tid = Tid }
	Log.New(W()):Append(tostring(To), { DeliverOp })
	local SettleOp: any = { Id = `set:{Tid}`, Kind = "__TransferSettle", Tid = Tid }
	Log.New(W()):Append(tostring(From), { SettleOp })

	local Reread = FoldId(From)
	local RereadSeesHold = Reread._Held ~= nil and Reread._Held[Tid] ~= nil

	local Base: any = if AppendReturn.Snapshot == nil then INIT else AppendReturn.Snapshot
	local AppendState = Fold(Base, AppendReturn.Ops, TR)
	local AppendSeesHold = AppendState._Held ~= nil and AppendState._Held[Tid] ~= nil

	Expect(RereadSeesHold).ToBe(false)
	Expect(AppendSeesHold).ToBe(true)
end

function Suite.TransferPruneDelivered()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40)
	local Sb1 = FoldId(B)
	local Had = type(Sb1._Received) == "table" and next(Sb1._Received) ~= nil

	Transfer.Prune(Log.New(W()), B)
	local Sb2 = FoldId(B)
	local Cleared = Sb2._Received == nil or next(Sb2._Received) == nil

	Expect(Sb1.Gold).ToBe(40)
	Expect(Had).ToBe(true)
	Expect(Sb2.Gold).ToBe(40)
	Expect(Cleared).ToBe(true)
end

function Suite.TransferExpiredRefund()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Tid = HttpService:GenerateGUID(false)
	local ReserveOp: any = { Id = `res:{Tid}`, Kind = "__TransferReserve", To = B, Amount = 60, Tid = Tid, At = os.time() - 9 * 86400 }
	Log.New(W()):Append(tostring(A), { ReserveOp })
	local Sa1 = FoldId(A)

	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, Sa1._Held)
	local Sa2, Sb2 = FoldId(A), FoldId(B)

	Expect(Sa1.Gold).ToBe(40)
	Expect(HeldSum(Sa1)).ToBe(60)
	Expect(Sa2.Gold).ToBe(100)
	Expect(HeldSum(Sa2)).ToBe(0)
	Expect(Sb2.Gold).ToBe(0)
end

function Suite.TransferExpiredButDelivered()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Tid = HttpService:GenerateGUID(false)
	local Old = os.time() - 9 * 86400
	local ReserveOp: any = { Id = `res:{Tid}`, Kind = "__TransferReserve", To = B, Amount = 60, Tid = Tid, At = Old }
	Log.New(W()):Append(tostring(A), { ReserveOp })
	local DeliverOp: any = { Id = `del:{Tid}`, Kind = "__TransferDeliver", From = A, Amount = 60, Tid = Tid, At = Old }
	Log.New(W()):Append(tostring(B), { DeliverOp })

	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, FoldId(A)._Held)
	local Sa2, Sb2 = FoldId(A), FoldId(B)
	local Total = Sa2.Gold + Sb2.Gold + HeldSum(Sa2)

	Expect(Sa2.Gold).ToBe(40)
	Expect(HeldSum(Sa2)).ToBe(0)
	Expect(Sb2.Gold).ToBe(60)
	Expect(Total).ToBe(100)
end

function Suite.TransferReceivedWindow()
	local A, B = Uid(), Uid()
	local Now = os.time()
	local Stale = Now - 31 * 86400
	for Index = 1, 2 do
		local DeliverOp: any = { Id = `del:win{Index}`, Kind = "__TransferDeliver", From = A, Amount = 10, Tid = `win{Index}`, At = Stale }
		Log.New(W()):Append(tostring(B), { DeliverOp })
	end
	local FreshOp: any = { Id = "del:win3", Kind = "__TransferDeliver", From = A, Amount = 10, Tid = "win3", At = Now }
	Log.New(W()):Append(tostring(B), { FreshOp })

	local Sb = FoldId(B)
	local Received = Sb._Received :: { [string]: any }

	Expect(Sb.Gold).ToBe(30)
	Expect(Received["t:win1"]).ToBeNil()
	Expect(Received["t:win2"]).ToBeNil()
	Expect(Received["t:win3"]).Never.ToBeNil()
	Expect(Received["win3"]).ToBeNil()
end

function Suite.TransferConservation()
	local N = 4
	local Accts, Total = {}, 0
	for i = 1, N do
		Accts[i] = Uid()
		Log.New(W()):Append(tostring(Accts[i]), { MakeOp("Add", { Amount = 500 }) })
		Total += 500
	end

	for _ = 1, 60 do
		local From = Accts[RNG:NextInteger(1, N)]
		local To = Accts[RNG:NextInteger(1, N)]
		if From ~= To then
			local Amt = RNG:NextInteger(1, 40)
			local Roll = RNG:NextNumber()
			if Roll < 0.5 then
				pcall(function() return Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), From, To, Amt) end)
			elseif Roll < 0.7 then
				pcall(function() return Transfer.Reserve(Log.New(W()), Log.Shape(TR, INIT), From, To, Amt) end)
			elseif Roll < 0.85 then
				pcall(function()
					local Tid = Transfer.Reserve(Log.New(W()), Log.Shape(TR, INIT), From, To, Amt)
					if Tid then
						local DeliverOp: any = { Id = `del:{Tid}`, Kind = "__TransferDeliver", Tid = Tid, From = From, Amount = Amt }
						Log.New(W()):Append(tostring(To), { DeliverOp })
					end
				end)
			else
				pcall(function() return Log.New(W()):Compact(tostring(From), Log.Shape(TR, INIT)) end)
			end
		end
	end

	for _ = 1, 3 do
		for _, A in Accts do
			pcall(function() Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, FoldId(A)._Held) end)
		end
	end

	local Gold, Held = 0, 0
	for _, A in Accts do
		local S = FoldId(A)
		Gold += S.Gold
		Held += HeldSum(S)
	end

	Expect(Gold).ToBe(Total)
	Expect(Held).ToBe(0)
end

function Suite.TransferExpiredPrunedSettles()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Now = os.time()
	local Old = Now - 31 * 86400
	local Tid = HttpService:GenerateGUID(false)

	Log.New(W()):Append(tostring(A), { { Id = `res:{Tid}`, Kind = "__TransferReserve", To = B, Amount = 60, Tid = Tid, At = Old } :: any })
	Log.New(W()):Append(tostring(B), { { Id = `del:{Tid}`, Kind = "__TransferDeliver", From = A, Amount = 60, Tid = Tid, At = Old } :: any })

	local FreshTid = HttpService:GenerateGUID(false)
	Log.New(W()):Append(tostring(B), { { Id = `del:{FreshTid}`, Kind = "__TransferDeliver", From = A, Amount = 0, Tid = FreshTid, At = Now } :: any })

	local Sb1 = FoldId(B)
	local EvidenceGone = Sb1._Received == nil or Sb1._Received[`t:{Tid}`] == nil

	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, FoldId(A)._Held)
	local Sa2, Sb2 = FoldId(A), FoldId(B)
	local Total = Sa2.Gold + Sb2.Gold + HeldSum(Sa2)

	Expect(EvidenceGone).ToBe(true)
	Expect(Sa2.Gold).ToBe(40)
	Expect(HeldSum(Sa2)).ToBe(0)
	Expect(Sb2.Gold).ToBe(60)
	Expect(Total).ToBe(100)
end

function Suite.TransferHeldSurvivesCloningReducer()
	local A, B = Uid(), Uid()

	local function Cloning(State: any, Op: any): any?
		if Op.Kind ~= "Add" then
			return nil
		end
		local Next = table.clone(State)
		Next.Gold += Op.Amount
		return Next
	end
	local Wrapped = Transfer.Wrap(Cloning, "Gold")

	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	Transfer.Reserve(Log.New(W()), Log.Shape(Wrapped, INIT), A, B, 40)
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 10 }) })

	local S = FoldRecord(tostring(A), Wrapped)

	Expect(HeldSum(S)).ToBe(40)
	Expect(S.Gold).ToBe(70)
end

local Chained = Tx.Wrap(TR)

function Suite.TransferChainedWrapKeepsDelivered()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })

	Transfer.Drive(Log.New(W()), Log.Shape(Chained, INIT), A, B, 40)
	local Delivered = FoldRecord(tostring(B), Chained)

	Log.New(W()):Append(tostring(B), { MakeOp("Add", { Amount = 5 }) })
	local AfterPlain = FoldRecord(tostring(B), Chained)

	local Tid = next(Delivered._Received :: { [string]: any })
	local Redeliver: any = { Id = `del2:{tostring(Tid)}`, Kind = "__TransferDeliver", Tid = Tid, Amount = 40 }
	Log.New(W()):Append(tostring(B), { Redeliver })
	local AfterRedeliver = FoldRecord(tostring(B), Chained)

	Expect(Delivered.Gold).ToBe(40)
	Expect(Tid).Never.ToBeNil()
	Expect(AfterPlain.Gold).ToBe(45)
	Expect(AfterPlain._Received[Tid]).Never.ToBeNil()
	Expect(AfterRedeliver.Gold).ToBe(45)
end

function Suite.TransferChainedWrapStillPrunes()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })

	Transfer.Drive(Log.New(W()), Log.Shape(Chained, INIT), A, B, 40)
	local Before = FoldRecord(tostring(B), Chained)

	Transfer.Prune(Log.New(W()), B)
	local After = FoldRecord(tostring(B), Chained)

	Expect((next(Before._Received :: { [string]: any }))).Never.ToBeNil()
	Expect(After._Received).ToBeNil()
	Expect(After.Gold).ToBe(40)
end

local function OrderId(): string
	return `order-{HttpService:GenerateGUID(false)}`
end

function Suite.TransferRetrySameIdMovesOnce()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Id = OrderId()

	Transfer.Reserve(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)
	local Mid = FoldId(A)

	local Retried = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Mid.Gold).ToBe(60)
	Expect(HeldSum(Mid)).ToBe(40)
	Expect(Retried).ToBe(true)
	Expect(Sa.Gold).ToBe(60)
	Expect(Sb.Gold).ToBe(40)
	Expect(HeldSum(Sa)).ToBe(0)
	Expect(Sa.Gold + Sb.Gold + HeldSum(Sa)).ToBe(100)
end

function Suite.TransferRetryAfterCompleteIsNoop()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Id = OrderId()

	local First = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)
	local Second = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)
	local Third = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(First).ToBe(true)
	Expect(Second).ToBe(true)
	Expect(Third).ToBe(true)
	Expect(Sa.Gold).ToBe(60)
	Expect(Sb.Gold).ToBe(40)
	Expect(HeldSum(Sa)).ToBe(0)
end

function Suite.TransferRetryAfterRefundRefuses()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Id = OrderId()
	local Old = os.time() - 9 * 86400

	Log.New(W()):Append(tostring(A), {
		{ Id = `res:{Id}`, Kind = "__TransferReserve", To = B, Amount = 60, Tid = Id, At = Old } :: any
	})
	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, FoldId(A)._Held)
	local Refunded = FoldId(A)

	local Retried = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 60, Id)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Refunded.Gold).ToBe(100)
	Expect(HeldSum(Refunded)).ToBe(0)
	Expect(Retried).ToBe(false)
	Expect(Sa.Gold).ToBe(100)
	Expect(Sb.Gold).ToBe(0)
end

local function ForgetIds(Key: number, Prefixes: { string })
	Log.New(W()):Compact(tostring(Key), Log.Shape(TR, INIT))
	W():UpdateAsync(tostring(Key), function(Current: any): any
		if type(Current) ~= "table" or type(Current.Seen) ~= "table" then
			return Current
		end

		local Kept = {}
		for _, Id in Current.Seen :: { string } do
			local Strip = false
			for _, Prefix in Prefixes do
				if string.sub(Id, 1, #Prefix) == Prefix then
					Strip = true
				end
			end
			if not Strip then
				table.insert(Kept, Id)
			end
		end

		Current.Seen = Kept
		return Current
	end)
end

function Suite.TransferRetryAfterSenderForgetsConserves()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Id = OrderId()

	Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)
	ForgetIds(A, { `res:{Id}`, `set:{Id}`, `exp:{Id}` })

	local Retried = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Retried).ToBe(true)
	Expect(Sa.Gold).ToBe(60)
	Expect(Sb.Gold).ToBe(40)
	Expect(HeldSum(Sa)).ToBe(0)
	Expect(Sa.Gold + Sb.Gold + HeldSum(Sa)).ToBe(100)
end

function Suite.TransferRetryAfterReceivedPrunedConserves()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Id = OrderId()
	local Old = os.time() - 31 * 86400

	Log.New(W()):Append(tostring(A), {
		{ Id = `res:{Id}`, Kind = "__TransferReserve", To = B, Amount = 40, Tid = Id, At = Old } :: any
	})
	Log.New(W()):Append(tostring(B), {
		{ Id = `del:{Id}`, Kind = "__TransferDeliver", From = A, Amount = 40, Tid = Id, At = Old } :: any
	})
	Log.New(W()):Append(tostring(A), { { Id = `set:{Id}`, Kind = "__TransferSettle", Tid = Id } :: any })

	local Fresh = HttpService:GenerateGUID(false)
	Log.New(W()):Append(tostring(B), {
		{ Id = `del:{Fresh}`, Kind = "__TransferDeliver", From = A, Amount = 0, Tid = Fresh, At = os.time() } :: any
	})

	local Mid = FoldId(B)
	local Forgotten = Mid._Received == nil or Mid._Received[`t:{Id}`] == nil

	ForgetIds(A, { `res:{Id}`, `set:{Id}`, `exp:{Id}` })

	local Retried = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Forgotten).ToBe(true)
	Expect(Retried).ToBe(true)
	Expect(Sa.Gold).ToBe(60)
	Expect(Sb.Gold).ToBe(40)
	Expect(Sa.Gold + Sb.Gold + HeldSum(Sa)).ToBe(100)
end

function Suite.TransferUnkeyedRetryMovesTwice()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })

	Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40)
	Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Sa.Gold).ToBe(20)
	Expect(Sb.Gold).ToBe(80)
	Expect(Sa.Gold + Sb.Gold + HeldSum(Sa)).ToBe(100)
end

local function FailFrom(Inner: any, Method: string, Index: number): any
	local Count = 0
	return setmetatable({}, {
		__index = function(_, Name: string): any
			local Member = Inner[Name]
			if type(Member) ~= "function" then
				return Member
			end
			local Call = Member :: (...any) -> ...any
			return function(_: any, ...): ...any
				if Name == Method then
					Count += 1
					if Count >= Index then
						return false, "chaos: injected failure"
					end
				end
				return Call(Inner, ...)
			end
		end
	})
end

function Suite.TransferReasonRefused()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 30 }) })

	local Ok, Why = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 50)

	Expect(Ok).ToBe(false)
	Expect(Why).ToBe("Refused")
	Expect(HeldSum(FoldId(A))).ToBe(0)
end

function Suite.TransferReasonBusy()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })

	local Txid = HttpService:GenerateGUID(false)
	W():UpdateAsync(tostring(A), function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Txid}:1`, Kind = "Add", Amount = 0, Tx = Txid })
		return Record
	end)

	local Ok, Why = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Ok).ToBe(false)
	Expect(Why).ToBe("Busy")
	Expect(Sa.Gold).ToBe(100)
	Expect(Sb.Gold).ToBe(0)
	Expect(HeldSum(Sa)).ToBe(0)
end

function Suite.TransferReasonSpent()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Id = `order{Uid()}`
	local Old = os.time() - 10 * 86400

	Log.New(W()):Append(tostring(A), {
		{ Id = `res:{Id}`, Kind = "__TransferReserve", To = B, Amount = 40, Tid = Id, At = Old } :: any
	})
	Log.New(W()):Append(tostring(A), { { Id = `exp:{Id}`, Kind = "__TransferExpire", Tid = Id } :: any })

	local Ok, Why = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Ok).ToBe(false)
	Expect(Why).ToBe("Spent")
	Expect(Sa.Gold).ToBe(100)
	Expect(Sb.Gold).ToBe(0)
end

function Suite.TransferReasonHeld()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })

	local Ok, Why, Escrowed = Transfer.Drive(Log.New(FailFrom(W(), "UpdateAsync", 2)), Log.Shape(TR, INIT), A, B, 40)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Ok).ToBe(false)
	Expect(Why).ToBe("Unresolved")
	Expect(Escrowed).ToBe(true)
	Expect(Sa.Gold).ToBe(60)
	Expect(HeldSum(Sa)).ToBe(40)
	Expect(Sb.Gold).ToBe(0)
	Expect(Sa.Gold + Sb.Gold + HeldSum(Sa)).ToBe(100)

	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, Sa._Held)
	local Fa, Fb = FoldId(A), FoldId(B)

	Expect(HeldSum(Fa)).ToBe(0)
	Expect(Fb.Gold).ToBe(40)
	Expect(Fa.Gold + Fb.Gold + HeldSum(Fa)).ToBe(100)
end

function Suite.TransferSuccessCarriesNoReason()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Id = `order{Uid()}`

	local First, FirstWhy = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)
	local Again, AgainWhy = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)

	Expect(First).ToBe(true)
	Expect(FirstWhy).ToBeNil()
	Expect(Again).ToBe(true)
	Expect(AgainWhy).ToBeNil()
	Expect(FoldId(B).Gold).ToBe(40)
end

function Suite.TransferExpireSeesDeliveryAfterClearDelivered()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Old = os.time() - 10 * 86400
	local Tid = HttpService:GenerateGUID(false)

	Log.New(W()):Append(tostring(A), {
		{ Id = `res:{Tid}`, Kind = "__TransferReserve", To = B, Amount = 40, Tid = Tid, At = Old } :: any
	})
	Log.New(W()):Append(tostring(B), {
		{ Id = `del:{Tid}`, Kind = "__TransferDeliver", From = A, Amount = 40, Tid = Tid, At = Old } :: any
	})

	Transfer.Prune(Log.New(W()), B)
	local Cleared = FoldId(B)._Received == nil

	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, FoldId(A)._Held)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Cleared).ToBe(true)
	Expect(Sa.Gold).ToBe(60)
	Expect(HeldSum(Sa)).ToBe(0)
	Expect(Sb.Gold).ToBe(40)
	Expect(Sa.Gold + Sb.Gold + HeldSum(Sa)).ToBe(100)
end

function Suite.TransferAndTxShareANameSafely()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Name = `order{Uid()}`
	local TxStore = DataStoreWrapper.New(`{Harness.STORE}_Tx`, 30, 0.15, 1.1)

	local Moved, MovedWhy = Transfer.Drive(Log.New(W()), Log.Shape(Chained, INIT), A, B, 40, Name)

	local Records, Format = Log.New(W()), Log.Shape(Chained, INIT)
	local Committed, CommittedWhy = Tx.Drive(TxStore, {
		{ Key = tostring(B), Kind = "Add", Fields = { Amount = 5 }, Log = Records, Shape = Format, TxStore = TxStore },
		{ Key = tostring(A), Kind = "Add", Fields = { Amount = 5 }, Log = Records, Shape = Format, TxStore = TxStore }
	}, Name)

	local Sa = FoldRecord(tostring(A), Chained)
	local Sb = FoldRecord(tostring(B), Chained)

	Expect(Moved).ToBe(true)
	Expect(MovedWhy).ToBeNil()
	Expect(Committed).ToBe(true)
	Expect(CommittedWhy).ToBeNil()
	Expect(Sb.Gold).ToBe(45)
	Expect(Sa.Gold).ToBe(65)
	Expect(Sb._Received[`t:{Name}`]).Never.ToBeNil()
	Expect(Sb._Received[`x:{Name}`]).Never.ToBeNil()
end

function Suite.TransferMarginHoldIsLeftAlone()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Mid = os.time() - 7 * 86400 - 43200
	local Tid = HttpService:GenerateGUID(false)

	Log.New(W()):Append(tostring(A), {
		{ Id = `res:{Tid}`, Kind = "__TransferReserve", To = B, Amount = 40, Tid = Tid, At = Mid } :: any
	})

	Transfer.Recover(Log.New(W()), Log.Shape(TR, INIT), A, FoldId(A)._Held)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(HeldSum(Sa)).ToBe(40)
	Expect(Sa.Gold).ToBe(60)
	Expect(Sb.Gold).ToBe(0)
	Expect(Sa.Gold + Sb.Gold + HeldSum(Sa)).ToBe(100)
end

function Suite.TransferReplayedReserveDoesNotDoubleDebit()
	local A, B = Uid(), Uid()
	Log.New(W()):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Id = `order{Uid()}`

	Log.New(W()):Append(tostring(A), {
		{ Id = `res:{Id}`, Kind = "__TransferReserve", To = B, Amount = 40, Tid = Id, At = os.time() } :: any
	})
	local Held = FoldId(A)

	ForgetIds(A, { `res:{Id}` })

	local Retried, Why = Transfer.Drive(Log.New(W()), Log.Shape(TR, INIT), A, B, 40, Id)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Held.Gold).ToBe(60)
	Expect(HeldSum(Held)).ToBe(40)
	Expect(Retried).ToBe(true)
	Expect(Why).ToBeNil()
	Expect(Sb.Gold).ToBe(40)
	Expect(Sa.Gold).ToBe(60)
	Expect(HeldSum(Sa)).ToBe(0)
	Expect(Sa.Gold + Sb.Gold + HeldSum(Sa)).ToBe(100)
end

return table.freeze(Suite)
