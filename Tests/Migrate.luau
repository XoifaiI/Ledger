--!strict

-- migrate suite, version chaining, floors and compatible steps

local Harness = require("./Harness")
local Log = require("../src/Log")
local Session = require("../src/Session")
local Types = require("../src/Types")
local DataStoreWrapper = require("../src/Util/DataStoreWrapper")
local Testing = require("./Testing")

local Ledger: any = require("../src")

local Expect = Testing.Expect
local W = Harness.Store
local Key = Harness.Key

local Suite = {}

local function Keep(State: any): any?
	return State
end

local RENAME: { Types.Migration } = {
	function(State: any): any
		State.Gold = State.Coins
		State.Coins = nil
		return State
	end
}

local CHAIN: { Types.Migration } = {
	RENAME[1],
	{
		Compatible = true,
		Apply = function(State: any): any
			State.Gold *= 10
			return State
		end
	}
}

function Suite.MigrateOnLoad()
	local K = Key("migrate")
	W():UpdateAsync(K, function()
		return { Snapshot = { Coins = 55 }, Ops = {} }
	end)

	local Active = Session.Load(Log.New(W()), Log.Shape(Keep, { Gold = 0 }, RENAME), K):Wait()
	local State = Active:Get()

	Expect(State.Gold).ToBe(55)
	Expect(State.Coins).ToBeNil()
end

function Suite.MigrateChainsFromStoredVersion()
	local K = Key("migratechain")
	W():UpdateAsync(K, function()
		return { Snapshot = { Gold = 7 }, Ops = {}, Version = 1 }
	end)

	local Active = Session.Load(Log.New(W()), Log.Shape(Keep, { Gold = 0 }, CHAIN), K):Wait()
	local State = Active:Get()

	Expect(State.Gold).ToBe(70)
end

function Suite.MigrateStampsOnCompact()
	local K = Key("migratestamp")
	W():UpdateAsync(K, function()
		return { Snapshot = { Coins = 5 }, Ops = {} }
	end)

	Log.New(W()):Compact(K, Log.Shape(Keep, { Gold = 0 }, RENAME))
	local Record = Log.New(W()):Read(K)
	local Again = Log.Shape(Keep, { Gold = 0 }, RENAME):Rehydrate(Record) :: any

	Expect(Record.Version).ToBe(1)
	Expect(Record.Floor).ToBe(1)
	Expect((Record.Snapshot :: any).Gold).ToBe(5)
	Expect((Record.Snapshot :: any).Coins).ToBeNil()
	Expect(Again.Gold).ToBe(5)
end

function Suite.MigrateCompatibleFutureLoads()
	local K = Key("migratecompat")
	W():UpdateAsync(K, function()
		return { Snapshot = { Gold = 5 }, Ops = {}, Version = 2, Floor = 1 }
	end)

	local Active = Session.Load(Log.New(W()), Log.Shape(Keep, { Gold = 0 }, RENAME), K):Wait()
	local State = Active:Get()

	Expect(State.Gold).ToBe(5)
	Expect(State.Coins).ToBeNil()
end

function Suite.MigrateCompactPreservesFuture()
	local K = Key("migkeep")
	W():UpdateAsync(K, function()
		return { Snapshot = { Gold = 5 }, Ops = {}, Version = 2, Floor = 1 }
	end)

	Log.New(W()):Compact(K, Log.Shape(Keep, { Gold = 0 }, RENAME))
	local Record = Log.New(W()):Read(K)

	Expect(Record.Version).ToBe(2)
	Expect(Record.Floor).ToBe(1)
	Expect((Record.Snapshot :: any).Gold).ToBe(5)
end

function Suite.MigrateRefusesFuture()
	local K = Key("migratefuture")
	W():UpdateAsync(K, function()
		return { Snapshot = { Gold = 1 }, Ops = {}, Version = 5 }
	end)

	local Loaded = Session.Load(Log.New(W()), Log.Shape(Keep, { Gold = 0 }, RENAME), K)
	local Active = Loaded:Wait()

	local Record = Log.New(W()):Read(K)

	Expect(Loaded:Happened()).ToBe(false)
	Expect(Active).ToBeNil()
	Expect(function()
		Log.Shape(Keep, { Gold = 0 }, RENAME):Rehydrate(Record)
	end).ToThrow()
end

