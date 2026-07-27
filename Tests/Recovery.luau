--!strict

-- recovery suite, version history, resets and erasure

local TableUtil = require("../src/Util/TableUtil")
local Harness = require("./Harness")
local Log = require("../src/Log")
local MakeOp = require("../src/MakeOp")
local Session = require("../src/Session")
local Testing = require("./Testing")

local Expect = Testing.Expect
local W = Harness.Store
local Key = Harness.Key

local Suite = {}

local function AddReducer(State: any, Op: any): any?
	if Op.Kind ~= "Add" then
		return nil
	end
	local Next = table.clone(State)
	Next.Gold = (Next.Gold or 0) + Op.Amount
	return Next
end

function Suite.RecoveryHistory()
	local K = Key("rechist")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 1 }) })
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 2 }) })

	local Ok, Pages = W():ListVersionsAsync(K, Enum.SortDirection.Descending, nil, nil, 10)
	local Count = 0
	local Newest: DataStoreObjectVersionInfo? = nil
	if Ok then
		for _, Info in (Pages :: DataStoreVersionPages):GetCurrentPage() do
			Count += 1
			Newest = Newest or (Info :: DataStoreObjectVersionInfo)
		end
	end

	Expect(Ok).ToBe(true)
	Expect(Count).ToBeGreaterThanOrEqual(1)
	Expect(Newest).Never.ToBeNil()
	Expect(type((Newest :: DataStoreObjectVersionInfo).Version)).ToBe("string")
	Expect((Newest :: DataStoreObjectVersionInfo).CreatedTime).ToBeGreaterThan(0)
end

function Suite.RecoveryPeekVersion()
	local K = Key("recpeek")
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 1 }) })
	Log.New(W()):Append(K, { MakeOp("Add", { Amount = 2 }) })

	local Ok, Pages = W():ListVersionsAsync(K, Enum.SortDirection.Descending, nil, nil, 10)
	Expect(Ok).ToBe(true)

	local Newest = (Pages :: DataStoreVersionPages):GetCurrentPage()[1] :: DataStoreObjectVersionInfo
	local Versioned = Log.Shape(AddReducer, { Gold = 0 }):Fold(Log.New(W()):ReadVersion(K, Newest.Version))
	local Current = Log.Shape(AddReducer, { Gold = 0 }):Fold(Log.New(W()):Read(K))

	Expect(Current.Gold).ToBe(3)
	Expect(Versioned.Gold).ToBe(Current.Gold)
end

function Suite.RecoveryEnvelopeRefused()
	local K = Key("recenv")
	W():UpdateAsync(K, function()
		return { Envelope = 2, Snapshot = { Gold = 1 }, Ops = {} }
	end)

	local Loaded = Session.Load(Log.New(W()), Log.Shape(AddReducer, { Gold = 0 }), K)
	local Active = Loaded:Wait()

	Expect(function()
		Log.New(W()):Read(K)
	end).ToThrow()
	Expect(Loaded:Happened()).ToBe(false)
	Expect(Active).ToBeNil()
end

function Suite.RecoveryFrozenState()
	local K = Key("recfroze")
	W():UpdateAsync(K, function()
		return { Snapshot = { Gold = 5, Bag = { Swords = 1 } }, Ops = {} }
	end)

	local Active = Session.Load(Log.New(W()), Log.Shape(AddReducer, { Gold = 0, Bag = {} }), K):Wait()
	local State = Active:Get() :: any

	Expect(function()
		State.Gold = 999
	end).ToThrow()
	Expect(function()
		State.Bag.Swords = 999
	end).ToThrow()

	local Applied = Active:Apply("Add", { Amount = 1 })

	Expect(Applied).ToBe(true)
	Expect((Active:Get() :: any).Gold).ToBe(6)
	Expect(function()
		TableUtil.DeepFreeze(TableUtil.DeepFreeze({ Inner = { 1 } }))
	end).Never.ToThrow()
end

return table.freeze(Suite)
