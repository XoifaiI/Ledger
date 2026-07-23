--!strict

local Harness = require("./Harness")
local Log = require("../src/Log")
local Fold = require("../src/Fold")
local MakeOp = require("../src/MakeOp")
local Testing = require("./Testing")

local Expect = Testing.Expect
local W = Harness.Store
local Key = Harness.Key
local Race = Harness.Race
local ChaosAppend = Harness.ChaosAppend
local Reducer = Harness.Reducer
local INIT = Harness.INIT
local RNG = Harness.RNG
local FoldRecord = Harness.FoldRecord

local Suite = {}

function Suite.AppendIntegrity()
	local K = Key("append")
	local Servers, OkIds, Fails = {}, {}, 0

	local Thunks = {}
	for i = 1, 3 do
		Servers[i] = W()
		Thunks[i] = function()
			for j = 1, 3 do
				local Op = MakeOp("Add", { Amount = 1, S = i, J = j })
				if pcall(Log.Append, Servers[i], K, { Op }) then
					OkIds[Op.Id] = true
				else
					Fails += 1
				end
			end
		end
	end
	Race("AppendIntegrity", Thunks)

	local Rec = Log.Read(W(), K)
	local Stored, Dupes = {}, 0
	for _, Op in Rec.Ops do
		if Stored[Op.Id] then Dupes += 1 end
		Stored[Op.Id] = true
	end
	local Lost = 0
	for Id in OkIds do
		if not Stored[Id] then Lost += 1 end
	end

	Expect(Lost).ToBe(0)
	Expect(Dupes).ToBe(0)
end

