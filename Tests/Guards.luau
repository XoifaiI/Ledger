--!strict

-- guards suite, everything New and the entry points must refuse before it ever reaches a datastore

local Fold = require("../src/Fold")
local Future = require("../src/Util/Future")
local Log = require("../src/Log")
local Session = require("../src/Session")
local DataStoreWrapper = require("../src/Util/DataStoreWrapper")
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
			Name = `GuardsDS_{Harness.Uid()}`,
			Reducer = Keep,
			Default = { Gold = 0 }
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
	local Active = Session.Load(Log.New(W()), Log.Shape(Banana, { Gold = 0 }), K):Wait()
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
	local Name = `GuardsStr_{Harness.Uid()}`
	local Store = Ledger.New({ Name = Name, Keys = "String", Reducer = Keep, Default = { Gold = 0 } })

	local TxCollision = not pcall(function()
		Ledger.New({ Name = `{Name}_Tx`, Reducer = Keep, Default = {} })
	end)
	local LoadRefused = not pcall(function()
		Store:Load(nil)
	end)

	local function Peeking(Key: any): boolean
		return not pcall(function()
			Store:Peek(Key)
		end)
	end

	local NumberKey = Peeking(261)
	local EmptyKey = Peeking("")
	local LongKey = Peeking(string.rep("k", 51))
	local JunkBytes = Peeking("\255\254")

	local function Accept(State: any, Op: any): any?
		if Op.Kind == "Set" then
			local Next = table.clone(State)
			Next.Gold = Op.Amount
			return Next
		end
		return nil
	end
	local Round = Ledger.New({ Name = `{Name}_r`, Keys = "String", Reducer = Accept, Default = { Gold = 0 } })
	Round:Edit("clan one", "Set", { Amount = 5 }):Wait()
	local Peeked = Round:Peek("clan one"):Wait()

	Expect(TxCollision).ToBe(true)
	Expect(LoadRefused).ToBe(true)
	Expect(NumberKey).ToBe(true)
	Expect(EmptyKey).ToBe(true)
	Expect(LongKey).ToBe(true)
	Expect(JunkBytes).ToBe(true)
	Expect(Peeked.Gold).ToBe(5)
end

function Suite.GuardCrossStoreTx()
	local Name = `GuardsX_{Harness.Uid()}`
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
	local ClanStore = Ledger.New({ Name = `{Name}_c`, Keys = "String", Reducer = Move, Default = { Gold = 0 } })
	local Uid = Harness.Uid()

	local JunkStore = pcall(function()
		PlayerStore:Tx(`x{Uid}j`, {
			{ UserId = Uid, Kind = "Move", Fields = { Amount = 1 } },
			{ Store = {}, Key = "clan x", Kind = "Move", Fields = { Amount = -1 } }
		})
	end)

	local Broke, BrokeWhy = PlayerStore:Tx(`x{Uid}b`, {
		{ UserId = Uid, Kind = "Move", Fields = { Amount = 25 } },
		{ Store = ClanStore, Key = "clan x", Kind = "Move", Fields = { Amount = -25 } }
	}):Wait()

	ClanStore:Edit("clan x", "Move", { Amount = 40 }):Wait()
	local Funded = PlayerStore:Tx(`x{Uid}f`, {
		{ UserId = Uid, Kind = "Move", Fields = { Amount = 25 } },
		{ Store = ClanStore, Key = "clan x", Kind = "Move", Fields = { Amount = -25 } }
	}):Wait()

	local PlayerState = PlayerStore:Peek(Uid):Wait()
	local ClanState = ClanStore:Peek("clan x"):Wait()

	Expect(JunkStore).ToBe(false)
	Expect(Broke).ToBe(false)
	Expect(BrokeWhy).ToBe("Refused")
	Expect(Funded).ToBe(true)
	Expect(PlayerState.Gold).ToBe(25)
	Expect(ClanState.Gold).ToBe(15)
end

