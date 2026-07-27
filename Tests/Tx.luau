--!strict

-- tx suite, crash windows, cross store atomicity and the conservation storms

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
	return DataStoreWrapper.New(`{Harness.STORE}_Tx`, 30, 0.15, 1.1)
end

local function Seed(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string, Gold: number, Items: { [string]: true })
	Wrapper:UpdateAsync(K, function()
		return { Snapshot = { Gold = Gold, Items = Items }, Ops = {} }
	end)
end

local function Fold(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string): any
	return Log.Shape(TradeReducer, TINIT):Fold(Log.New(Wrapper):Read(K))
end

local function Clean(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string): boolean
	return not Log.HasPending(Log.New(Wrapper):Read(K))
end

local function Fresh(): string
	return `auto{Harness.Uid()}`
end

local function Bind(Legs: { any }, Wrapper: any, Store: any, Reducer: any, Initial: any): { any }
	local Records, Format = Log.New(Wrapper), Log.Shape(Reducer, Initial)
	for _, Leg in Legs do
		Leg.Log = Leg.Log or (if Leg.Wrapper then Log.New(Leg.Wrapper :: any) else Records)
		Leg.Shape = Leg.Shape or (if Leg.Wrapper then Log.Shape(Leg.Reducer, Leg.Initial) else Format)
		Leg.TxStore = Leg.TxStore or Store
		Leg.Wrapper, Leg.Reducer, Leg.Initial = nil, nil, nil
	end
	return Legs
end

local function SwapLegs(A: string, B: string, Price: number): { any }
	return {
		{ Key = A, Kind = "Delta", Fields = { Gold = Price, Drop = "Sword" } },
		{ Key = B, Kind = "Delta", Fields = { Gold = -Price, Gain = "Sword" } }
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

	local Committed = Tx.Drive(Store, Bind(SwapLegs(A, B, 25), Wrapper, Store, TradeReducer, TINIT), Fresh())
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

	local Committed, Why = Tx.Drive(Store, Bind(SwapLegs(A, B, 25), Wrapper, Store, TradeReducer, TINIT), Fresh())
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Committed).ToBe(false)
	Expect(Why).ToBe("Refused")
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

	Tx.Settle(Log.New(Wrapper), Store, A, Log.New(Wrapper):Read(A), STALE)
	Tx.Settle(Log.New(Wrapper), Store, B, Log.New(Wrapper):Read(B), STALE)

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

	Tx.Settle(Log.New(Wrapper), Store, A, Log.New(Wrapper):Read(A), STALE)
	Tx.Settle(Log.New(Wrapper), Store, B, Log.New(Wrapper):Read(B), STALE)

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

	local Committed, Why = Tx.Drive(Store, Bind(SwapLegs(A, B, 10), Wrapper, Store, TradeReducer, TINIT), Fresh(), 120)

	Tx.Settle(Log.New(Wrapper), Store, A, Log.New(Wrapper):Read(A), STALE)
	Tx.Settle(Log.New(Wrapper), Store, B, Log.New(Wrapper):Read(B), STALE)
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Committed).ToBe(false)
	Expect(Why).ToBe("Busy")
	Expect(SA.Gold).ToBe(100)
	Expect(SB.Gold).ToBe(100)
end

function Suite.TxAbortedLegReprepareStillAborts()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txza"), Key("txzb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	local Txid = CraftPending(Wrapper, Store, A, B, "Pending")

	Tx.Settle(Log.New(Wrapper), Store, A, Log.New(Wrapper):Read(A), STALE)
	Tx.Settle(Log.New(Wrapper), Store, B, Log.New(Wrapper):Read(B), STALE)

	local Verdict = Log.New(Wrapper):Prepare(A, { Id = `tx:{Txid}:1`, Kind = "Delta", Gold = 25, Drop = "Sword", Tx = Txid } :: any, Log.Shape(TradeReducer, TINIT))
	Tx.Settle(Log.New(Wrapper), Store, A, Log.New(Wrapper):Read(A), STALE)

	local SA = Fold(Wrapper, A)

	Expect(Verdict).ToBe("Prepared")
	Expect(SA.Gold).ToBe(100)
	Expect(SA.Items.Sword).ToBe(true)
	Expect(Clean(Wrapper, A)).ToBe(true)