function Suite.Overdraft()
	local K = Key("overdraft")
	Log.Append(W(), K, { MakeOp("Add", { Amount = 100 }) })

	local Thunks = {}
	for _ = 1, 6 do
		Thunks[#Thunks + 1] = function()
			pcall(Log.Append, W(), K, { MakeOp("Spend", { Amount = 100 }) })
		end
	end
	Race("Overdraft", Thunks)

	local F = FoldRecord(K)
	local Spends = F.N - 1

	Expect(F.Gold).ToBe(0)
	Expect(Spends).ToBe(1)
end

function Suite.Idempotency()
	local K = Key("idem")
	local Op = MakeOp("Add", { Amount = 1 })
	Race("Idempotency", {
		function() pcall(Log.Append, W(), K, { Op }) end,
		function() pcall(Log.Append, W(), K, { Op }) end,
		function() pcall(Log.Append, W(), K, { Op }) end,
	})
	pcall(Log.Append, W(), K, { Op })

	local Rec = Log.Read(W(), K)
	local Count = 0
	for _, O in Rec.Ops do
		if O.Id == Op.Id then Count += 1 end
	end

	Expect(Count).ToBe(1)
end

function Suite.CompactionRace()
	local K = Key("compact")
	local Total = 0
	for Round = 1, 3 do
		local Thunks = { function()
			pcall(function() Log.Compact(W(), K, Reducer, INIT) end)
		end }
		for _ = 1, 3 do
			Thunks[#Thunks + 1] = function()
				if pcall(Log.Append, W(), K, { MakeOp("Add", { Amount = 1 }) }) then
					Total += 1
				end
			end
		end
		Race("CompactionRace r" .. Round, Thunks)
	end
	local F = FoldRecord(K)

	Expect(F.Gold).ToBe(Total)
end

function Suite.Fuzz()
	local Keys = {}
	for i = 1, 8 do Keys[i] = Key("fuzz" .. i) end

	local Success: { [string]: boolean } = {}
	local Attempted = 0
	local Thunks = {}
	for a = 1, 8 do
		Thunks[a] = function()
			local Wrapper = W()
			for _ = 1, 8 do
				local K = Keys[RNG:NextInteger(1, #Keys)]
				local Kind = if RNG:NextNumber() < 0.6 then "Add" else "Spend"
				local Op = MakeOp(Kind, { Amount = RNG:NextInteger(1, 20) })
				Attempted += 1
				if ChaosAppend(Wrapper, K, { Op }) then
					Success[Op.Id] = true
				end
			end
		end
	end
	Race("Fuzz", Thunks)

	local Stored, Dupes, Negatives, NonDeterministic = {}, 0, 0, 0
	local StoredCount = 0
	for _, K in Keys do
		local Rec = Log.Read(W(), K)
		local Seen: { [string]: boolean } = {}
		for _, Op in Rec.Ops do
			if Seen[Op.Id] then Dupes += 1 end
			Seen[Op.Id] = true
			Stored[Op.Id] = true
		end
		StoredCount += #Rec.Ops
		local F1 = Fold(INIT, Rec.Ops, Reducer)
		local F2 = Fold(INIT, Rec.Ops, Reducer)
		if F1.Gold ~= F2.Gold or F1.N ~= F2.N then NonDeterministic += 1 end
		if F1.Gold < 0 then Negatives += 1 end
	end
	local Lost = 0
	for Id in Success do
		if not Stored[Id] then Lost += 1 end
	end

	Expect(Dupes).ToBe(0)
	Expect(Lost).ToBe(0)
	Expect(Negatives).ToBe(0)
	Expect(NonDeterministic).ToBe(0)
end

function Suite.Determinism()
	local K = Key("determ")
	local Wr = W()
	for _ = 1, 12 do
		local Kind = if RNG:NextNumber() < 0.5 then "Add" else "Spend"
		Log.Append(Wr, K, { MakeOp(Kind, { Amount = RNG:NextInteger(1, 30) }) })
	end
	local Rec = Log.Read(W(), K)
	local First = Fold(INIT, Rec.Ops, Reducer)
	local Mismatches = 0
	for _ = 1, 8 do
		local F = Fold(INIT, Log.Read(W(), K).Ops, Reducer)
		if F.Gold ~= First.Gold or F.N ~= First.N then Mismatches += 1 end
	end

	Expect(Mismatches).ToBe(0)
end

function Suite.BurstScale()
	local N = 24
	local Keys = {}
	for i = 1, N do Keys[i] = Key("burst" .. i) end
	local Ok = 0
	local Thunks = {}
	for i = 1, N do
		Thunks[i] = function()
			if pcall(Log.Append, W(), Keys[i], { MakeOp("Add", { Amount = 1 }) }) then Ok += 1 end
		end
	end
	Race("BurstScale", Thunks)
	local Good = 0
	for _, K in Keys do
		if #Log.Read(W(), K).Ops == 1 then Good += 1 end
	end

	Expect(Good).ToBe(N)
end

function Suite.SeenKeepsBatch()
	local K = Key("seen")
	local Batch: { any } = {}
	for i = 1, 2100 do
		table.insert(Batch, { Id = "op:" .. i, Kind = "Noop" })
	end
	Log.Append(W(), K, Batch)
	Log.Compact(W(), K, Reducer, INIT)
	local Rec = Log.Read(W(), K)

	Expect(#Rec.Seen).ToBeGreaterThanOrEqual(2100)
end

function Suite.PrepareRejectsNonTable()
	local K = Key("preptable")
	local function BadReducer(_State: any, _Op: any): any?
		return true
	end
	local Op: any = { Id = "leg1", Kind = "Delta", Tx = "tx1", TxHome = "Home" }
	local Verdict = Log.Prepare(W(), K, Op, BadReducer, INIT)
	local Rec = Log.Read(W(), K)

	Expect(Verdict).ToBe("Rejected")
	Expect(#Rec.Ops).ToBe(0)
end

function Suite.MaterializeDropsJunkSnapshot()
	local K = Key("junksnap")
	W():UpdateAsync(K, function(): any
		return { Snapshot = "corrupted", Ops = {}, Seen = {} }
	end)
	local Rec = Log.Read(W(), K)
	local Folded = FoldRecord(K)

	Expect(Rec.Snapshot).ToBeNil()
	Expect(Folded.Gold).ToBe(0)
	Expect(Folded.N).ToBe(0)
end

function Suite.MaterializeDropsPoisonOps()
	local K = Key("poison")
	W():UpdateAsync(K, function(): any
		return {
			Ops = {
				{ Id = "good", Kind = "Add", Amount = 5 },
				{ Id = "nokind", Amount = 9 },
				{ Id = "numtx", Kind = "Add", Amount = 9, Tx = 7 },
				{ Kind = "Add", Amount = 9 },
			},
			Seen = {},
		}
	end)
	local Rec = Log.Read(W(), K)
	local Kept: { [string]: boolean } = {}
	for _, Op in Rec.Ops do
		Kept[Op.Id] = true
	end

	Expect(#Rec.Ops).ToBe(1)
	Expect(Kept["good"]).ToBe(true)
	Expect(Kept["nokind"]).ToBeNil()
	Expect(Kept["numtx"]).ToBeNil()
end

return table.freeze(Suite)
