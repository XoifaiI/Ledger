--!strict

--[=[
    Tx suite: the lock free two phase commit must apply both legs or neither, refuse a
    second transaction on a busy key, survive every crash window (a stale pending marker
    gets bystander aborted, a committed marker with unresolved legs heals to applied),
    keep aborted leg ids retired so an idempotent re prepare cannot resurrect them, and
    hold its invariants under chaos: random fault injection (calls that fail before
    running and calls that succeed but REPORT failure, the unacked commit window),
    concurrent coordinators, random timeouts and crashed drives. after settling, gold is
    conserved, the traded item lives in exactly one bag, and no pending legs remain.

    the chaos round is intentionally non deterministic; the seed is printed so a failing
    run can be replayed.

    the cross store tests cover legs on different datastores: atomic commit and abort,
    dead leg or marker stores, TxHome settlement by servers that do not own the marker
    (including a live session), the unknown verdict rule (a lost ack still commits both
    legs, a dead marker store aborts both by timeout, never one of each), orphan legs
    past a shrunk away marker, cross coordinator busy, and a conservation storm.

    Return type: frozen table of test functions, each asserts through Testing.Expect
    Example usage:
        local Suite = require("./Tx")
        Suite.TxCommitsSwap()
--]=]

local HttpService = game:GetService("HttpService")

local DataStoreWrapper = require("../src/Util/DataStoreWrapper")
local Log = require("../src/Log")
local Session = require("../src/Session")
local Tx = require("../src/Tx")
local IsStorable = require("../src/Storable")
local Harness = require("./Harness")
local Testing = require("./Testing")

local Expect = Testing.Expect
local W = Harness.Store
local Key = Harness.Key

local Suite = {}

local TINIT: any = { Gold = 0, Items = {} }
local STALE = -3600

local function TradeReducer(State: any, Op: any): any?
	if Op.Kind ~= "Delta" then
		return nil
	end

	local Gold = State.Gold + (Op.Gold or 0)
	if Gold < 0 then
		return nil
	end

	local Items = table.clone(State.Items)
	if Op.Drop ~= nil then
		if not Items[Op.Drop] then
			return nil
		end
		Items[Op.Drop] = nil
	end
	if Op.Gain ~= nil then
		if Items[Op.Gain] then
			return nil
		end
		Items[Op.Gain] = true
	end

	return { Gold = Gold, Items = Items }
end

local function TxStore(): DataStoreWrapper.DataStoreWrapper
	return DataStoreWrapper.New(Harness.STORE .. "_Tx", 30, 0.15, 1.1)
end

local function Seed(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string, Gold: number, Items: { [string]: true })
	Wrapper:UpdateAsync(K, function()
		return { Snapshot = { Gold = Gold, Items = Items }, Ops = {} }
	end)
end

local function Fold(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string): any
	return Log.FoldRecord(Log.Read(Wrapper, K), TINIT, TradeReducer)
end

local function Clean(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string): boolean
	return not Log.HasPending(Log.Read(Wrapper, K))
end

local function SwapLegs(A: string, B: string, Price: number): { Tx.Leg }
	return {
		{ Key = A, Kind = "Delta", Fields = { Gold = Price, Drop = "Sword" } },
		{ Key = B, Kind = "Delta", Fields = { Gold = -Price, Gain = "Sword" } },
	}
end

local function CraftPending(Wrapper: DataStoreWrapper.DataStoreWrapper, Store: DataStoreWrapper.DataStoreWrapper, A: string, B: string, Status: string): string
	local Txid = HttpService:GenerateGUID(false)
	Store:UpdateAsync(Txid, function()
		return { Status = Status, Total = 2, Adopted = 0 }
	end)
	Wrapper:UpdateAsync(A, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Txid}:1`, Kind = "Delta", Gold = 25, Drop = "Sword", Tx = Txid })
		return Record
	end)
	Wrapper:UpdateAsync(B, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Txid}:2`, Kind = "Delta", Gold = -25, Gain = "Sword", Tx = Txid })
		return Record
	end)
	return Txid
end

function Suite.TxCommitsSwap()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txa"), Key("txb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})

	local Committed = Tx.Drive(Wrapper, Store, TradeReducer, TINIT, nil, SwapLegs(A, B, 25))
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Committed).ToBe(true)
	Expect(SA.Gold).ToBe(125)
	Expect(SA.Items.Sword).ToBeNil()
	Expect(SB.Gold).ToBe(75)
	Expect(SB.Items.Sword).ToBe(true)
	Expect(Clean(Wrapper, A)).ToBe(true)
	Expect(Clean(Wrapper, B)).ToBe(true)
