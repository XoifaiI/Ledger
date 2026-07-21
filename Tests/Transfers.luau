--!strict

local HttpService = game:GetService("HttpService")

local Harness = require("./Harness")
local Log = require("../src/Log")
local Fold = require("../src/Fold")
local MakeOp = require("../src/MakeOp")
local Transfer = require("../src/Transfer")
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
	Log.Append(W(), tostring(A), { MakeOp("Add", { Amount = 100 }) })

	local Ok = Transfer.Drive(W(), TR, INIT, A, B, 50)
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
	Log.Append(W(), tostring(A), { MakeOp("Add", { Amount = 30 }) })

	local Ok = Transfer.Drive(W(), TR, INIT, A, B, 50)
	local Sa, Sb = FoldId(A), FoldId(B)

	Expect(Ok).ToBeFalsy()
	Expect(Sa.Gold).ToBe(30)
	Expect(Sb.Gold).ToBe(0)
	Expect(HeldSum(Sa)).ToBe(0)
end

function Suite.TransferCrashRecover()
	local A, B = Uid(), Uid()
	Log.Append(W(), tostring(A), { MakeOp("Add", { Amount = 100 }) })

	Transfer.Reserve(W(), TR, INIT, A, B, 50)
	local Sa1 = FoldId(A)

	Expect(Sa1.Gold).ToBe(50)
	Expect(HeldSum(Sa1)).ToBe(50)
	Expect(FoldId(B).Gold).ToBe(0)

	Transfer.Recover(W(), TR, INIT, nil, A, Sa1._Held)
	local Sa2, Sb2 = FoldId(A), FoldId(B)
	local Total = Sa2.Gold + Sb2.Gold + HeldSum(Sa2)

	Expect(Sa2.Gold).ToBe(50)
	Expect(Sb2.Gold).ToBe(50)
	Expect(HeldSum(Sa2)).ToBe(0)
	Expect(Total).ToBe(100)
end

function Suite.TransferDoubleRecover()
	local A, B = Uid(), Uid()
	Log.Append(W(), tostring(A), { MakeOp("Add", { Amount = 100 }) })
	Transfer.Reserve(W(), TR, INIT, A, B, 50)
	local Held = FoldId(A)._Held

	Transfer.Recover(W(), TR, INIT, nil, A, Held)
	Transfer.Recover(W(), TR, INIT, nil, A, Held)
	Transfer.Recover(W(), TR, INIT, nil, A, Held)

	local Sb = FoldId(B)

	Expect(Sb.Gold).ToBe(50)
end

function Suite.TransferConcurrentConserve()
	local Accts = {}
	for i = 1, 4 do
		Accts[i] = Uid()
		Log.Append(W(), tostring(Accts[i]), { MakeOp("Add", { Amount = 100 }) })
	end

	local Thunks = {}
	for i = 1, 8 do
		Thunks[i] = function()
			local From = Accts[RNG:NextInteger(1, 4)]
			local To = Accts[RNG:NextInteger(1, 4)]
			if From ~= To then
				pcall(Transfer.Drive, W(), TR, INIT, From, To, RNG:NextInteger(1, 30))
			end
		end
	end
	Race("TransferConcurrentConserve", Thunks)

	local Total = 0
	for _, A in Accts do
		local S = FoldId(A)
		Total += S.Gold + HeldSum(S)
	end

	Expect(Total).ToBe(400)
end

function Suite.TransferWindowMint()
	local B = Uid()
	local T0 = HttpService:GenerateGUID(false)

	local Batch: { any } = { { Id = "del:" .. T0, Kind = "__TransferDeliver", Tid = T0, Amount = 100 } }
	for _ = 1, 1030 do
		local U = HttpService:GenerateGUID(false)
		table.insert(Batch, { Id = "del:" .. U, Kind = "__TransferDeliver", Tid = U, Amount = 0 })
	end
	Log.Append(W(), tostring(B), Batch)
	local G1 = FoldId(B).Gold

	local Redeliver: any = { Id = "del2:" .. T0, Kind = "__TransferDeliver", Tid = T0, Amount = 100 }
	Log.Append(W(), tostring(B), { Redeliver })
	local G2 = FoldId(B).Gold

	Expect(G1).ToBe(100)
	Expect(G2).ToBe(100)
end

function Suite.TransferHeldSurvivesEdit()
	local A, B = Uid(), Uid()
	Log.Append(W(), tostring(A), { MakeOp("Add", { Amount = 100 }) })
	Transfer.Reserve(W(), TR, INIT, A, B, 40)
	Log.Append(W(), tostring(A), { MakeOp("Add", { Amount = 10 }) })

	local S = FoldId(A)

	Expect(HeldSum(S)).ToBe(40)
	Expect(S.Gold).ToBe(70)
end

