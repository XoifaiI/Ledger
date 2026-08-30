--!strict
--!optimize 2

--[=[

	Shapes: One rule per case for the shape of a stored record.

	Migrations, resets, filling in defaults, version history and byte sizing. All of it is about what a
	record written by one build means to another.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau
--]=]

local HttpService = game:GetService("HttpService")

local Suite = require("../Suite")

local Measure = require("../../src/Encode/Measure")
local NewOp = require("../../src/Record/NewOp")
local Reconcile = require("../../src/Record/Reconcile")
local Schema = require("../../src/Record/Schema")
local Session = require("../../src/Session/Session")
local TableUtil = require("../../src/Util/TableUtil")

local Reducers = Suite.Reducers

type Case = Suite.Case
type Fixture = Suite.Fixture

local Cases = Suite.File("Shapes")

local function Keep(State: any): any?
	return State
end

local RENAME: { any } = {
	function(State: any): any
		State.Gold = State.Coins
		State.Coins = nil
		return State
	end,
}

local CHAIN: { any } = {
	RENAME[1],
	{
		Compatible = true,
		Apply = function(State: any): any
			State.Gold *= 10
			return State
		end,
	},
}

local function Held(T: Case, Steps: { any }?, Default: any?): Fixture
	return T:Store({
		Default = Default or { Gold = 0 },
		Reducer = Keep,
		Migrations = Steps,
	})
end

local function Money(State: any, Op: any): any?
	if Op.Kind ~= "Add" then
		return nil
	end
	local Next = table.clone(State)
	Next.Gold += Op.Amount
	return Next
end

local function Adder(State: any, Op: any): any?
	if Op.Kind ~= "Add" then
		return nil
	end
	local Next = table.clone(State)
	Next.Gold = (Next.Gold or 0) + Op.Amount
	return Next
end

local BUMP: any = function(State: any): any
	State.Gold = (State.Gold or 0) + 0
	return State
end

local COMPATIBLE: any = {
	Compatible = true,
	Apply = function(State: any): any
		return State
	end,
}

local TENFOLD: { any } = {
	function(State: any): any
		State.Gold *= 10
		return State
	end,
}

local function Resettable(T: Case, Steps: { any }, Data: string?): Fixture
	return T:Store({
		Default = { Gold = 100 },
		Reducer = Money,
		Migrations = Steps,
		Data = Data,
	})
end

local function ResetOp(Id: string, State: any, Version: number?, Floor: number?): any
	return { Id = Id, Kind = "__Reset", State = State, Version = Version, Floor = Floor }
end

Cases.Case("a stored snapshot is migrated on load", function(T: Case)
	local Store = Held(T, RENAME)
	Store:Write("migrate", { Snapshot = { Coins = 55 }, Ops = {} })

	local Active: any = Store:Session("migrate")
	local State = Active:Get()

	T:Is("the renamed field", State.Gold, 55)
	T:Is("the old field", State.Coins, nil)
end)

Cases.Case("migrations chain from the stored version", function(T: Case)
	local Store = Held(T, CHAIN)
	Store:Write("migratechain", { Snapshot = { Gold = 7 }, Ops = {}, Version = 1 })

	local Active: any = Store:Session("migratechain")

	T:Is("gold after only the steps past the stored version ran", Active:Get().Gold, 70)
end)

Cases.Case("compaction stamps the version it wrote", function(T: Case)
	local Store = Held(T, RENAME)
	Store:Write("migratestamp", { Snapshot = { Coins = 5 }, Ops = {} })

	Store:Log():Compact("migratestamp", Store:Format())
	local Record = Store:Record("migratestamp")
	local Snapshot: any = Record.Snapshot

	T:Is("the stamped version", Record.Version, 1)
	T:Is("the stamped floor", Record.Floor, 1)
	T:Is("the renamed field in the snapshot", Snapshot.Gold, 5)
	T:Is("the old field in the snapshot", Snapshot.Coins, nil)
	T:Is("rehydrating the compacted record again", (Store:Format():Rehydrate(Record) :: any).Gold, 5)
end)

Cases.Case("a record from a compatible future version still loads", function(T: Case)
	local Store = Held(T, RENAME)
	Store:Write("migratecompat", { Snapshot = { Gold = 5 }, Ops = {}, Version = 2, Floor = 1 })

	local Active: any = Store:Session("migratecompat")

	T:Is("gold", Active:Get().Gold, 5)
	T:Is("the old field", Active:Get().Coins, nil)
end)

