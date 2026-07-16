--!strict

local Fold = require("../src/Fold")
local Session = require("../src/Session")
local Harness = require("./Harness")
local Testing = require("./Testing")

local Data: any = require("../src")
local MakeOp: any = require("../src/MakeOp")

local Expect = Testing.Expect
local W = Harness.Store
local Key = Harness.Key
local Uid = Harness.Uid

local Suite = {}

local function Keep(State: any): any?
	return State
end

local function Refused(Options: any): boolean
	return not pcall(function()
		Data:Configure(Options)
	end)
end

local function EnsureStore()
	Data:Configure({
		Name = "GuardsDS",
		Reducer = Keep,
		Default = { Gold = 0 },
	})
end

function Suite.GuardConfigure()
	local NoName = Refused({ Reducer = Keep, Default = {} })
	local NoReducer = Refused({ Name = "GuardsDS", Default = {} })
	local ReservedKey = Refused({ Name = "GuardsDS", Reducer = Keep, Default = { _Mine = 1 } })
	local Unstorable = Refused({ Name = "GuardsDS", Reducer = Keep, Default = { Callback = Keep } })
	local BadStep = Refused({ Name = "GuardsDS", Reducer = Keep, Default = {}, Migrations = { 5 } })
	local BadBalance = Refused({ Name = "GuardsDS", Reducer = Keep, Default = { Gold = 0 }, Balance = 5 })
	local Misfit = Refused({ Name = "GuardsDS", Reducer = Keep, Default = { Gold = "lots" }, Balance = "Gold" })

	Expect(NoName).ToBe(true)
	Expect(NoReducer).ToBe(true)
	Expect(ReservedKey).ToBe(true)
	Expect(Unstorable).ToBe(true)
	Expect(BadStep).ToBe(true)
	Expect(BadBalance).ToBe(true)
	Expect(Misfit).ToBe(true)
	Expect(EnsureStore).Never.ToThrow()
end

function Suite.GuardReducerNonTable()
	local function Banana(State: any, Op: any): any?
		if Op.Kind == "Bad" then
			return "banana"
		elseif Op.Kind == "Good" then
			local Next = table.clone(State)
			Next.Gold += 1
			return Next
		end
		return nil
	end

	local K = Key("guardred")
	local Active = Session.Load(W(), K, Banana, { Gold = 0 }):Wait()
	local BadApplied = Active:Apply("Bad")
	local GoodApplied = Active:Apply("Good")
	local State = Active:Get()

	local Folded = Fold({ Gold = 5 }, { { Id = "x", Kind = "Bad" } :: any }, Banana) :: any

	Expect(BadApplied).ToBeFalsy()
	Expect(GoodApplied).ToBeTruthy()
	Expect(type(State)).ToBe("table")
	Expect(State.Gold).ToBe(1)
	Expect(Folded.Gold).ToBe(5)
end

function Suite.GuardMakeOp()
	Expect(function()
		local _ = MakeOp(5)
	end).ToThrow()
	Expect(function()
		local _ = MakeOp("")
	end).ToThrow()
	Expect(function()
		local _ = MakeOp("K", 5)
	end).ToThrow()

	local Clobbered: any = MakeOp("K", { Id = "mine", Kind = "Fake", Amount = 1 })

	Expect(Clobbered.Id).Never.ToBe("mine")
	Expect(Clobbered.Kind).ToBe("K")
	Expect(Clobbered.Amount).ToBe(1)
end

function Suite.GuardBadUserIds()
	EnsureStore()

	local PeekFuture = Data:Peek("abc")
	PeekFuture:Wait()
	local PeekRefused = not PeekFuture:Happened()

	local EditOk = pcall(function()
		Data:Edit(nil, "K"):Wait()
	end)

	local TransferSelf = Data:Transfer(5, 5, 10):Wait()
	local TransferJunk = Data:Transfer(0.5, 2, 10):Wait()

	local TxJunk = Data:Tx({ { UserId = "x", Kind = "K" }, { UserId = 2, Kind = "K" } }):Wait()

	local ResetFuture = Data:Reset(-1)
	ResetFuture:Wait()
	local ResetRefused = not ResetFuture:Happened()

	Expect(PeekRefused).ToBe(true)
	Expect(EditOk).ToBe(true)
	Expect(TransferSelf).ToBe(false)
	Expect(TransferJunk).ToBe(false)
	Expect(TxJunk).ToBe(false)
	Expect(ResetRefused).ToBe(true)
end

function Suite.GuardNoBalanceConfigured()
	EnsureStore()

	local TransferOk = Data:Transfer(Uid(), Uid(), 10):Wait()

	local RecoverFuture = Data:RecoverTransfers(Uid())
	RecoverFuture:Wait()
	local RecoverRefused = not RecoverFuture:Happened()

	Expect(TransferOk).ToBe(false)
	Expect(RecoverRefused).ToBe(true)
end

return table.freeze(Suite)
