--!strict

local Harness = require("./Harness")
local Log = require("../src/Log")
local MakeOp = require("../src/MakeOp")
local Reconcile = require("../src/Reconcile")
local Session = require("../src/Session")
local Testing = require("./Testing")

local Expect = Testing.Expect
local W = Harness.Store
local Key = Harness.Key
local Reducer = Harness.Reducer
local INIT = Harness.INIT
local MigDefault = Harness.MigDefault
local MigReducer = Harness.MigReducer

local Suite = {}

function Suite.ReconcileDefaults()
	local K = Key("reconcile")
	W():UpdateAsync(K, function()
		return { Snapshot = { Gold = 50 }, Ops = {} }
	end)

	local Sess = Session.Load(W(), K, function(State: any) return State end, { Gold = 100, Gems = 7 }):Wait()
	local St = Sess:Get()

	Expect(St.Gold).ToBe(50)
	Expect(St.Gems).ToBe(7)
end

function Suite.ReconcileInFold()
	local K = Key("mig")
	Log.Append(W(), K, { MakeOp("Add", { Amount = 100 }) })
	Log.Compact(W(), K, Reducer, INIT)

	local S = Session.Load(W(), K, MigReducer, MigDefault):Wait()
	local HadSettings = S:Get().Settings ~= nil
	local Applied = S:Apply("SetVol", { Amount = 10 })
	S:Flush():Wait()

	local Settings = S:Get().Settings :: { Volume: number }?
	local Vol = if Settings then Settings.Volume else nil

	Expect(HadSettings).ToBe(true)
	Expect(Applied).ToBe(true)
	Expect(Settings).Never.ToBeNil()
	Expect(Vol).ToBe(10)
end

function Suite.ReconcileArrayNoBackfill()
	local D: any = { Hotbar = { "A", "B", "C" }, Coins = 5 }
	local Stored: any = { Hotbar = { "X" } }
	Reconcile(D, Stored)

	Expect(Stored.Hotbar).ToHaveLength(1)
	Expect(Stored.Hotbar[1]).ToBe("X")
	Expect(Stored.Coins).ToBe(5)
end

return table.freeze(Suite)