function Suite.GuardBadUserIds()
	local Store = EnsureStore()

	local PeekRefused = not pcall(function()
		Store:Peek("abc")
	end)
	local EditRefused = not pcall(function()
		Store:Edit(nil, "K")
	end)

	local TransferSelf = pcall(function()
		Store:Transfer(5, 5, 10)
	end)
	local TransferJunk = pcall(function()
		Store:Transfer(0.5, 2, 10)
	end)
	local TransferZero = pcall(function()
		Store:Transfer(1, 2, 0)
	end)
	local TransferNaN = pcall(function()
		Store:Transfer(1, 2, 0 / 0)
	end)

	local TxJunk = pcall(function()
		Store:Tx("junkkey", { { UserId = "x", Kind = "K" }, { UserId = 2, Kind = "K" } })
	end)
	local TxNoId = pcall(function()
		Store:Tx({ { UserId = 1, Kind = "K" }, { UserId = 2, Kind = "K" } })
	end)
	local TxOneLeg = pcall(function()
		Store:Tx("oneleg", { { UserId = 1, Kind = "K" } })
	end)

	local ResetRefused = not pcall(function()
		Store:Reset(-1)
	end)

	Expect(PeekRefused).ToBe(true)
	Expect(EditRefused).ToBe(true)
	Expect(TransferSelf).ToBe(false)
	Expect(TransferJunk).ToBe(false)
	Expect(TransferZero).ToBe(false)
	Expect(TransferNaN).ToBe(false)
	Expect(TxJunk).ToBe(false)
	Expect(TxNoId).ToBe(false)
	Expect(TxOneLeg).ToBe(false)
	Expect(ResetRefused).ToBe(true)
end

function Suite.GuardNoBalance()
	local Store = EnsureStore()

	local TransferOk = pcall(function()
		Store:Transfer(Harness.Uid(), Harness.Uid(), 10)
	end)

	local RecoverRefused = not pcall(function()
		Store:RecoverTransfers(Harness.Uid())
	end)

	Expect(TransferOk).ToBe(false)
	Expect(RecoverRefused).ToBe(true)
end

function Suite.GuardEntityLifecycle()
	local Store = Ledger.New({
		Name = `GuardsLife_{Harness.Uid()}`,
		Keys = "String",
		Reducer = Keep,
		Default = { Gold = 0 }
	})
	local Dummy: any = nil

	local GetRefused = not pcall(function() Store:Get(Dummy) end)
	local ExpectRefused = not pcall(function() Store:Expect(Dummy) end)
	local IsLoadedRefused = not pcall(function() Store:IsLoaded(Dummy) end)
	local ReadRefused = not pcall(function() Store:Read(Dummy) end)
	local WaitRefused = not pcall(function() Store:WaitForLoaded(Dummy) end)

	Expect(GetRefused).ToBe(true)
	Expect(ExpectRefused).ToBe(true)
	Expect(IsLoadedRefused).ToBe(true)
	Expect(ReadRefused).ToBe(true)
	Expect(WaitRefused).ToBe(true)
end

function Suite.GuardEditUnstorable()
	local Store = EnsureStore()
	local Uid = Harness.Uid()

	local Bad, BadWhy = Store:Edit(Uid, "K", { Fn = Keep }):Wait()
	local Good, GoodWhy = Store:Edit(Uid, "Add", { Amount = 1 }):Wait()

	local Picky = Ledger.New({
		Name = `GuardsPicky_{Harness.Uid()}`,
		Reducer = function(State: any, Op: any): any?
			if Op.Kind ~= "Add" then
				return nil
			end
			return { Gold = State.Gold + Op.Amount }
		end,
		Default = { Gold = 0 }
	})
	local Unknown, UnknownWhy = Picky:Edit(Harness.Uid(), "NoSuchKind", { Amount = 1 }):Wait()

	Expect(Bad).ToBe(false)
	Expect(BadWhy).ToBe("Invalid")
	Expect(Good).ToBe(true)
	Expect(GoodWhy).ToBeNil()
	Expect(Unknown).ToBe(false)
	Expect(UnknownWhy).ToBe("Refused")
end