end

function Suite.TxAtomicAbort()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txaa"), Key("txab")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 10, {})

	local Committed = Tx.Drive(Wrapper, Store, TradeReducer, TINIT, nil, SwapLegs(A, B, 25))
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Committed).ToBe(false)
	Expect(SA.Gold).ToBe(100)
	Expect(SA.Items.Sword).ToBe(true)
	Expect(SB.Gold).ToBe(10)
	Expect(Clean(Wrapper, A)).ToBe(true)
	Expect(Clean(Wrapper, B)).ToBe(true)
end

function Suite.TxStalePendingBystanderAborts()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txsa"), Key("txsb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	local Txid = CraftPending(Wrapper, Store, A, B, "Pending")

	Tx.Settle(Wrapper, Store, A, Log.Read(Wrapper, A), STALE)
	Tx.Settle(Wrapper, Store, B, Log.Read(Wrapper, B), STALE)

	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)
	local _, Marker = Store:GetAsync(Txid)

	Expect(SA.Gold).ToBe(100)
	Expect(SA.Items.Sword).ToBe(true)
	Expect(SB.Gold).ToBe(100)
	Expect(Clean(Wrapper, A)).ToBe(true)
	Expect(Clean(Wrapper, B)).ToBe(true)
	Expect(Marker).ToBeNil()
end

function Suite.TxCommittedCrashHeals()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txca"), Key("txcb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	local Txid = CraftPending(Wrapper, Store, A, B, "Committed")

	Tx.Settle(Wrapper, Store, A, Log.Read(Wrapper, A), STALE)
	Tx.Settle(Wrapper, Store, B, Log.Read(Wrapper, B), STALE)

	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)
	local _, Marker = Store:GetAsync(Txid)

	Expect(SA.Gold).ToBe(125)
	Expect(SA.Items.Sword).ToBeNil()
	Expect(SB.Gold).ToBe(75)
	Expect(SB.Items.Sword).ToBe(true)
	Expect(Marker).ToBeNil()
end

function Suite.TxBusyKeyRefused()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txba"), Key("txbb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	CraftPending(Wrapper, Store, A, B, "Pending")

	local Committed = Tx.Drive(Wrapper, Store, TradeReducer, TINIT, nil, SwapLegs(A, B, 10), 120)

	Tx.Settle(Wrapper, Store, A, Log.Read(Wrapper, A), STALE)
	Tx.Settle(Wrapper, Store, B, Log.Read(Wrapper, B), STALE)
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Committed).ToBe(false)
	Expect(SA.Gold).ToBe(100)
	Expect(SB.Gold).ToBe(100)
end

function Suite.TxAbortedLegCannotResurrect()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txza"), Key("txzb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	local Txid = CraftPending(Wrapper, Store, A, B, "Pending")

	Tx.Settle(Wrapper, Store, A, Log.Read(Wrapper, A), STALE)
	local Verdict = Log.Prepare(Wrapper, A, { Id = `tx:{Txid}:1`, Kind = "Delta", Gold = 25, Drop = "Sword", Tx = Txid } :: any, TradeReducer, TINIT)
	Tx.Settle(Wrapper, Store, B, Log.Read(Wrapper, B), STALE)

	local SA = Fold(Wrapper, A)

	Expect(Verdict).ToBe("Aborted")
	Expect(SA.Gold).ToBe(100)
	Expect(SA.Items.Sword).ToBe(true)
end

function Suite.TxReservedField()
	local Storable, Reason = IsStorable.Op({ Id = "x", Kind = "Delta", Tx = "hax" })

	Expect(Storable).ToBe(false)
	Expect(Reason).ToBeDefined()
	Expect((string.find(Reason :: string, "reserved", 1, true))).Never.ToBeNil()
end

local function Faulty(Inner: any, RNG: Random, FailRate: number, LieRate: number): any
	return setmetatable({}, {
		__index = function(_, Name: string): any
			local Member = Inner[Name]
			if type(Member) ~= "function" then
				return Member
			end
			local Call = Member :: (...any) -> ...any
			return function(_: any, ...): ...any
				if RNG:NextNumber() < FailRate then
					return false, "chaos: injected failure before the call"
				end
				local Results = table.pack(Call(Inner, ...))
				if Results[1] == true and RNG:NextNumber() < LieRate then
					return false, "chaos: the call committed but the response was lost"
				end
				return table.unpack(Results, 1, Results.n)
			end
		end,
	})
