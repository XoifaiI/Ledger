--!strict

local HttpService = game:GetService("HttpService")

local DataStoreWrapper = require("../src/Util/DataStoreWrapper")
local Log = require("../src/Log")
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
	return DataStoreWrapper.New("LedgerChaos_v1_Tx", 30, 0.15, 1.1)
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

return table.freeze(Suite)