function Suite.GuardResetReconciles()
	local Name = `GuardsReset_{Harness.Uid()}`
	local Store = Ledger.New({
		Name = Name,
		Keys = "String",
		Reducer = Keep,
		Default = { Gold = 100, Extra = "keep" }
	})

	local Raw = DataStoreWrapper.New(Name)
	Log.New(Raw):Append("k1", { { Id = "reset1", Kind = "__Reset", State = { Gold = 5 } } :: any })

	local State = Store:Peek("k1"):Wait()

	Expect(State.Gold).ToBe(5)
	Expect(State.Extra).ToBe("keep")
end

function Suite.GuardFutureWaitTimeout()
	local Slow = Future.New(function(): number
		task.wait(1)
		return 42
	end)

	local Start = os.clock()
	local TimedOut = Slow:Wait(0.1)
	local Elapsed = os.clock() - Start
	local StillRunning = Slow:Happened()

	local Settled = Slow:Wait()

	Expect(TimedOut).ToBeNil()
	Expect(Elapsed).ToBeLessThan(0.9)
	Expect(StillRunning).ToBe(false)
	Expect(Settled).ToBe(42)
	Expect(Slow:Happened()).ToBe(true)
end

function Suite.GuardEditSettlesPendingLeg()
	local Name = `GuardsSettle_{Harness.Uid()}`
	local function Add(State: any, Op: any): any?
		if Op.Kind ~= "Add" then
			return nil
		end
		local Next = table.clone(State)
		Next.Gold += Op.Amount
		return Next
	end
	local Store = Ledger.New({ Name = Name, Keys = "String", Reducer = Add, Default = { Gold = 0 } })

	local Raw = DataStoreWrapper.New(Name)
	local TxRaw = DataStoreWrapper.New(`{Name}_Tx`)
	local Txid = `tx{Harness.Uid()}`
	local K = "clan"

	TxRaw:UpdateAsync(Txid, function()
		return { Status = "Committed", Total = 1, Adopted = 0 }
	end)
	Raw:UpdateAsync(K, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Txid}:1`, Kind = "Add", Amount = 25, Tx = Txid, TxHome = TxRaw.Name })
		return Record
	end)

	local Before = Store:Peek(K):Wait()
	Store:Edit(K, "Add", { Amount = 5 }):Wait()
	local After = Store:Peek(K):Wait()

	Expect(Before.Gold).ToBe(0)
	Expect(After.Gold).ToBe(30)
	Expect(Log.HasPending(Log.New(Raw):Read(K))).ToBe(false)
end

function Suite.GuardWakeSurvivesDeadWaiter()
	local Store = Ledger.New({
		Name = `GuardsWake_{Harness.Uid()}`,
		Reducer = Keep,
		Default = { Gold = 0 }
	})
	local Fake: any = { UserId = Harness.Uid(), Name = "Fake", Parent = workspace }

	local Dead = task.spawn(function()
		Store:WaitForLoaded(Fake)
	end)
	local Woke = false
	task.spawn(function()
		Store:WaitForLoaded(Fake)
		Woke = true
	end)

	coroutine.close(Dead)

	local Threw = not pcall(function()
		Store:Unload(Fake)
	end)
	task.wait()

	Expect(Threw).ToBe(false)
	Expect(Woke).ToBe(true)
end

function Suite.GuardTxLegFields()
	local Store = Ledger.New({
		Name = `GuardsFields_{Harness.Uid()}`,
		Reducer = Keep,
		Default = { Gold = 0 }
	})

	local BadFields = pcall(function()
		Store:Tx("badfields", {
			{ UserId = Harness.Uid(), Kind = "K", Fields = "nope" },
			{ UserId = Harness.Uid(), Kind = "K" }
		})
	end)

	local Unstorable = pcall(function()
		Store:Tx("unstorable", {
			{ UserId = Harness.Uid(), Kind = "K", Fields = { Thing = workspace } },
			{ UserId = Harness.Uid(), Kind = "K" }
		})
	end)

	local Reserved = pcall(function()
		Store:Tx("reserved", {
			{ UserId = Harness.Uid(), Kind = "K", Fields = { Tx = "hax" } },
			{ UserId = Harness.Uid(), Kind = "K" }
		})
	end)
	local OwnedKind = pcall(function()
		Store:Tx("ownedkind", {
			{ UserId = Harness.Uid(), Kind = "__TransferDeliver" },
			{ UserId = Harness.Uid(), Kind = "K" }
		})
	end)

	local Legit = Store:Tx("legit", {
		{ UserId = Harness.Uid(), Kind = "K", Fields = { Amount = 1 } },
		{ UserId = Harness.Uid(), Kind = "K", Fields = { Amount = 1 } }
	})
	local Answered = Legit:Wait()

	Expect(BadFields).ToBe(false)
	Expect(Unstorable).ToBe(false)
	Expect(Reserved).ToBe(false)
	Expect(OwnedKind).ToBe(false)
	Expect(Legit:Happened()).ToBe(true)
	Expect(typeof(Answered)).ToBe("boolean")
end

local function EraseStore(): (any, any)
	local Name = `GuardsErase_{Harness.Uid()}`
	local Store = Ledger.New({
		Name = Name,
		Reducer = function(State: any, Op: any): any?
			if Op.Kind ~= "Add" then
				return nil
			end
			return { Gold = State.Gold + Op.Amount }
		end,
		Default = { Gold = 0 },
		Balance = "Gold"
	})
	return Store, DataStoreWrapper.New(Name, 30, 0.15, 1.1)
end

function Suite.GuardEraseDeliversHoldsFirst()
	local Store, Raw = EraseStore()
	local A, B = Harness.Uid(), Harness.Uid()

	Log.New(Raw):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	Log.New(Raw):Append(tostring(A), {
		{ Id = "res:fresh", Kind = "__TransferReserve", To = B, Amount = 40, Tid = "fresh", At = os.time() } :: any
	})

	Store:Erase(A):Wait()

	local Receiver = Store:Peek(B):Wait()
	local Gone = Store:Peek(A):Wait()

	Expect(Receiver.Gold).ToBe(40)
	Expect(Gone.Gold).ToBe(0)
end

function Suite.GuardEraseReportsUndeliverableHolds()
	local Store, Raw = EraseStore()
	local A, B = Harness.Uid(), Harness.Uid()
	local Margin = os.time() - 7 * 86400 - 43200

	Log.New(Raw):Append(tostring(A), { MakeOp("Add", { Amount = 100 }) })
	Log.New(Raw):Append(tostring(A), {
		{ Id = "res:margin", Kind = "__TransferReserve", To = B, Amount = 40, Tid = "margin", At = Margin } :: any
	})

	local Erased = Store:Erase(A)
	Erased:Wait()

	local Receiver = Store:Peek(B):Wait()
	local Gone = Store:Peek(A):Wait()

	Expect(Erased:Happened()).ToBe(true)
	Expect(Receiver.Gold).ToBe(0)
	Expect(Gone.Gold).ToBe(0)
end

function Suite.GuardSweepSettlesStrandedLeg()
	local Name = `GuardsSweep_{Harness.Uid()}`
	local Store = Ledger.New({
		Name = Name,
		Keys = "String",
		Reducer = function(State: any, Op: any): any?
			if Op.Kind ~= "Add" then
				return nil
			end
			return { Gold = State.Gold + Op.Amount }
		end,
		Default = { Gold = 0 }
	})

	local Raw = DataStoreWrapper.New(Name, 30, 0.15, 1.1)
	local Marker = DataStoreWrapper.New(`{Name}_Tx`, 30, 0.15, 1.1)
	local Key = `clan_{Harness.Uid()}`
	local Txid = `sweep_{Harness.Uid()}`

	Marker:UpdateAsync(Txid, function()
		return { Status = "Committed", Total = 1, Adopted = 0 }
	end)
	Raw:UpdateAsync(Key, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = `tx:{Txid}:1`, Kind = "Add", Amount = 40, Tx = Txid, TxHome = Marker.Name })
		return Record
	end)

	local Stale = Store:Peek(Key):Wait()

	Ledger.Sweep()

	local Settled = Store:Peek(Key):Wait()
	local Clean = not Log.HasPending(Log.New(Raw):Read(Key))

	Expect(Stale.Gold).ToBe(0)
	Expect(Settled.Gold).ToBe(40)
	Expect(Clean).ToBe(true)
end

function Suite.GuardSweepGivesUpOnAStuckLeg()
	local Name = `GuardsStuck_{Harness.Uid()}`
	local Store = Ledger.New({
		Name = Name,
		Keys = "String",
		Reducer = Keep,
		Default = { Gold = 0 }
	})

	local Raw = DataStoreWrapper.New(Name, 30, 0.15, 1.1)
	local Key = `clan_{Harness.Uid()}`

	Raw:UpdateAsync(Key, function(Current: any)
		local Record = if type(Current) == "table" then Current else { Ops = {}, Seen = {} }
		table.insert(Record.Ops, { Id = "tx:ghost:1", Kind = "Add", Amount = 1, Tx = "ghost", TxHome = "\0nowhere" })
		return Record
	end)

	Store:Peek(Key):Wait()

	local Reads = 0
	local Watched: any = setmetatable({}, {
		__index = function(_, Member: string): any
			local Inner = (Raw :: any)[Member]
			if type(Inner) ~= "function" then
				return Inner
			end
			return function(_: any, ...): ...any
				if Member == "GetAsync" then
					Reads += 1
				end
				return (Inner :: any)(Raw, ...)
			end
		end
	})
	;(Store :: any).Wrapper = Watched

	for _ = 1, 12 do
		Ledger.Sweep()
	end

	Expect(Reads > 0).ToBe(true)
	Expect(Reads <= 5).ToBe(true)
end

local function FailFrom(Inner: any, Method: string, Index: number): any
	local Count = 0
	return setmetatable({}, {
		__index = function(_, Name: string): any
			local Member = (Inner :: any)[Name]
			if type(Member) ~= "function" then
				return Member
			end
			local Call = Member :: (...any) -> ...any
			return function(_: any, ...): ...any
				if Name == Method then
					Count += 1
					if Count >= Index then
						return false, "chaos: injected failure"
					end
				end
				return Call(Inner, ...)
			end
		end
	})
end

function Suite.GuardSweepFinishesStrandedEscrow()
	local Name = `GuardsEscrow_{Harness.Uid()}`
	local Store = Ledger.New({
		Name = Name,
		Keys = "String",
		Balance = "Gold",
		Reducer = function(State: any, Op: any): any?
			if Op.Kind ~= "Add" then
				return nil
			end
			return { Gold = State.Gold + Op.Amount }
		end,
		Default = { Gold = 0 }
	})

	local From, To = `bank_{Harness.Uid()}`, `bank_{Harness.Uid()}`
	Store:Edit(From, "Add", { Amount = 100 }):Wait()

	local Raw = (Store :: any).Wrapper
	;(Store :: any).Wrapper = FailFrom(Raw, "UpdateAsync", 2)

	local Ok, Why = Store:Transfer(From, To, 40):Wait()

	;(Store :: any).Wrapper = Raw

	Expect(Ok).ToBe(false)
	Expect(Why).ToBe("Unresolved")

	Expect(Store:Peek(From):Wait().Gold).ToBe(60)
	Expect(Store:Peek(To):Wait().Gold).ToBe(0)

	Ledger.Sweep()

	Expect(Store:Peek(To):Wait().Gold).ToBe(40)
	Expect(Store:Peek(From):Wait().Gold).ToBe(60)

	local Held = (Store:Peek(From):Wait() :: any)._Held
	Expect(Held == nil or next(Held) == nil).ToBe(true)
end

function Suite.GuardFailedCompactionKeepsTheVerdict()
	local Name = `GuardsCompact_{Harness.Uid()}`
	local Store = Ledger.New({
		Name = Name,
		Keys = "String",
		Reducer = function(State: any, Op: any): any?
			if Op.Kind ~= "Add" then
				return nil
			end
			return { Gold = State.Gold + Op.Amount }
		end,
		Default = { Gold = 0 }
	})

	local Raw = DataStoreWrapper.New(Name, 30, 0.15, 1.1)
	local Key = `clan_{Harness.Uid()}`

	local Seed = {}
	for Index = 1, 130 do
		Seed[Index] = { Id = `seed{Index}`, Kind = "Add", Amount = 1 } :: any
	end
	Log.New(Raw):Append(Key, Seed)

	;(Store :: any).Wrapper = FailFrom(Raw, "UpdateAsync", 2)

	local Ok, Why = Store:Edit(Key, "Add", { Amount = 5 }):Wait()

	Expect(Ok).ToBe(true)
	Expect(Why).ToBeNil()
end

function Suite.GuardResetRefusesANewerRecord()
	local Name = `GuardsResetVer_{Harness.Uid()}`
	local Behind = Ledger.New({
		Name = Name,
		Keys = "String",
		Reducer = Keep,
		Default = { Gold = 0 },
		Migrations = {
			function(State: any): any
				return State
			end
		}
	})

	local Raw = DataStoreWrapper.New(Name, 30, 0.15, 1.1)
	local Key = `clan_{Harness.Uid()}`

	Raw:UpdateAsync(Key, function()
		return { Snapshot = { Gold = 500 }, Ops = {}, Seen = {}, Version = 4, Floor = 4, Envelope = 1 }
	end)

	local Ok, Why = Behind:Reset(Key):Wait()
	local After = Log.New(Raw):Read(Key)

	Expect(Ok).ToBe(false)
	Expect(Why).ToBe("Refused")
	Expect(After.Version).ToBe(4)
	Expect(#After.Ops).ToBe(0)

	local Fresh = `clan_{Harness.Uid()}`
	Raw:UpdateAsync(Fresh, function()
		return { Snapshot = { Gold = 500 }, Ops = {}, Seen = {}, Version = 1, Floor = 1, Envelope = 1 }
	end)
	local Reset = Behind:Reset(Fresh):Wait()

	Expect(Reset).ToBe(true)
end

function Suite.GuardMigrationRemovingADefaultKey()
	local function Drop(State: any): any
		local Next = table.clone(State)
		Next.Coins = nil
		return Next
	end

	local Bad = Harness.Warnings(function()
		Ledger.New({
			Name = `GuardsMigDrop_{Harness.Uid()}`,
			Reducer = Keep,
			Default = { Gold = 0, Coins = 0 },
			Migrations = { Drop }
		})
	end)

	local Clean = Harness.Warnings(function()
		Ledger.New({
			Name = `GuardsMigOk_{Harness.Uid()}`,
			Reducer = Keep,
			Default = { Gold = 0 },
			Migrations = { Drop }
		})
	end)

	local Threw = Harness.Warnings(function()
		Ledger.New({
			Name = `GuardsMigThrow_{Harness.Uid()}`,
			Reducer = Keep,
			Default = { Gold = 0 },
			Migrations = {
				function(State: any): any
					return { Gold = State.Legacy.Nested }
				end
			}
		})
	end)

	local Restored = Harness.Warnings(function()
		Ledger.New({
			Name = `GuardsMigBack_{Harness.Uid()}`,
			Reducer = Keep,
			Default = { Gold = 0, Coins = 0 },
			Migrations = {
				Drop,
				function(State: any): any
					local Next = table.clone(State)
					Next.Coins = 100
					return Next
				end
			}
		})
	end)

	Expect(Harness.Mentioning(Bad, "Default still declares")).ToBe(1)
	Expect(Harness.Mentioning(Bad, "'Coins'")).ToBe(1)
	Expect(Harness.Mentioning(Clean, "Default still declares")).ToBe(0)
	Expect(Harness.Mentioning(Threw, "Default still declares")).ToBe(0)
	Expect(Harness.Mentioning(Restored, "Default still declares")).ToBe(0)
end

return table.freeze(Suite)