function Suite.PrepareLeavesStoredSnapshotUnmigrated()
	local K = Key("prepmig")
	W():UpdateAsync(K, function()
		return { Snapshot = { Coins = 55 }, Ops = {} }
	end)

	local Leg: any = { Id = "leg:prepmig", Kind = "Keep", Tx = "tx:prepmig", TxHome = "Home" }
	local Verdict = Log.New(W()):Prepare(K, Leg, Log.Shape(Keep, { Gold = 0 }, RENAME))

	local Record = Log.New(W()):Read(K)
	local Snapshot = Record.Snapshot :: any

	Expect(Verdict).ToBe("Prepared")
	Expect(Snapshot.Coins).ToBe(55)
	Expect(Snapshot.Gold).ToBeNil()
	Expect(Record.Version).ToBeNil()

	local State = Log.Shape(Keep, { Gold = 0 }, RENAME):Rehydrate(Log.New(W()):Read(K)) :: any

	Expect(State.Gold).ToBe(55)
end

local function Money(State: any, Op: any): any?
	if Op.Kind ~= "Add" then
		return nil
	end
	local Next = table.clone(State)
	Next.Gold += Op.Amount
	return Next
end

local BUMP: Types.Migration = function(State: any): any
	State.Gold = (State.Gold or 0) + 0
	return State
end

local COMPATIBLE: Types.Migration = {
	Compatible = true,
	Apply = function(State: any): any
		return State
	end
}

local function ResetStore(Steps: { Types.Migration }): (any, DataStoreWrapper.DataStoreWrapper)
	local Name = `MigReset_{Harness.Uid()}`
	local Store = Ledger.New({
		Name = Name,
		Keys = "String",
		Reducer = Money,
		Default = { Gold = 100 },
		Migrations = Steps
	})
	return Store, DataStoreWrapper.New(Name)
end

local function ResetOp(Id: string, State: any, Version: number?, Floor: number?): any
	return { Id = Id, Kind = "__Reset", State = State, Version = Version, Floor = Floor }
end

function Suite.ResetRefusesFutureVersion()
	local Store, Raw = ResetStore({ BUMP })
	local K = "future"

	Store:Edit(K, "Add", { Amount = 25 }):Wait()
	Log.New(Raw):Append(K, { ResetOp("reset:future", { Gold = 0, Shape = "new" }, 5, 5) })

	local State = Store:Peek(K):Wait()

	Expect(State.Gold).ToBe(125)
	Expect(State.Shape).ToBeNil()
end

function Suite.ResetCompatibleFutureApplies()
	local Store, Raw = ResetStore({ BUMP })
	local K = "compatfuture"

	Store:Edit(K, "Add", { Amount = 25 }):Wait()
	Log.New(Raw):Append(K, { ResetOp("reset:compat", { Gold = 7 }, 5, 1) })

	local State = Store:Peek(K):Wait()

	Expect(State.Gold).ToBe(7)
end

function Suite.ResetUnstampedStillApplies()
	local Store, Raw = ResetStore({ BUMP })
	local K = "legacy"

	Store:Edit(K, "Add", { Amount = 25 }):Wait()
	Log.New(Raw):Append(K, { ResetOp("reset:legacy", { Gold = 3 }) })

	local State = Store:Peek(K):Wait()

	Expect(State.Gold).ToBe(3)
end

function Suite.ResetStampsWriterVersion()
	local Plain, PlainRaw = ResetStore({ BUMP })
	local Mixed, MixedRaw = ResetStore({ BUMP, COMPATIBLE })

	Plain:Reset("stamped"):Wait()
	Mixed:Reset("stamped"):Wait()

	local function StampOf(Raw: DataStoreWrapper.DataStoreWrapper): any
		for _, Op in Log.New(Raw):Read("stamped").Ops do
			if Op.Kind == "__Reset" then
				return Op
			end
		end
		return nil
	end

	local PlainOp, MixedOp = StampOf(PlainRaw), StampOf(MixedRaw)

	Expect(PlainOp).Never.ToBeNil()
	Expect(PlainOp.Version).ToBe(1)
	Expect(PlainOp.Floor).ToBe(1)
	Expect(MixedOp).Never.ToBeNil()
	Expect(MixedOp.Version).ToBe(2)
	Expect(MixedOp.Floor).ToBe(1)
end

return table.freeze(Suite)