Cases.Case("compacting a future record keeps its version", function(T: Case)
	local Store = Held(T, RENAME)
	Store:Write("migkeep", { Snapshot = { Gold = 5 }, Ops = {}, Version = 2, Floor = 1 })

	Store:Log():Compact("migkeep", Store:Format())
	local Record = Store:Record("migkeep")
	local Snapshot: any = Record.Snapshot

	T:Is("the version an older server wrote back", Record.Version, 2)
	T:Is("the floor", Record.Floor, 1)
	T:Is("gold", Snapshot.Gold, 5)
end)

Cases.Case("a record from an incompatible future is refused", function(T: Case)
	local Store = Held(T, RENAME)
	Store:Write("migratefuture", { Snapshot = { Gold = 1 }, Ops = {}, Version = 5 })

	local Active, Why = Store:TrySession("migratefuture")
	local Record = Store:Record("migratefuture")

	T:Throws("rehydrating a record from a newer format", function()
		Store:Format():Rehydrate(Record)
	end)
	T:Is("the session handed back", Active, nil)
	T:Is("why the load could not go ahead", Why, "Behind")
end)

Cases.Case("preparing a leg leaves the stored snapshot unmigrated", function(T: Case)
	local Store = Held(T, RENAME)
	Store:Write("prepmig", { Snapshot = { Coins = 55 }, Ops = {} })

	local Leg: any = { Id = "leg:prepmig", Kind = "Keep", Tx = "tx:prepmig", TxHome = "Home" }
	local Verdict = Store:Log():Prepare("prepmig", Leg, Store:Format())

	local Record = Store:Record("prepmig")
	local Snapshot: any = Record.Snapshot

	T:Is("the verdict", Verdict, "Prepared")
	T:Is("the stored snapshot was migrated by a prepare", Snapshot.Coins, 55)
	T:Is("a migrated field appeared on disk", Snapshot.Gold, nil)
	T:Is("a version was stamped by a prepare", Record.Version, nil)

	local State: any = Store:Format():Rehydrate(Store:Record("prepmig"))
	T:Is("reading it back still migrates", State.Gold, 55)
end)

Cases.Case("a reset payload is migrated by a server that knows more", function(T: Case)
	local Older = Resettable(T, {}, "CaseResetLadder")

	Older.Store:Edit("ladder", "Add", { Amount = 25 }):Wait()
	Older.Store:Reset("ladder"):Wait()

	local Plain = Resettable(T, {}, "CaseResetPlain")
	Plain.Store:Edit("ladder", "Add", { Amount = 25 }):Wait()
	Plain:Log():Compact("ladder", Plain:Format())

	local Newer = Resettable(T, TENFOLD, "CaseResetLadder")
	local Control = Resettable(T, TENFOLD, "CaseResetPlain")

	T:Is("gold the server that wrote the reset reads", Older:Amount("ladder"), 100)
	T:Is("gold once a server with the migration folds that reset", Newer:Amount("ladder"), 1000)
	T:Is("the same migration on a snapshot that was never reset", Control:Amount("ladder"), 1250)
end)

Cases.Case("a reset from an incompatible future is ignored", function(T: Case)
	local Store = Resettable(T, { BUMP })

	Store.Store:Edit("future", "Add", { Amount = 25 }):Wait()
	Store:Append("future", { ResetOp("reset:future", { Gold = 0, Shape = "new" }, 5, 5) })

	local State: any = Store:State("future")

	T:Is("gold, the reset was ignored", State.Gold, 125)
	T:Is("a field only the newer format knows", State.Shape, nil)
end)

Cases.Case("a reset from a compatible future applies", function(T: Case)
	local Store = Resettable(T, { BUMP })

	Store.Store:Edit("compatfuture", "Add", { Amount = 25 }):Wait()
	Store:Append("compatfuture", { ResetOp("reset:compat", { Gold = 7 }, 5, 1) })

	T:Is("gold", Store:Amount("compatfuture"), 7)
end)

Cases.Case("a reset with no version stamp still applies", function(T: Case)
	local Store = Resettable(T, { BUMP })

	Store.Store:Edit("legacy", "Add", { Amount = 25 }):Wait()
	Store:Append("legacy", { ResetOp("reset:legacy", { Gold = 3 }) })

	T:Is("gold", Store:Amount("legacy"), 3)
end)

Cases.Case("a reset stamps the version of the server that wrote it", function(T: Case)
	local Plain = Resettable(T, { BUMP }, "CaseOneStep")
	local Mixed = Resettable(T, { BUMP, COMPATIBLE }, "CaseTwoStep")

	Plain.Store:Reset("stamped"):Wait()
	Mixed.Store:Reset("stamped"):Wait()

	local function StampOf(Store: Fixture): any
		for _, Op in Store:Record("stamped").Ops do
			if Op.Kind == "__Reset" then
				return Op
			end
		end
		return nil
	end

	local First, Second = StampOf(Plain), StampOf(Mixed)

	T:Is("the one step server wrote a reset", First ~= nil, true)
	T:Is("its version", if First then First.Version else nil, 1)
	T:Is("its floor", if First then First.Floor else nil, 1)
	T:Is("the two step server wrote a reset", Second ~= nil, true)
	T:Is("the two step version", if Second then Second.Version else nil, 2)
	T:Is("its floor, unmoved by a compatible step", if Second then Second.Floor else nil, 1)
end)