end

function Suite.TxChaosSwapStorm()
	local SeedValue = math.floor((os.clock() % 1) * 2 ^ 30) + 1
	local RNG = Random.new(SeedValue)
	print(`TxChaosSwapStorm seed={SeedValue}`)

	local Real, Store = W(), TxStore()
	local A, B = Key("txcha"), Key("txchb")
	Seed(Real, A, 100, { Sword = true })
	Seed(Real, B, 100, {})

	local ROUNDS = 6

	for _ = 1, ROUNDS do
		local ChaosW = Faulty(Real, RNG, 0.1, 0.1)
		local ChaosT = Faulty(Store, RNG, 0.1, 0.1)
		local Timeout = if RNG:NextNumber() < 0.5 then STALE else 60

		local Jobs = RNG:NextInteger(1, 2)
		local Done = 0
		for _ = 1, Jobs do
			task.spawn(function()
				local Holder = if Fold(Real, A).Items.Sword then A else B
				local Other = if Holder == A then B else A
				local Price = RNG:NextInteger(0, 30)

				pcall(Tx.Drive, ChaosW, ChaosT, TradeReducer, TINIT, nil, SwapLegs(Holder, Other, Price), Timeout)
				Done += 1
			end)
		end

		pcall(function()
			Log.Append(ChaosW, if RNG:NextNumber() < 0.5 then A else B, { { Id = HttpService:GenerateGUID(false), Kind = "Delta", Gold = 0 } :: any })
		end)

		local Deadline = os.clock() + 30
		while Done < Jobs and os.clock() < Deadline do
			task.wait(0.1)
		end
	end

	for _ = 1, 3 do
		Tx.Settle(Real, Store, A, Log.Read(Real, A), STALE)
		Tx.Settle(Real, Store, B, Log.Read(Real, B), STALE)
	end

	local SA, SB = Fold(Real, A), Fold(Real, B)
	local SwordAtA = SA.Items.Sword == true
	local SwordAtB = SB.Items.Sword == true

	Expect(SA.Gold + SB.Gold).ToBe(200)
	Expect((SwordAtA or SwordAtB) and not (SwordAtA and SwordAtB)).ToBe(true)
	Expect(Clean(Real, A)).ToBe(true)
	Expect(Clean(Real, B)).ToBe(true)
end

local VINIT: any = { Coins = 0 }

local function VaultReducer(State: any, Op: any): any?
	if Op.Kind ~= "Vault" then
		return nil
	end
	local Coins = State.Coins + (Op.Coins or 0)
	if Coins < 0 then
		return nil
	end
	return { Coins = Coins }
end

local function StoreB(): DataStoreWrapper.DataStoreWrapper
	return DataStoreWrapper.New(Harness.STORE .. "_B", 30, 0.15, 1.1)
end

local function SeedVault(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string, Coins: number)
	Wrapper:UpdateAsync(K, function()
		return { Snapshot = { Coins = Coins }, Ops = {} }
	end)
end

local function FoldVault(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string): any
	return Log.FoldRecord(Log.Read(Wrapper, K), VINIT, VaultReducer)
end

local function CrossLegs(WrapB: any, A: string, B: string, Amount: number): { Tx.Leg }
	return {
		{ Key = A, Kind = "Delta", Fields = { Gold = -Amount } },
		{ Key = B, Kind = "Vault", Fields = { Coins = Amount }, Wrapper = WrapB, Reducer = VaultReducer, Initial = VINIT },
	}
end

function Suite.TxCrossStoreCommits()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local A, B = Key("txxa"), Key("txxb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)

	local Committed = Tx.Drive(WrapA, Store, TradeReducer, TINIT, nil, CrossLegs(WrapB, A, B, 25))
	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)

	Expect(Committed).ToBe(true)
	Expect(SA.Gold).ToBe(75)
	Expect(SB.Coins).ToBe(25)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
end

function Suite.TxCrossStoreAtomicAbort()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local A, B = Key("txva"), Key("txvb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 10)

	local Legs: { Tx.Leg } = {
		{ Key = A, Kind = "Delta", Fields = { Gold = 25 } },
		{ Key = B, Kind = "Vault", Fields = { Coins = -25 }, Wrapper = WrapB, Reducer = VaultReducer, Initial = VINIT },
	}
	local Committed = Tx.Drive(WrapA, Store, TradeReducer, TINIT, nil, Legs)
	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)

	Expect(Committed).ToBe(false)
	Expect(SA.Gold).ToBe(100)
	Expect(SB.Coins).ToBe(10)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
