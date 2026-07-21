--!strict

--[=[
    Guards suite: the idiot-proofing. New must refuse a missing name, a missing reducer,
    a reserved _ key or an unstorable value in the Default, a malformed migration step, a
    name too long for the transaction store, and a Balance that names no numeric field,
    all at build time instead of at the first player. A reducer that returns a non-table
    must read as a rejection everywhere. MakeOp must refuse junk kinds and clobber
    reserved fields loudly. The cross-server entry points must refuse junk keys benignly
    instead of reading or writing a garbage key. Entity stores refuse the session
    lifecycle and non-string keys. A cross-store transaction refuses a junk Store leg and
    stays atomic across a player store and an entity store.

    Return type: frozen table of test functions, each asserts through Testing.Expect
    Example usage:
        local Suite = require("./Guards")
        Suite.GuardNew()
--]=]

local Fold = require("../src/Fold")
local Session = require("../src/Session")
local Harness = require("./Harness")
local Testing = require("./Testing")

local Ledger: any = require("../src")
local MakeOp: any = require("../src/MakeOp")

local Expect = Testing.Expect
local W = Harness.Store
local Key = Harness.Key

local Suite = {}

local function Keep(State: any): any?
	return State
end

local function Refused(Options: any): boolean
	return not pcall(function()
		Ledger.New(Options)
	end)
end

local GuardStore: any = nil

local function EnsureStore(): any
	if not GuardStore then
		GuardStore = Ledger.New({
			Name = "GuardsDS_" .. Harness.Uid(),
			Reducer = Keep,
			Default = { Gold = 0 },
		})
	end
	return GuardStore
end

function Suite.GuardNew()
	local NoName = Refused({ Reducer = Keep, Default = {} })
	local NoReducer = Refused({ Name = "GuardsDS", Default = {} })
	local ReservedKey = Refused({ Name = "GuardsDS", Reducer = Keep, Default = { _Mine = 1 } })
	local Unstorable = Refused({ Name = "GuardsDS", Reducer = Keep, Default = { Callback = Keep } })
	local BadStep = Refused({ Name = "GuardsDS", Reducer = Keep, Default = {}, Migrations = { 5 } })
	local BadBalance = Refused({ Name = "GuardsDS", Reducer = Keep, Default = { Gold = 0 }, Balance = 5 })
	local Misfit = Refused({ Name = "GuardsDS", Reducer = Keep, Default = { Gold = "lots" }, Balance = "Gold" })
	local LongName = Refused({ Name = string.rep("x", 48), Reducer = Keep, Default = {} })

	Expect(NoName).ToBe(true)
	Expect(NoReducer).ToBe(true)
	Expect(ReservedKey).ToBe(true)
	Expect(Unstorable).ToBe(true)
	Expect(BadStep).ToBe(true)
	Expect(BadBalance).ToBe(true)
	Expect(Misfit).ToBe(true)
	Expect(LongName).ToBe(true)
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

function Suite.GuardStringStore()
	local Name = "GuardsStr_" .. Harness.Uid()
	local Store = Ledger.New({ Name = Name, Keys = "String", Reducer = Keep, Default = { Gold = 0 } })

	local TxCollision = not pcall(function()
		Ledger.New({ Name = Name .. "_Tx", Reducer = Keep, Default = {} })
	end)
	local LoadRefused = not pcall(function()
		Store:Load(nil)
	end)

	local NumberKey = Store:Peek(261)
	NumberKey:Wait()
	local EmptyKey = Store:Peek("")
	EmptyKey:Wait()
	local LongKey = Store:Peek(string.rep("k", 51))
	LongKey:Wait()
	local JunkBytes = Store:Peek("\255\254")
	JunkBytes:Wait()

	local function Accept(State: any, Op: any): any?
		if Op.Kind == "Set" then
			local Next = table.clone(State)
			Next.Gold = Op.Amount
			return Next
		end
		return nil
	end
	local Round = Ledger.New({ Name = Name .. "_r", Keys = "String", Reducer = Accept, Default = { Gold = 0 } })
	Round:Edit("clan one", "Set", { Amount = 5 }):Wait()
	local Peeked = Round:Peek("clan one"):Wait()

	Expect(TxCollision).ToBe(true)
	Expect(LoadRefused).ToBe(true)
	Expect(NumberKey:Happened()).ToBe(false)
	Expect(EmptyKey:Happened()).ToBe(false)
	Expect(LongKey:Happened()).ToBe(false)
	Expect(JunkBytes:Happened()).ToBe(false)
	Expect(Peeked.Gold).ToBe(5)