end

function Suite.TxNamedRetryAfterBusySucceeds()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txbra"), Key("txbrb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	local Id = `order{Harness.Uid()}`

	local Blocker = HttpService:GenerateGUID(false)
	Store:UpdateAsync(Blocker, function()
		return { Status = "Pending", Total = 1, Adopted = 0 }
	end)
	Wrapper:UpdateAsync(B, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Blocker}:1`, Kind = "Delta", Gold = 0, Tx = Blocker })
		return Record
	end)

	local Blocked, Why = Tx.Drive(Store, Bind(SwapLegs(A, B, 25), Wrapper, Store, TradeReducer, TINIT), Id, 120)

	Tx.Settle(Log.New(Wrapper), Store, B, Log.New(Wrapper):Read(B), STALE)

	local Retried = Tx.Drive(Store, Bind(SwapLegs(A, B, 25), Wrapper, Store, TradeReducer, TINIT), Id)
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Blocked).ToBe(false)
	Expect(Why).ToBe("Busy")
	Expect(Retried).ToBe(true)
	Expect(SA.Gold).ToBe(125)
	Expect(SA.Items.Sword).ToBeNil()
	Expect(SB.Gold).ToBe(75)
	Expect(SB.Items.Sword).ToBe(true)
	Expect(Clean(Wrapper, A)).ToBe(true)
	Expect(Clean(Wrapper, B)).ToBe(true)
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
		end
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

				pcall(function() Tx.Drive(ChaosT, Bind(SwapLegs(Holder, Other, Price), ChaosW, ChaosT, TradeReducer, TINIT), Fresh(), Timeout) end)
				Done += 1
			end)
		end

		pcall(function()
			Log.New(ChaosW):Append(if RNG:NextNumber() < 0.5 then A else B, { { Id = HttpService:GenerateGUID(false), Kind = "Delta", Gold = 0 } :: any })
		end)

		local Deadline = os.clock() + 30
		while Done < Jobs and os.clock() < Deadline do
			task.wait(0.1)
		end
	end

	for _ = 1, 3 do
		Tx.Settle(Log.New(Real), Store, A, Log.New(Real):Read(A), STALE)
		Tx.Settle(Log.New(Real), Store, B, Log.New(Real):Read(B), STALE)
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
	return DataStoreWrapper.New(`{Harness.STORE}_B`, 30, 0.15, 1.1)
end

local function SeedVault(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string, Coins: number)
	Wrapper:UpdateAsync(K, function()
		return { Snapshot = { Coins = Coins }, Ops = {} }
	end)
end

local function FoldVault(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string): any
	return Log.Shape(VaultReducer, VINIT):Fold(Log.New(Wrapper):Read(K))
end

local function CrossLegs(WrapB: any, A: string, B: string, Amount: number): { any }
	return {
		{ Key = A, Kind = "Delta", Fields = { Gold = -Amount } },
		{ Key = B, Kind = "Vault", Fields = { Coins = Amount }, Wrapper = WrapB, Reducer = VaultReducer, Initial = VINIT }
	}
end

function Suite.TxCrossStoreCommits()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local A, B = Key("txxa"), Key("txxb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)

	local Committed = Tx.Drive(Store, Bind(CrossLegs(WrapB, A, B, 25), WrapA, Store, TradeReducer, TINIT), Fresh())
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

	local Legs: { any } = {
		{ Key = A, Kind = "Delta", Fields = { Gold = 25 } },
		{ Key = B, Kind = "Vault", Fields = { Coins = -25 }, Wrapper = WrapB, Reducer = VaultReducer, Initial = VINIT }
	}
	local Committed, Why = Tx.Drive(Store, Bind(Legs, WrapA, Store, TradeReducer, TINIT), Fresh())
	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)

	Expect(Committed).ToBe(false)
	Expect(Why).ToBe("Refused")
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

	local Committed, Why = Tx.Drive(Store, Bind(CrossLegs(DeadB, A, B, 25), WrapA, Store, TradeReducer, TINIT), Fresh())
	local SA = Fold(WrapA, A)

	Expect(Committed).ToBe(false)
	Expect(Why).ToBe("Unresolved")
	Expect(SA.Gold).ToBe(100)
	Expect(Clean(WrapA, A)).ToBe(true)
end

function Suite.TxCrossStoreMarkerDown()
	local WrapA, WrapB = W(), StoreB()
	local DeadMarker = Faulty(TxStore(), Random.new(2), 1, 0)
	local A, B = Key("txma"), Key("txmb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)

	local Committed, Why = Tx.Drive(DeadMarker, Bind(CrossLegs(WrapB, A, B, 25), WrapA, DeadMarker, TradeReducer, TINIT), Fresh())
	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)
	local RecA, RecB = Log.New(WrapA):Read(A), Log.New(WrapB):Read(B)

	Expect(Committed).ToBe(false)
	Expect(Why).ToBe("Unresolved")
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

	local ForeignTx = DataStoreWrapper.New(`{Harness.STORE}_B_Tx`, 30, 0.15, 1.1)
	Tx.Settle(Log.New(WrapB), ForeignTx, B, Log.New(WrapB):Read(B), STALE)
	Tx.Settle(Log.New(WrapA), Store, A, Log.New(WrapA):Read(A), STALE)

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
				local Legs: { any } = {
					{ Key = A, Kind = "Delta", Fields = { Gold = -Amount * Sign } },
					{
						Key = B,
						Kind = "Vault",
						Fields = { Coins = Amount * Sign },
						Wrapper = ChaosB,
						Reducer = VaultReducer,
						Initial = VINIT
					}
				}
				pcall(function() Tx.Drive(ChaosT, Bind(Legs, ChaosA, ChaosT, TradeReducer, TINIT), Fresh(), Timeout) end)
				Done += 1
			end)
		end

		local Deadline = os.clock() + 30
		while Done < Jobs and os.clock() < Deadline do
			task.wait(0.1)
		end
	end

	for _ = 1, 3 do
		Tx.Settle(Log.New(RealA), Store, A, Log.New(RealA):Read(A), STALE)
		Tx.Settle(Log.New(RealB), Store, B, Log.New(RealB):Read(B), STALE)
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
		end
	})
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
						return false, "chaos: injected marker failure"
					end
				end
				return Call(Inner, ...)
			end
		end
	})
end

function Suite.TxDecideLostAckCommits()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local Lying = FailOn(Store, "UpdateAsync", 2, true)
	local A, B = Key("txla"), Key("txlb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)

	local Committed, Why = Tx.Drive(Lying, Bind(CrossLegs(WrapB, A, B, 25), WrapA, Lying, TradeReducer, TINIT), Fresh())
	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)

	Expect(Committed).ToBe(true)
	Expect(Why).ToBeNil()
	Expect(SA.Gold).ToBe(75)
	Expect(SB.Coins).ToBe(25)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
end

function Suite.TxDecideDownAbortsByTimeout()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local Dead = FailFrom(Store, "UpdateAsync", 2)
	local A, B = Key("txna"), Key("txnb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)

	local Committed, Why = Tx.Drive(Dead, Bind(CrossLegs(WrapB, A, B, 25), WrapA, Dead, TradeReducer, TINIT), Fresh())
	local PendingA = Log.HasPending(Log.New(WrapA):Read(A))
	local PendingB = Log.HasPending(Log.New(WrapB):Read(B))
	Expect(Why).ToBe("Unresolved")

	Tx.Settle(Log.New(WrapA), Store, A, Log.New(WrapA):Read(A), STALE)
	Tx.Settle(Log.New(WrapB), Store, B, Log.New(WrapB):Read(B), STALE)
	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)

	Expect(Committed).ToBe(false)
	Expect(PendingA).ToBe(true)
	Expect(PendingB).ToBe(true)
	Expect(SA.Gold).ToBe(100)
	Expect(SB.Coins).ToBe(0)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
end

function Suite.TxAdoptSurvivesALostAcknowledgement()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txada"), Key("txadb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	local Txid = CraftPending(Wrapper, Store, A, B, "Committed")

	local Lying = FailOn(Store, "UpdateAsync", 1, true)
	Tx.Settle(Log.New(Wrapper), Lying, A, Log.New(Wrapper):Read(A), STALE)

	local _, Marker = Store:GetAsync(Txid)

	Tx.Settle(Log.New(Wrapper), Store, B, Log.New(Wrapper):Read(B), STALE)
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Marker).Never.ToBeNil()
	Expect(SA.Gold).ToBe(125)
	Expect(SB.Gold).ToBe(75)
	Expect(SB.Items.Sword).ToBe(true)
	Expect(Clean(Wrapper, A)).ToBe(true)
	Expect(Clean(Wrapper, B)).ToBe(true)
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

	local LocalTx = DataStoreWrapper.New(`{Harness.STORE}_B_Tx`, 30, 0.15, 1.1)
	local Active = Session.Load(Log.New(Wrapper), Log.Shape(Harness.Reducer, Harness.INIT, nil), K, LocalTx):Wait()
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
	return DataStoreWrapper.New(`{Harness.STORE}_C`, 30, 0.15, 1.1)
end

function Suite.TxThreeStoreLegs()
	local WrapA, WrapB, WrapC, Store = W(), StoreB(), StoreC(), TxStore()
	local A, B, C = Key("tx3a"), Key("tx3b"), Key("tx3c")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)
	SeedVault(WrapC, C, 0)

	local Committed = Tx.Drive(Store, Bind({
		{ Key = A, Kind = "Delta", Fields = { Gold = -30 } },
		{ Key = B, Kind = "Vault", Fields = { Coins = 20 }, Wrapper = WrapB, Reducer = VaultReducer, Initial = VINIT },
		{ Key = C, Kind = "Vault", Fields = { Coins = 10 }, Wrapper = WrapC, Reducer = VaultReducer, Initial = VINIT }
	}, WrapA, Store, TradeReducer, TINIT), Fresh())
	local Aborted = Tx.Drive(Store, Bind({
		{ Key = A, Kind = "Delta", Fields = { Gold = -10 } },
		{ Key = B, Kind = "Vault", Fields = { Coins = 5 }, Wrapper = WrapB, Reducer = VaultReducer, Initial = VINIT },
		{ Key = C, Kind = "Vault", Fields = { Coins = -100 }, Wrapper = WrapC, Reducer = VaultReducer, Initial = VINIT }
	}, WrapA, Store, TradeReducer, TINIT), Fresh())

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

	local Committed = Tx.Drive(Store, Bind(CrossLegs(LyingB, A, B, 25), WrapA, Store, TradeReducer, TINIT), Fresh())

	local RecB = Log.New(RealB):Read(B)
	local Orphaned = Log.HasPending(RecB)
	local Txid = if RecB.Ops[1] then RecB.Ops[1].Tx else nil
	local _, Marker = Store:GetAsync(Txid :: any)

	Tx.Settle(Log.New(RealB), Store, B, RecB, STALE)
	local SA, SB = Fold(WrapA, A), FoldVault(RealB, B)

	Expect(Committed).ToBe(false)
	Expect(Orphaned).ToBe(true)
	Expect(Marker).ToBeNil()
	Expect(SA.Gold).ToBe(100)
	Expect(SB.Coins).ToBe(0)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(RealB, B)).ToBe(true)
end

function Suite.TxRetrySameIdAfterCommitIsNoop()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local A, B = Key("txida"), Key("txidb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)
	local Id = `order{Harness.Uid()}`

	local First = Tx.Drive(Store, Bind(CrossLegs(WrapB, A, B, 25), WrapA, Store, TradeReducer, TINIT), Id)
	local Second = Tx.Drive(Store, Bind(CrossLegs(WrapB, A, B, 25), WrapA, Store, TradeReducer, TINIT), Id)
	local Third = Tx.Drive(Store, Bind(CrossLegs(WrapB, A, B, 25), WrapA, Store, TradeReducer, TINIT), Id)

	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)

	local _, Husk = Store:GetAsync(Id)

	Expect(First).ToBe(true)
	Expect(Second).ToBe(true)
	Expect(Third).ToBe(true)
	Expect(Husk).ToBeNil()
	Expect(SA.Gold).ToBe(75)
	Expect(SB.Coins).ToBe(25)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
end

local StickyTrade = Tx.Wrap(TradeReducer)
local StickyVault = Tx.Wrap(VaultReducer)

local function StickyFold(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string): any
	return Log.Shape(StickyTrade, TINIT):Fold(Log.New(Wrapper):Read(K))
end

local function StickyFoldVault(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string): any
	return Log.Shape(StickyVault, VINIT):Fold(Log.New(Wrapper):Read(K))
end

local function ForgetLegIds(Wrapper: DataStoreWrapper.DataStoreWrapper, K: string, Reducer: any, Initial: any, Prefix: string)
	Log.New(Wrapper):Compact(K, Log.Shape(Reducer, Initial))
	Wrapper:UpdateAsync(K, function(Current: any): any
		if type(Current) ~= "table" or type(Current.Seen) ~= "table" then
			return Current
		end

		local Kept = {}
		for _, Id in Current.Seen :: { string } do
			if string.sub(Id, 1, #Prefix) ~= Prefix then
				table.insert(Kept, Id)
			end
		end

		Current.Seen = Kept
		return Current
	end)
end

function Suite.TxRetryAfterLegIdsForgottenIsNoop()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local A, B = Key("txapa"), Key("txapb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)
	local Id = `order{Harness.Uid()}`

	local Legs: { any } = {
		{ Key = A, Kind = "Delta", Fields = { Gold = -25 } },
		{ Key = B, Kind = "Vault", Fields = { Coins = 25 }, Wrapper = WrapB, Reducer = StickyVault, Initial = VINIT }
	}

	local First = Tx.Drive(Store, Bind(Legs, WrapA, Store, StickyTrade, TINIT), Id)
	local Marked = StickyFold(WrapA, A)

	Log.New(WrapA):Append(A, { { Id = `plain:{Id}`, Kind = "Delta", Gold = 0 } :: any })
	local AfterPlain = StickyFold(WrapA, A)

	local Prefix = `tx:{Id}:`
	ForgetLegIds(WrapA, A, StickyTrade, TINIT, Prefix)
	ForgetLegIds(WrapB, B, StickyVault, VINIT, Prefix)

	local Retried = Tx.Drive(Store, Bind(Legs, WrapA, Store, StickyTrade, TINIT), Id)
	local SA, SB = StickyFold(WrapA, A), StickyFoldVault(WrapB, B)

	Expect(First).ToBe(true)
	Expect(Marked._Received[`x:{Id}`]).Never.ToBeNil()
	Expect(AfterPlain._Received[`x:{Id}`]).Never.ToBeNil()
	Expect(Marked._Received[`t:{Id}`]).ToBeNil()
	Expect(Retried).ToBe(true)
	Expect(SA.Gold).ToBe(75)
	Expect(SB.Coins).ToBe(25)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
end

function Suite.TxHuskHealsWithinOneCall()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txhka"), Key("txhkb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	local Id = `order{Harness.Uid()}`

	Store:UpdateAsync(Id, function()
		return { Status = "Aborted", Total = 2, Adopted = 0 }
	end)

	local Committed, Why = Tx.Drive(Store, Bind(SwapLegs(A, B, 25), Wrapper, Store, TradeReducer, TINIT), Id)
	local _, Husk = Store:GetAsync(Id)
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Committed).ToBe(true)
	Expect(Why).ToBeNil()
	Expect(Husk).ToBeNil()
	Expect(SA.Gold).ToBe(125)
	Expect(SB.Gold).ToBe(75)
	Expect(Clean(Wrapper, A)).ToBe(true)
	Expect(Clean(Wrapper, B)).ToBe(true)
end

function Suite.TxZeroTotalHuskAlsoHeals()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txhna"), Key("txhnb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	local Id = `order{Harness.Uid()}`

	Store:UpdateAsync(Id, function()
		return { Status = "Aborted", Total = 0, Adopted = 0 }
	end)

	local Committed = Tx.Drive(Store, Bind(SwapLegs(A, B, 25), Wrapper, Store, TradeReducer, TINIT), Id)
	local _, Husk = Store:GetAsync(Id)
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Committed).ToBe(true)
	Expect(Husk).ToBeNil()
	Expect(SA.Gold).ToBe(125)
	Expect(SB.Gold).ToBe(75)
	Expect(Clean(Wrapper, A)).ToBe(true)
	Expect(Clean(Wrapper, B)).ToBe(true)
end

function Suite.TxRetryAfterCompactionIsNoop()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local A, B = Key("txcma"), Key("txcmb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)
	local Id = `order{Harness.Uid()}`

	local Legs: { any } = {
		{ Key = A, Kind = "Delta", Fields = { Gold = -25 } },
		{ Key = B, Kind = "Vault", Fields = { Coins = 25 }, Wrapper = WrapB, Reducer = StickyVault, Initial = VINIT }
	}

	local First = Tx.Drive(Store, Bind(Legs, WrapA, Store, StickyTrade, TINIT), Id)

	Log.New(WrapA):Compact(A, Log.Shape(StickyTrade, TINIT))
	Log.New(WrapB):Compact(B, Log.Shape(StickyVault, VINIT))

	local InSeen = false
	for _, Entry in Log.New(WrapA):Read(A).Seen do
		if Entry == `tx:{Id}:1` then
			InSeen = true
		end
	end

	local Retried = Tx.Drive(Store, Bind(Legs, WrapA, Store, StickyTrade, TINIT), Id)
	local SA, SB = StickyFold(WrapA, A), StickyFoldVault(WrapB, B)

	Expect(First).ToBe(true)
	Expect(InSeen).ToBe(true)
	Expect(Retried).ToBe(true)
	Expect(SA.Gold).ToBe(75)
	Expect(SB.Coins).ToBe(25)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
end

function Suite.TxRetryWithPartialMemoryAborts()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local A, B = Key("txpma"), Key("txpmb")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)
	local Id = `order{Harness.Uid()}`

	local Legs: { any } = {
		{ Key = A, Kind = "Delta", Fields = { Gold = -25 } },
		{ Key = B, Kind = "Vault", Fields = { Coins = 25 }, Wrapper = WrapB, Reducer = StickyVault, Initial = VINIT }
	}

	local First = Tx.Drive(Store, Bind(Legs, WrapA, Store, StickyTrade, TINIT), Id)

	local Prefix = `tx:{Id}:`
	ForgetLegIds(WrapA, A, StickyTrade, TINIT, Prefix)
	ForgetLegIds(WrapB, B, StickyVault, VINIT, Prefix)

	WrapA:UpdateAsync(A, function(Current: any): any
		local Snapshot: any = if type(Current) == "table" then Current.Snapshot else nil
		if Snapshot ~= nil then
			Snapshot._Received = nil
		end
		return Current
	end)

	local Retried, Why = Tx.Drive(Store, Bind(Legs, WrapA, Store, StickyTrade, TINIT), Id)
	local SA, SB = StickyFold(WrapA, A), StickyFoldVault(WrapB, B)

	Expect(First).ToBe(true)
	Expect(Retried).ToBe(false)
	Expect(Why).ToBe("Spent")
	Expect(SA.Gold).ToBe(75)
	Expect(SB.Coins).ToBe(25)
	Expect(Clean(WrapA, A)).ToBe(true)
	Expect(Clean(WrapB, B)).ToBe(true)
end

function Suite.TxNameReusedForOtherKeysIsRefused()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txfpa"), Key("txfpb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	local Id = `order{Harness.Uid()}`

	Store:UpdateAsync(Id, function()
		return { Status = "Pending", Total = 2, Adopted = 0, Keys = "another\0set\1of\0keys" }
	end)

	local Committed, Why = Tx.Drive(Store, Bind(SwapLegs(A, B, 25), Wrapper, Store, TradeReducer, TINIT), Id)
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Committed).ToBe(false)
	Expect(Why).ToBe("Spent")
	Expect(SA.Gold).ToBe(100)
	Expect(SB.Gold).ToBe(100)
	Expect(Clean(Wrapper, A)).ToBe(true)
	Expect(Clean(Wrapper, B)).ToBe(true)
end

function Suite.TxAbortLosesToCommittedMarker()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txova"), Key("txovb")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	local Id = `order{Harness.Uid()}`

	Store:UpdateAsync(Id, function()
		return { Status = "Committed", Total = 2, Adopted = 0 }
	end)
	Wrapper:UpdateAsync(A, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Id}:1`, Kind = "Delta", Gold = 25, Drop = "Sword" })
		return Record
	end)

	local Committed, Why = Tx.Drive(Store, Bind(SwapLegs(A, B, 25), Wrapper, Store, TradeReducer, TINIT), Id)
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Committed).ToBe(true)
	Expect(Why).ToBeNil()
	Expect(SA.Gold).ToBe(125)
	Expect(SB.Gold).ToBe(75)
	Expect(SB.Items.Sword).ToBe(true)
	Expect(Clean(Wrapper, A)).ToBe(true)
	Expect(Clean(Wrapper, B)).ToBe(true)
