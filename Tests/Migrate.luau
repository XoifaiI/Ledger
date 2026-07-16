--!strict

local Harness = require("./Harness")
local Log = require("../src/Log")
local Session = require("../src/Session")
local Types = require("../src/Types")
local Testing = require("./Testing")

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
	end,
}

local CHAIN: { Types.Migration } = {
	RENAME[1],
	{
		Compatible = true,
		Apply = function(State: any): any
			State.Gold *= 10
			return State
		end,
	},
}

function Suite.MigrateOnLoad()
	local K = Key("migrate")
	W():UpdateAsync(K, function()
		return { Snapshot = { Coins = 55 }, Ops = {} }
	end)

	local Active = Session.Load(W(), K, Keep, { Gold = 0 }, RENAME):Wait()
	local State = Active:Get()

	Expect(State.Gold).ToBe(55)
	Expect(State.Coins).ToBeNil()
end

function Suite.MigrateChainsFromStoredVersion()
	local K = Key("migratechain")
	W():UpdateAsync(K, function()
		return { Snapshot = { Gold = 7 }, Ops = {}, Version = 1 }
	end)

	local Active = Session.Load(W(), K, Keep, { Gold = 0 }, CHAIN):Wait()
	local State = Active:Get()

	Expect(State.Gold).ToBe(70)
end

function Suite.MigrateStampsOnCompact()
	local K = Key("migratestamp")
	W():UpdateAsync(K, function()
		return { Snapshot = { Coins = 5 }, Ops = {} }
	end)

	Log.Compact(W(), K, Keep, { Gold = 0 }, RENAME)
	local Record = Log.Read(W(), K)
	local Again = Log.Rehydrate(Record, { Gold = 0 }, RENAME) :: any

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

	local Active = Session.Load(W(), K, Keep, { Gold = 0 }, RENAME):Wait()
	local State = Active:Get()

	Expect(State.Gold).ToBe(5)
	Expect(State.Coins).ToBeNil()
end

function Suite.MigrateCompactPreservesFuture()
	local K = Key("migkeep")
	W():UpdateAsync(K, function()
		return { Snapshot = { Gold = 5 }, Ops = {}, Version = 2, Floor = 1 }
	end)

	Log.Compact(W(), K, Keep, { Gold = 0 }, RENAME)
	local Record = Log.Read(W(), K)

	Expect(Record.Version).ToBe(2)
	Expect(Record.Floor).ToBe(1)
	Expect((Record.Snapshot :: any).Gold).ToBe(5)
end

function Suite.MigrateRefusesFuture()
	local K = Key("migratefuture")
	W():UpdateAsync(K, function()
		return { Snapshot = { Gold = 1 }, Ops = {}, Version = 5 }
	end)

	local Loaded = Session.Load(W(), K, Keep, { Gold = 0 }, RENAME)
	local Active = Loaded:Wait()

	local Record = Log.Read(W(), K)

	Expect(Loaded:Happened()).ToBe(false)
	Expect(Active).ToBeNil()
	Expect(function()
		Log.Rehydrate(Record, { Gold = 0 }, RENAME)
	end).ToThrow()
end

return table.freeze(Suite)