end

function Suite.TxCrossStoreLegDown()
	local WrapA, Store = W(), TxStore()
	local DeadB = Faulty(StoreB(), Random.new(1), 1, 0)
	local A, B = Key("txda"), Key("txdb")
	Seed(WrapA, A, 100, {})

	local Committed = Tx.Drive(WrapA, Store, TradeReducer, TINIT, nil, CrossLegs(DeadB, A, B, 25))
	local SA = Fold(WrapA, A)

	Expect(Committed).ToBe(false)
	Expect(SA.Gold).ToBe(100)
	Expect(Clean(WrapA, A)).ToBe(true)
end

function Suite.TxCrossStoreMarkerDown()
	local WrapA, WrapB = W(), StoreB()
	local DeadMarker = Faulty(TxStore(), Random.new(2), 1, 0)
	local A, B = Key("txma"), Key("txmb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)

	local Committed = Tx.Drive(WrapA, DeadMarker, TradeReducer, TINIT, nil, CrossLegs(WrapB, A, B, 25))
	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)
	local RecA, RecB = Log.Read(WrapA, A), Log.Read(WrapB, B)

	Expect(Committed).ToBe(false)
	Expect(SA.Gold).ToBe(100)
	Expect(SB.Coins).ToBe(0)
	Expect(#RecA.Ops).ToBe(0)
	Expect(#RecB.Ops).ToBe(0)
end

function Suite.TxCrossStoreCrashSettles()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local A, B = Key("txha"), Key("txhb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)

	local Txid = HttpService:GenerateGUID(false)
	Store:UpdateAsync(Txid, function()
		return { Status = "Committed", Total = 2, Adopted = 0 }
	end)
	WrapA:UpdateAsync(A, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Txid}:1`, Kind = "Delta", Gold = -25, Tx = Txid, TxHome = Store.Name })
		return Record
	end)
	WrapB:UpdateAsync(B, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Txid}:2`, Kind = "Vault", Coins = 25, Tx = Txid, TxHome = Store.Name })
		return Record
	end)

	local ForeignTx = DataStoreWrapper.New(Harness.STORE .. "_B_Tx", 30, 0.15, 1.1)
	Tx.Settle(WrapB, ForeignTx, B, Log.Read(WrapB, B), STALE)
	Tx.Settle(WrapA, Store, A, Log.Read(WrapA, A), STALE)

	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)
	local _, Marker = Store:GetAsync(Txid)

	Expect(SA.Gold).ToBe(75)
	Expect(SB.Coins).ToBe(25)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
	Expect(Marker).ToBeNil()
end

function Suite.TxCrossStoreConservationStorm()
	local SeedValue = math.floor((os.clock() % 1) * 2 ^ 30) + 1
	local RNG = Random.new(SeedValue)
	print(`TxCrossStoreConservationStorm seed={SeedValue}`)

	local RealA, RealB, Store = W(), StoreB(), TxStore()
	local A, B = Key("txwa"), Key("txwb")
	Seed(RealA, A, 100, {})
	SeedVault(RealB, B, 100)

	local ROUNDS = 6
	for _ = 1, ROUNDS do
		local ChaosA = Faulty(RealA, RNG, 0.1, 0.1)
		local ChaosB = Faulty(RealB, RNG, 0.1, 0.1)
		local ChaosT = Faulty(Store, RNG, 0.1, 0.1)
		local Timeout = if RNG:NextNumber() < 0.5 then STALE else 60

		local Jobs = RNG:NextInteger(1, 2)
		local Done = 0
		for _ = 1, Jobs do
			task.spawn(function()
				local Amount = RNG:NextInteger(0, 30)
				local Sign = if RNG:NextNumber() < 0.5 then 1 else -1
				local Legs: { Tx.Leg } = {
					{ Key = A, Kind = "Delta", Fields = { Gold = -Amount * Sign } },
					{
						Key = B,
						Kind = "Vault",
						Fields = { Coins = Amount * Sign },
						Wrapper = ChaosB,
						Reducer = VaultReducer,
						Initial = VINIT,
					},
				}
				pcall(Tx.Drive, ChaosA, ChaosT, TradeReducer, TINIT, nil, Legs, Timeout)
				Done += 1
			end)
		end

		local Deadline = os.clock() + 30
		while Done < Jobs and os.clock() < Deadline do
			task.wait(0.1)
		end
	end

	for _ = 1, 3 do
		Tx.Settle(RealA, Store, A, Log.Read(RealA, A), STALE)
		Tx.Settle(RealB, Store, B, Log.Read(RealB, B), STALE)
	end

	local SA, SB = Fold(RealA, A), FoldVault(RealB, B)

	Expect(SA.Gold + SB.Coins).ToBe(200)
	Expect(SA.Gold >= 0 and SB.Coins >= 0).ToBe(true)
	Expect(Clean(RealA, A)).ToBe(true)
	Expect(Clean(RealB, B)).ToBe(true)