Cases.Case("every write leaves a readable version", function(T: Case)
	local Store = T:Store({ Default = { Gold = 0 }, Reducer = Adder })
	Store:Append("rechist", { NewOp.New("Add", { Amount = 1 }) })
	Store:Append("rechist", { NewOp.New("Add", { Amount = 2 }) })

	local Ok, Pages = Store.Store.Wrapper:ListVersionsAsync("rechist", Enum.SortDirection.Descending, nil, nil, 10)
	local Count, Newest = 0, nil :: any
	if Ok then
		for _, Info in (Pages :: any):GetCurrentPage() do
			Count += 1
			Newest = Newest or Info
		end
	end

	T:Is("listing versions", Ok, true)
	T:Is("at least one version is listed", Count >= 1, true)
	T:Is("the newest has a version string", if Newest then type(Newest.Version) else nil, "string")
	T:Is("it carries a creation time", if Newest then Newest.CreatedTime > 0 else nil, true)
end)

Cases.Case("an old version folds to what it held then", function(T: Case)
	local Store = T:Store({ Default = { Gold = 0 }, Reducer = Adder })
	Store:Append("recpeek", { NewOp.New("Add", { Amount = 1 }) })
	Store:Append("recpeek", { NewOp.New("Add", { Amount = 2 }) })

	local Ok, Pages = Store.Store.Wrapper:ListVersionsAsync("recpeek", Enum.SortDirection.Descending, nil, nil, 10)
	T:Is("listing versions", Ok, true)
	if not Ok then
		return
	end

	local Newest: any = (Pages :: any):GetCurrentPage()[1]
	local Format = Store:Format()
	local Versioned = Format:Fold(Store:Log():ReadVersion("recpeek", Newest.Version))
	local Current = Store:Stored("recpeek")

	T:Is("gold now", Current.Gold, 3)
	T:Is("gold at the newest stored version", Versioned.Gold, Current.Gold)
end)

Cases.Case("a record from a newer envelope is refused", function(T: Case)
	local Store = T:Store({ Default = { Gold = 0 }, Reducer = Adder })
	Store:Write("recenv", { Envelope = 2, Snapshot = { Gold = 1 }, Ops = {} })

	T:Throws("reading a record from a newer envelope", function()
		Store:Log():Read("recenv")
	end)

	local Active, Why = Store:TrySession("recenv")
	T:Is("the session handed back", Active, nil)
	T:Is("why the load could not go ahead", Why, "Behind")
end)

Cases.Case("a reducer that freezes its own result still gets a deep freeze", function(T: Case)
	local Leaked: any = nil
	local function Sealing(State: any, Op: any): any?
		if Op.Kind ~= "Add" then
			return nil
		end
		local Bag = { Swords = (State.Bag.Swords or 0) + Op.Amount }
		Leaked = Bag
		return table.freeze({ Gold = State.Gold, Bag = Bag })
	end

	local Store = T:Store({ Default = { Gold = 0, Bag = {} }, Reducer = Sealing, Data = "CaseSeal" })
	local Active: any = Store:Session("sealed")

	Active:Apply("Add", { Amount = 1 })
	local State: any = Active:Get()

	T:Is("the state a reducer froze itself", table.isfrozen(State), true)
	T:Throws("writing a nested field of it", function()
		State.Bag.Swords = 999
	end)
	T:Throws("writing through the table the reducer kept a handle on", function()
		Leaked.Swords = 999
	end)
	T:Is("swords after one apply", Active:Get().Bag.Swords, 1)
end)

Cases.Case("the state a session hands out cannot be edited", function(T: Case)
	local Store = T:Store({ Default = { Gold = 0, Bag = {} }, Reducer = Adder })
	Store:Write("recfroze", { Snapshot = { Gold = 5, Bag = { Swords = 1 } }, Ops = {} })

	local Active: any = Store:Session("recfroze")
	local State: any = Active:Get()

	T:Throws("writing a top level field", function()
		State.Gold = 999
	end)
	T:Throws("writing a nested field", function()
		State.Bag.Swords = 999
	end)
	T:Is("applying through the session still works", Active:Apply("Add", { Amount = 1 }), true)
	T:Is("gold after the apply", Active:Get().Gold, 6)
	T:Holds("freezing an already frozen table", function()
		TableUtil.DeepFreeze(TableUtil.DeepFreeze({ Inner = { 1 } }))
	end)
end)