function Suite.TransferRecoverCompletes()
	local A, B = Uid(), Uid()
	Log.Append(W(), tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Tid = Transfer.Reserve(W(), TR, INIT, A, B, 60) :: string
	local DeliverOp: any = { Id = "del:" .. Tid, Kind = "__TransferDeliver", Tid = Tid, From = A, Amount = 60 }
	Log.Append(W(), tostring(B), { DeliverOp })
	local Sa1, Sb1 = FoldId(A), FoldId(B)

	Transfer.Recover(W(), TR, INIT, nil, A, Sa1._Held)
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
	Log.Append(W(), tostring(From), { MakeOp("Add", { Amount = 100 }) })

	local Tid = HttpService:GenerateGUID(false)
	local ReserveOp: any = { Id = "res:" .. Tid, Kind = "__TransferReserve", To = To, Amount = 30, Tid = Tid }
	local AppendReturn = Log.Append(W(), tostring(From), { ReserveOp })

	local DeliverOp: any = { Id = "del:" .. Tid, Kind = "__TransferDeliver", From = From, Amount = 30, Tid = Tid }
	Log.Append(W(), tostring(To), { DeliverOp })
	local SettleOp: any = { Id = "set:" .. Tid, Kind = "__TransferSettle", Tid = Tid }
	Log.Append(W(), tostring(From), { SettleOp })

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
	Log.Append(W(), tostring(A), { MakeOp("Add", { Amount = 100 }) })
	Transfer.Drive(W(), TR, INIT, A, B, 40)
	local Sb1 = FoldId(B)
	local Had = type(Sb1._Received) == "table" and next(Sb1._Received) ~= nil

	Transfer.Prune(W(), B)
	local Sb2 = FoldId(B)
	local Cleared = Sb2._Received == nil or next(Sb2._Received) == nil

	Expect(Sb1.Gold).ToBe(40)
	Expect(Had).ToBe(true)
	Expect(Sb2.Gold).ToBe(40)
	Expect(Cleared).ToBe(true)
end

function Suite.TransferExpiredRefund()
	local A, B = Uid(), Uid()
	Log.Append(W(), tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Tid = HttpService:GenerateGUID(false)
	local ReserveOp: any = { Id = "res:" .. Tid, Kind = "__TransferReserve", To = B, Amount = 60, Tid = Tid, At = os.time() - 9 * 86400 }
	Log.Append(W(), tostring(A), { ReserveOp })
	local Sa1 = FoldId(A)

	Transfer.Recover(W(), TR, INIT, nil, A, Sa1._Held)
	local Sa2, Sb2 = FoldId(A), FoldId(B)

	Expect(Sa1.Gold).ToBe(40)
	Expect(HeldSum(Sa1)).ToBe(60)
	Expect(Sa2.Gold).ToBe(100)
	Expect(HeldSum(Sa2)).ToBe(0)
	Expect(Sb2.Gold).ToBe(0)
end

function Suite.TransferExpiredButDelivered()
	local A, B = Uid(), Uid()
	Log.Append(W(), tostring(A), { MakeOp("Add", { Amount = 100 }) })
	local Tid = HttpService:GenerateGUID(false)
	local Old = os.time() - 9 * 86400
	local ReserveOp: any = { Id = "res:" .. Tid, Kind = "__TransferReserve", To = B, Amount = 60, Tid = Tid, At = Old }
	Log.Append(W(), tostring(A), { ReserveOp })
	local DeliverOp: any = { Id = "del:" .. Tid, Kind = "__TransferDeliver", From = A, Amount = 60, Tid = Tid, At = Old }
	Log.Append(W(), tostring(B), { DeliverOp })

	Transfer.Recover(W(), TR, INIT, nil, A, FoldId(A)._Held)
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
		local DeliverOp: any = { Id = "del:win" .. Index, Kind = "__TransferDeliver", From = A, Amount = 10, Tid = "win" .. Index, At = Stale }
		Log.Append(W(), tostring(B), { DeliverOp })
	end
	local FreshOp: any = { Id = "del:win3", Kind = "__TransferDeliver", From = A, Amount = 10, Tid = "win3", At = Now }
	Log.Append(W(), tostring(B), { FreshOp })

	local Sb = FoldId(B)
	local Received = Sb._Received :: { [string]: any }

	Expect(Sb.Gold).ToBe(30)
	Expect(Received["win1"]).ToBeNil()
	Expect(Received["win2"]).ToBeNil()
	Expect(Received["win3"]).Never.ToBeNil()
end

function Suite.TransferConservation()
	local N = 4
	local Accts, Total = {}, 0
	for i = 1, N do
		Accts[i] = Uid()
		Log.Append(W(), tostring(Accts[i]), { MakeOp("Add", { Amount = 500 }) })
		Total += 500
	end

	for _ = 1, 60 do
		local From = Accts[RNG:NextInteger(1, N)]
		local To = Accts[RNG:NextInteger(1, N)]
		if From ~= To then
			local Amt = RNG:NextInteger(1, 40)
			local Roll = RNG:NextNumber()
			if Roll < 0.5 then
				pcall(Transfer.Drive, W(), TR, INIT, From, To, Amt)
			elseif Roll < 0.7 then
				pcall(Transfer.Reserve, W(), TR, INIT, From, To, Amt)
			elseif Roll < 0.85 then
				pcall(function()
					local Tid = Transfer.Reserve(W(), TR, INIT, From, To, Amt)
					if Tid then
						local DeliverOp: any = { Id = "del:" .. Tid, Kind = "__TransferDeliver", Tid = Tid, From = From, Amount = Amt }
						Log.Append(W(), tostring(To), { DeliverOp })
					end
				end)
			else
				pcall(Log.Compact, W(), tostring(From), TR, INIT)
			end
		end
	end

	for _ = 1, 3 do
		for _, A in Accts do
			pcall(Transfer.Recover, W(), TR, INIT, nil, A, FoldId(A)._Held)
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

return table.freeze(Suite)