end

function Suite.TxMarkerWithoutFingerprintStillRuns()
	local Wrapper, Store = W(), TxStore()
	local A, B = Key("txfoa"), Key("txfob")
	Seed(Wrapper, A, 100, { Sword = true })
	Seed(Wrapper, B, 100, {})
	local Id = `order{Harness.Uid()}`

	Store:UpdateAsync(Id, function()
		return { Status = "Pending", Total = 2, Adopted = 0 }
	end)

	local Committed = Tx.Drive(Store, Bind(SwapLegs(A, B, 25), Wrapper, Store, TradeReducer, TINIT), Id)
	local SA, SB = Fold(Wrapper, A), Fold(Wrapper, B)

	Expect(Committed).ToBe(true)
	Expect(SA.Gold).ToBe(125)
	Expect(SB.Gold).ToBe(75)
	Expect(Clean(Wrapper, A)).ToBe(true)
	Expect(Clean(Wrapper, B)).ToBe(true)
end

function Suite.TxStickyFieldsRefusedOnGameOps()
	local Sticky, StickyReason = IsStorable.Op({ Id = "x", Kind = "Delta", TxSticky = "hax" })
	local Stamped, StampedReason = IsStorable.Op({ Id = "y", Kind = "Delta", TxAt = 1 })

	Expect(Sticky).ToBe(false)
	Expect((string.find(StickyReason :: string, "reserved", 1, true))).Never.ToBeNil()
	Expect(Stamped).ToBe(false)
	Expect((string.find(StampedReason :: string, "reserved", 1, true))).Never.ToBeNil()