end

local function FailOn(Inner: any, Method: string, Index: number, Lie: boolean): any
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
					if Count == Index then
						if Lie then
							Call(Inner, ...)
						end
						return false, "chaos: injected marker failure"
					end
				end
				return Call(Inner, ...)
			end
		end,
	})
end

function Suite.TxDecideLostAckCommits()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local Lying = FailOn(Store, "UpdateAsync", 2, true)
	local A, B = Key("txla"), Key("txlb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)

	local Committed = Tx.Drive(WrapA, Lying, TradeReducer, TINIT, nil, CrossLegs(WrapB, A, B, 25))
	local PendingA = Log.HasPending(Log.Read(WrapA, A))
	local PendingB = Log.HasPending(Log.Read(WrapB, B))

	Tx.Settle(WrapA, Store, A, Log.Read(WrapA, A), STALE)
	Tx.Settle(WrapB, Store, B, Log.Read(WrapB, B), STALE)
	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)

	Expect(Committed).ToBe(false)
	Expect(PendingA).ToBe(true)
	Expect(PendingB).ToBe(true)
	Expect(SA.Gold).ToBe(75)
	Expect(SB.Coins).ToBe(25)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
end

function Suite.TxDecideDownAbortsByTimeout()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local Dead = FailOn(Store, "UpdateAsync", 2, false)
	local A, B = Key("txna"), Key("txnb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)

	local Committed = Tx.Drive(WrapA, Dead, TradeReducer, TINIT, nil, CrossLegs(WrapB, A, B, 25))
	local PendingA = Log.HasPending(Log.Read(WrapA, A))
	local PendingB = Log.HasPending(Log.Read(WrapB, B))

	Tx.Settle(WrapA, Store, A, Log.Read(WrapA, A), STALE)
	Tx.Settle(WrapB, Store, B, Log.Read(WrapB, B), STALE)
	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)

	Expect(Committed).ToBe(false)
	Expect(PendingA).ToBe(true)
	Expect(PendingB).ToBe(true)
	Expect(SA.Gold).ToBe(100)
	Expect(SB.Coins).ToBe(0)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
end