end

function Suite.GuardCrossStoreTx()
	local Name = "GuardsX_" .. Harness.Uid()
	local function Move(State: any, Op: any): any?
		if Op.Kind ~= "Move" then
			return nil
		end
		local Gold = State.Gold + Op.Amount
		if Gold < 0 then
			return nil
		end
		return { Gold = Gold }
	end
	local PlayerStore = Ledger.New({ Name = Name, Reducer = Move, Default = { Gold = 0 } })
	local ClanStore = Ledger.New({ Name = Name .. "_c", Keys = "String", Reducer = Move, Default = { Gold = 0 } })
	local Uid = Harness.Uid()

	local JunkStore = PlayerStore:Tx({
		{ UserId = Uid, Kind = "Move", Fields = { Amount = 1 } },
		{ Store = {}, Key = "clan x", Kind = "Move", Fields = { Amount = -1 } },
	}):Wait()

	local Broke = PlayerStore:Tx({
		{ UserId = Uid, Kind = "Move", Fields = { Amount = 25 } },
		{ Store = ClanStore, Key = "clan x", Kind = "Move", Fields = { Amount = -25 } },
	}):Wait()

	ClanStore:Edit("clan x", "Move", { Amount = 40 }):Wait()
	local Funded = PlayerStore:Tx({
		{ UserId = Uid, Kind = "Move", Fields = { Amount = 25 } },
		{ Store = ClanStore, Key = "clan x", Kind = "Move", Fields = { Amount = -25 } },
	}):Wait()

	local PlayerState = PlayerStore:Peek(Uid):Wait()
	local ClanState = ClanStore:Peek("clan x"):Wait()

	Expect(JunkStore).ToBe(false)
	Expect(Broke).ToBe(false)
	Expect(Funded).ToBe(true)
	Expect(PlayerState.Gold).ToBe(25)
	Expect(ClanState.Gold).ToBe(15)
end

function Suite.GuardBadUserIds()
	local Store = EnsureStore()

	local PeekFuture = Store:Peek("abc")
	PeekFuture:Wait()
	local PeekRefused = not PeekFuture:Happened()

	local EditOk = pcall(function()
		Store:Edit(nil, "K"):Wait()
	end)

	local TransferSelf = Store:Transfer(5, 5, 10):Wait()
	local TransferJunk = Store:Transfer(0.5, 2, 10):Wait()

	local TxJunk = Store:Tx({ { UserId = "x", Kind = "K" }, { UserId = 2, Kind = "K" } }):Wait()

	local ResetFuture = Store:Reset(-1)
	ResetFuture:Wait()
	local ResetRefused = not ResetFuture:Happened()

	Expect(PeekRefused).ToBe(true)
	Expect(EditOk).ToBe(true)
	Expect(TransferSelf).ToBe(false)
	Expect(TransferJunk).ToBe(false)
	Expect(TxJunk).ToBe(false)
	Expect(ResetRefused).ToBe(true)
end

function Suite.GuardNoBalance()
	local Store = EnsureStore()

	local TransferOk = Store:Transfer(Harness.Uid(), Harness.Uid(), 10):Wait()

	local RecoverFuture = Store:RecoverTransfers(Harness.Uid())
	RecoverFuture:Wait()
	local RecoverRefused = not RecoverFuture:Happened()

	Expect(TransferOk).ToBe(false)
	Expect(RecoverRefused).ToBe(true)
end

return table.freeze(Suite)