Cases.Case("missing default keys are filled and stored values win", function(T: Case)
	local Store = T:Store({ Default = { Gold = 100, Gems = 7 }, Reducer = Keep })
	Store:Write("reconcile", { Snapshot = { Gold = 50 }, Ops = {} })

	local Active: any = Store:Session("reconcile")
	local State = Active:Get()

	T:Is("the stored value wins", State.Gold, 50)
	T:Is("the missing default is filled in", State.Gems, 7)
end)

Cases.Case("a default added later appears on an old record", function(T: Case)
	local function Settings(State: any, Op: any): any?
		if Op.Kind == "Add" then
			return { Gold = State.Gold + Op.Amount, N = State.N + 1, Settings = State.Settings }
		elseif Op.Kind == "SetVol" then
			local Next = table.clone(State)
			Next.Settings = table.clone(State.Settings)
			Next.Settings.Volume = Op.Amount
			return Next
		end
		return nil
	end

	local Plain = T:Store({ Default = { Gold = 0, N = 0 }, Reducer = Settings })
	Plain:Append("mig", { NewOp.New("Add", { Amount = 100 }) })
	Plain:Log():Compact("mig", Plain:Format())

	local Active: any = Session.Load(Plain:Log(), Schema.New(Settings, { Gold = 0, N = 0, Settings = { Volume = 5 } }), "mig"):Wait()
	local Had = Active:Get().Settings ~= nil
	local Applied = Active:Apply("SetVol", { Amount = 10 })
	Active:Flush():Wait()

	local Live: any = Active:Get().Settings

	T:Is("the newly defaulted field is there on load", Had, true)
	T:Is("an edit to it", Applied, true)
	T:Is("its value", if Live then Live.Volume else nil, 10)
end)

Cases.Case("an array is never backfilled from the default", function(T: Case)
	local Default: any = { Hotbar = { "A", "B", "C" }, Coins = 5 }
	local Stored: any = { Hotbar = { "X" } }
	Reconcile(Default, Stored)

	T:Is("how many entries the stored array kept", #Stored.Hotbar, 1)
	T:Is("the entry it kept", Stored.Hotbar[1], "X")
	T:Is("a missing scalar was filled in", Stored.Coins, 5)
end)

Cases.Case("numbers are sized by their digits", function(T: Case)
	T:Is("5", Measure(5), 1)
	T:Is("0", Measure(0), 1)
	T:Is("-42", Measure(-42), 3)
	T:Is("1234567890", Measure(1234567890), 10)
	T:Is("1234567890123", Measure(1234567890123), 13)
	T:Is("0.5 is at least three bytes", Measure(0.5) >= 3, true)
end)

Cases.Case("sizing is conservative about escapes", function(T: Case)
	T:Is("a plain string", Measure("abc"), 5)
	T:Is("a hundred quotes", Measure(string.rep('"', 100)), 202)
	T:Is("a hundred control bytes", Measure(string.rep("\1", 100)), 602)
	T:Is("a boolean", Measure(false), 5)
	T:Is("a small table", Measure({ a = "x" }) >= 9, true)
end)

Cases.Case("sizing is never below what json actually takes", function(T: Case)
	local Record = {
		Snapshot = { Gold = 5, Name = "abc", Flag = true, Nested = { List = { 1, 22, 333 } } },
		Ops = { { Id = "op:1", Kind = "Add", Amount = 250 } },
		Seen = { "a\nb", 'quo"te', "plain" },
	}

	T:Is("the estimate against real json", Measure(Record) >= #HttpService:JSONEncode(Record), true)
end)

Cases.Case("a migration cannot take Ledger's own bookkeeping with it", function(T: Case)
	local Store = T:Store({
		Default = Reducers.MONEY,
		Reducer = Reducers.Banker,
		Balance = "Gold",
		Migrations = {
			function(State: any): any
				return { Gold = State.Gold, Touches = State.Touches }
			end,
		},
	})

	Store:Seed("kept", {
		Gold = 100,
		Touches = 0,
		_Held = { held1 = { To = "elsewhere", Amount = 40, At = T:Now() } },
		_Received = { ["t:paid1"] = T:Now() },
	})

	local Now = Store:State("kept")

	T:Is("the gold the migration was free to rewrite", Now.Gold, 100)
	T:Is("the money set aside, which it may not take with it", Store:Aside("kept"), 40)
	T:Is("the applied name it may not take either", Store:Names("kept")["t:paid1"] ~= nil, true)
	T:Accuses("it named what the migration dropped", "dropped Ledger's own")
end)

return Cases