function Suite.TxSessionSettlesForeignLeg()
	local Wrapper, Store = W(), TxStore()
	local K = Key("txsl")
	local Txid = HttpService:GenerateGUID(false)
	Store:UpdateAsync(Txid, function()
		return { Status = "Committed", Total = 1, Adopted = 0 }
	end)
	Wrapper:UpdateAsync(K, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Txid}:1`, Kind = "Add", Amount = 25, Tx = Txid, TxHome = Store.Name })
		return Record
	end)

	local LocalTx = DataStoreWrapper.New(Harness.STORE .. "_B_Tx", 30, 0.15, 1.1)
	local Active = Session.Load(Wrapper, K, Harness.Reducer, Harness.INIT, nil, LocalTx):Wait()
	local State = Active:Get()
	local Applied = Active:Apply("Add", { Amount = 5 })
	Active:Release():Wait()

	local _, Marker = Store:GetAsync(Txid)

	Expect(State.Gold).ToBe(25)
	Expect(Applied).ToBe(true)
	Expect(Clean(Wrapper, K)).ToBe(true)
	Expect(Marker).ToBeNil()
end

local function StoreC(): DataStoreWrapper.DataStoreWrapper
	return DataStoreWrapper.New(Harness.STORE .. "_C", 30, 0.15, 1.1)
end

function Suite.TxThreeStoreLegs()
	local WrapA, WrapB, WrapC, Store = W(), StoreB(), StoreC(), TxStore()
	local A, B, C = Key("tx3a"), Key("tx3b"), Key("tx3c")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)
	SeedVault(WrapC, C, 0)

	local Committed = Tx.Drive(WrapA, Store, TradeReducer, TINIT, nil, {
		{ Key = A, Kind = "Delta", Fields = { Gold = -30 } },
		{ Key = B, Kind = "Vault", Fields = { Coins = 20 }, Wrapper = WrapB, Reducer = VaultReducer, Initial = VINIT },
		{ Key = C, Kind = "Vault", Fields = { Coins = 10 }, Wrapper = WrapC, Reducer = VaultReducer, Initial = VINIT },
	})
	local Aborted = Tx.Drive(WrapA, Store, TradeReducer, TINIT, nil, {
		{ Key = A, Kind = "Delta", Fields = { Gold = -10 } },
		{ Key = B, Kind = "Vault", Fields = { Coins = 5 }, Wrapper = WrapB, Reducer = VaultReducer, Initial = VINIT },
		{ Key = C, Kind = "Vault", Fields = { Coins = -100 }, Wrapper = WrapC, Reducer = VaultReducer, Initial = VINIT },
	})

	local SA, SB, SC = Fold(WrapA, A), FoldVault(WrapB, B), FoldVault(WrapC, C)

	Expect(Committed).ToBe(true)
	Expect(Aborted).ToBe(false)
	Expect(SA.Gold).ToBe(70)
	Expect(SB.Coins).ToBe(20)
	Expect(SC.Coins).ToBe(10)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
	Expect(Clean(WrapC, C)).ToBe(true)
end

function Suite.TxOrphanLegPastShrunkMarker()
	local WrapA, RealB, Store = W(), StoreB(), TxStore()
	local LyingB = FailOn(RealB, "UpdateAsync", 1, true)
	local A, B = Key("txoa"), Key("txob")
	Seed(WrapA, A, 100, {})
	SeedVault(RealB, B, 0)

	local Committed = Tx.Drive(WrapA, Store, TradeReducer, TINIT, nil, CrossLegs(LyingB, A, B, 25))

	local RecB = Log.Read(RealB, B)
	local Orphaned = Log.HasPending(RecB)
	local Txid = if RecB.Ops[1] then RecB.Ops[1].Tx else nil
	local _, Marker = Store:GetAsync(Txid :: any)

	Tx.Settle(RealB, Store, B, RecB, STALE)
	local SA, SB = Fold(WrapA, A), FoldVault(RealB, B)

	Expect(Committed).ToBe(false)
	Expect(Orphaned).ToBe(true)
	Expect(Marker).ToBeNil()
	Expect(SA.Gold).ToBe(100)
	Expect(SB.Coins).ToBe(0)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(RealB, B)).ToBe(true)
end

function Suite.TxCrossCoordinatorBusy()
	local WrapA, WrapB = W(), StoreB()
	local StoreX = TxStore()
	local StoreY = DataStoreWrapper.New(Harness.STORE .. "_B_Tx", 30, 0.15, 1.1)
	local K, L = Key("txcca"), Key("txccb")
	Seed(WrapA, K, 100, {})
	SeedVault(WrapB, L, 50)

	local Txid = HttpService:GenerateGUID(false)
	StoreX:UpdateAsync(Txid, function()
		return { Status = "Pending", Total = 2, Adopted = 0 }
	end)
	WrapA:UpdateAsync(K, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Txid}:1`, Kind = "Delta", Gold = 5, Tx = Txid, TxHome = StoreX.Name })
		return Record
	end)

	local Legs: { Tx.Leg } = {
		{ Key = L, Kind = "Vault", Fields = { Coins = -10 } },
		{ Key = K, Kind = "Delta", Fields = { Gold = 10 }, Wrapper = WrapA, TxStore = StoreX, Reducer = TradeReducer, Initial = TINIT },
	}
	local Committed = Tx.Drive(WrapB, StoreY, VaultReducer, VINIT, nil, Legs, 120)
	local StillPending = Log.HasPending(Log.Read(WrapA, K))

	Tx.Settle(WrapA, StoreY, K, Log.Read(WrapA, K), STALE)
	local SA, SB = Fold(WrapA, K), FoldVault(WrapB, L)

	Expect(Committed).ToBe(false)
	Expect(StillPending).ToBe(true)
	Expect(SA.Gold).ToBe(100)
	Expect(SB.Coins).ToBe(50)
	Expect(Clean(WrapA, K)).ToBe(true)
	Expect(Clean(WrapB, L)).ToBe(true)
end

return table.freeze(Suite)