end

function Suite.TxRetrySameIdAfterLostAckMovesOnce()
	local WrapA, WrapB, Store = W(), StoreB(), TxStore()
	local Lying = FailOn(Store, "UpdateAsync", 2, true)
	local A, B = Key("txlaa"), Key("txlab")
	Seed(WrapA, A, 100, {})
	SeedVault(WrapB, B, 0)
	local Id = `order{Harness.Uid()}`

	local First = Tx.Drive(Lying, Bind(CrossLegs(WrapB, A, B, 25), WrapA, Lying, TradeReducer, TINIT), Id)

	Tx.Settle(Log.New(WrapA), Store, A, Log.New(WrapA):Read(A), STALE)
	Tx.Settle(Log.New(WrapB), Store, B, Log.New(WrapB):Read(B), STALE)

	local Second = Tx.Drive(Store, Bind(CrossLegs(WrapB, A, B, 25), WrapA, Store, TradeReducer, TINIT), Id)
	local SA, SB = Fold(WrapA, A), FoldVault(WrapB, B)

	Expect(First).ToBe(true)
	Expect(Second).ToBe(true)
	Expect(SA.Gold).ToBe(75)
	Expect(SB.Coins).ToBe(25)
end

function Suite.TxLoadSurvivesSettleFailure()
	local Wrapper, Store = W(), TxStore()
	local K = Key("txsf")
	local Txid = HttpService:GenerateGUID(false)

	Store:UpdateAsync(Txid, function()
		return { Status = "Committed", Total = 1, Adopted = 0 }
	end)
	Wrapper:UpdateAsync(K, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Txid}:1`, Kind = "Add", Amount = 25, Tx = Txid, TxHome = Store.Name })
		return Record
	end)

	local Failing = FailOn(Wrapper, "UpdateAsync", 1, false)
	local Loaded = Session.Load(Log.New(Failing), Log.Shape(Harness.Reducer, Harness.INIT, nil), K, Store)
	local Active = Loaded:Wait()

	Expect(Loaded:Happened()).ToBe(true)
	Expect(Active).Never.ToBeNil()
	Expect((Active :: any):Get().Gold).ToBe(0)
	Expect(Log.HasPending(Log.New(Wrapper):Read(K))).ToBe(true)
end

function Suite.TxCrossCoordinatorBusy()
	local WrapA, WrapB = W(), StoreB()
	local StoreX = TxStore()
	local StoreY = DataStoreWrapper.New(`{Harness.STORE}_B_Tx`, 30, 0.15, 1.1)
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

	local Legs: { any } = {
		{ Key = L, Kind = "Vault", Fields = { Coins = -10 } },
		{ Key = K, Kind = "Delta", Fields = { Gold = 10 }, Wrapper = WrapA, TxStore = StoreX, Reducer = TradeReducer, Initial = TINIT }
	}
	local Committed, Why = Tx.Drive(StoreY, Bind(Legs, WrapB, StoreY, VaultReducer, VINIT), Fresh(), 120)
	local StillPending = Log.HasPending(Log.New(WrapA):Read(K))

	Tx.Settle(Log.New(WrapA), StoreY, K, Log.New(WrapA):Read(K), STALE)
	local SA, SB = Fold(WrapA, K), FoldVault(WrapB, L)

	Expect(Committed).ToBe(false)
	Expect(Why).ToBe("Busy")
	Expect(StillPending).ToBe(true)
	Expect(SA.Gold).ToBe(100)
	Expect(SB.Coins).ToBe(50)
	Expect(Clean(WrapA, K)).ToBe(true)
	Expect(Clean(WrapB, L)).ToBe(true)
end

return table.freeze(Suite)
