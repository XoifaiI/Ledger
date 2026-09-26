--!strict
--!optimize 2

--[=[

	Logs: One rule per case for the op log itself.

	Reading a record, what a junk one folds to, and appending the same op twice. Then compaction:
	which ops it may absorb, which it must keep, and what it leaves behind.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau
--]=]

local Suite = require("../Suite")

local Windows = require("../../src/Core/Constants/Windows")
local Fold = require("../../src/Record/Fold")
local Log = require("../../src/Record/Log")
local NewOp = require("../../src/Record/NewOp")
local Rules = require("../../src/Record/Rules")
local Schema = require("../../src/Record/Schema")
local Sizes = require("../../src/Core/Constants/Sizes")
local Tags = require("../../src/Core/Constants/Tags")
local Transform = require("../../src/Record/Transform")
local TxStamp = require("../../src/Record/TxStamp")

local Fault = Suite.Fault

type Case = Suite.Case
type Fixture = Suite.Fixture

local COUNTED: any = { Gold = 0, N = 0 }

local Cases = Suite.File("Logs")

local function Crafter(State: any, Op: any): any?
	if Op.Kind ~= "Craft" then
		return Suite.Reducers.Banker(State, Op)
	end

	local Gold = State.Gold + Op.Amount
	if Gold < 0 then
		return nil
	end
	return { Gold = Gold, Touches = State.Touches }
end

local function Counter(State: any, Op: any): any?
	if Op.Kind == "Add" then
		return { Gold = State.Gold + Op.Amount, N = State.N + 1 }
	elseif Op.Kind == "Spend" then
		if Op.Amount > State.Gold then
			return nil
		end
		return { Gold = State.Gold - Op.Amount, N = State.N + 1 }
	end
	return nil
end

local function Ledgered(T: Case, Reducer: any?, Node: string?): Fixture
	return T:Store({ Default = COUNTED, Reducer = Reducer or Counter, Node = Node })
end

local function Canon(Value: any): string
	local Kind = type(Value)
	if Kind ~= "table" then
		return if Kind == "string" then `"{Value}"` else tostring(Value)
	end

	local Keys: { any } = {}
	for Key in Value do
		table.insert(Keys, Key)
	end
	table.sort(Keys, function(A: any, B: any): boolean
		return tostring(A) < tostring(B)
	end)

	local Parts: { string } = {}
	for _, Key in Keys do
		table.insert(Parts, `{tostring(Key)}={Canon(Value[Key])}`)
	end
	return `\{{table.concat(Parts, ",")}\}`
end

local APPENDED = `\{Bytes=16,Envelope=2,Ops=\{1=\{Amount=5,Id="v2case00000000:1",Kind="Add"\},2=\{Amount=7,Id="v2case00000000:2",Kind="Add"\}\},Seen=\{\},Snapshot=\{Gold=0,N=0\},Version=0\}`
local COMPACTED = `\{Absorbed=\{1=\{At=1700000000,Count=2\}\},Bytes=17,Envelope=2,Floor=0,Ops=\{\},Seen=\{1="v2case00000000:1",2="v2case00000000:2"\},Snapshot=\{Gold=12,N=2\},Version=0\}`

Cases.Case("a reducer cannot write into the snapshot a fold starts from", function(T: Case)
	local Store = T:Store({
		Default = { Gold = 10 },
		Reducer = function(State: any, Op: any): any?
			if Op.Kind == "Sneak" then
				State.Gold = 999
				return table.clone(State)
			end
			if Op.Kind == "Add" then
				local Next = table.clone(State)
				Next.Gold += 1
				return Next
			end
			return nil
		end,
	})

	Store.Store:Edit("k", "Add"):Wait()
	Store.Store:Edit("k", "Add"):Wait()
	Store:Log():Compact("k", Store:Format())

	local Ok, Why = Store.Store:Edit("k", "Sneak"):Wait()
	T:Is("an edit whose reducer wrote into the snapshot", Ok, false)
	T:Is("the reason it gives", Why, "Refused")
	T:Is("gold once the write was turned away", Store:Amount("k"), 12)
end)

Cases.Case("a stored record has exactly the shape its envelope promises", function(T: Case)
	local Store = Ledgered(T)
	Store.Store:Edit("g", "Add", { Amount = 5 }):Wait()
	Store.Store:Edit("g", "Add", { Amount = 7 }):Wait()

	T:Is("the record a write leaves behind", Canon(Store:Record("g")), APPENDED)

	Store:Log():Compact("g", Store:Format())
	T:Is("the record a compaction leaves behind", Canon(Store:Record("g")), COMPACTED)
end)

Cases.Case("concurrent appends never lose or duplicate an op", function(T: Case)
	local Store = Ledgered(T)
	local Accepted: { [string]: boolean } = {}
	local Failed = 0

	local Thunks: { () -> () } = {}
	for Server = 1, 3 do
		table.insert(Thunks, function()
			for Index = 1, 3 do
				local Op = NewOp.New("Add", { Amount = 1, Server = Server, Index = Index })
				local Fine = pcall(function()
					Store:Log():Append("appendk", { Op })
				end)
				if Fine then
					Accepted[Op.Id] = true
				else
					Failed += 1
				end
			end
		end)
	end
	T:Race(Thunks)

	local Stored: { [string]: boolean } = {}
	local Doubled = 0
	for _, Op in Store:Record("appendk").Ops do
		if Stored[Op.Id] then
			Doubled += 1
		end
		Stored[Op.Id] = true
	end

	local Lost = 0
	for Id in Accepted do
		if not Stored[Id] then
			Lost += 1
		end
	end

	T:Is("ops the log accepted and then lost", Lost, 0)
	T:Is("ops stored twice", Doubled, 0)
	T:Is("every append was accepted", Failed, 0)
end)

Cases.Case("only one of many concurrent spends can take", function(T: Case)
	local Store = Ledgered(T)
	Store:Log():Append("overdraft", { NewOp.New("Add", { Amount = 100 }) })

	local Thunks: { () -> () } = {}
	for _ = 1, 6 do
		table.insert(Thunks, function()
			pcall(function()
				Store:Log():Append("overdraft", { NewOp.New("Spend", { Amount = 100 }) })
			end)
		end)
	end
	T:Race(Thunks)

	local Folded = Store:Stored("overdraft")

	T:Is("gold once six racing spends of the whole balance are folded", Folded.Gold, 0)
	T:Is("how many of them the reducer took", Folded.N - 1, 1)
end)

Cases.Case("the same op appended concurrently lands once", function(T: Case)
	local Store = Ledgered(T)
	local Op = NewOp.New("Add", { Amount = 1 })

	local Thunks: { () -> () } = {}
	for _ = 1, 3 do
		table.insert(Thunks, function()
			pcall(function()
				Store:Log():Append("idem", { Op })
			end)
		end)
	end
	T:Race(Thunks)
	pcall(function()
		Store:Log():Append("idem", { Op })
	end)

	local Count = 0
	for _, Stored in Store:Record("idem").Ops do
		if Stored.Id == Op.Id then
			Count += 1
		end
	end

	T:Is("how many times one op id is stored", Count, 1)
	T:Is("gold", Store:Stored("idem").Gold, 1)
end)

Cases.Case("compaction racing appends loses nothing", function(T: Case)
	local Store = Ledgered(T)
	local Landed = 0

	for _ = 1, 3 do
		local Thunks: { () -> () } = {
			function()
				pcall(function()
					Store:Log():Compact("compactrace", Store:Format())
				end)
			end,
		}
		for _ = 1, 3 do
			table.insert(Thunks, function()
				local Fine = pcall(function()
					Store:Log():Append("compactrace", { NewOp.New("Add", { Amount = 1 }) })
				end)
				if Fine then
					Landed += 1
				end
			end)
		end
		T:Race(Thunks)
	end

	T:Is("gold after compaction raced nine appends", Store:Stored("compactrace").Gold, Landed)
end)

Cases.Case("folding the same log always gives the same answer", function(T: Case)
	local Store = Ledgered(T)
	local Rng = Random.new(99)

	for _ = 1, 12 do
		local Kind = if Rng:NextNumber() < 0.5 then "Add" else "Spend"
		Store:Log():Append("determ", { NewOp.New(Kind, { Amount = Rng:NextInteger(1, 30) }) })
	end

	local First = Fold(COUNTED, Store:Record("determ").Ops, Counter)
	local Mismatches = 0
	for _ = 1, 8 do
		local Again = Fold(COUNTED, Store:Record("determ").Ops, Counter)
		if Again.Gold ~= First.Gold or Again.N ~= First.N then
			Mismatches += 1
		end
	end

	T:Is("folds of one log that disagreed", Mismatches, 0)
end)

Cases.Case("compaction keeps every id of an oversized batch", function(T: Case)
	local Store = Ledgered(T)

	local Batch: { any } = {}
	for Index = 1, 2100 do
		table.insert(Batch, { Id = `op:{Index}`, Kind = "Add", Amount = 0 })
	end
	Store:Log():Append("seenbatch", Batch)
	Store:Log():Compact("seenbatch", Store:Format())

	T:Is("ids kept in Seen after compacting a 2100 op batch", #Store:Record("seenbatch").Seen >= 2100, true)
end)

Cases.Case("retiring a leg neither grows nor touches Seen", function(T: Case)
	local Store = Ledgered(T)
	local Leg = "tx:seenboundtx:1"

	local Seen: { string } = table.create(3000, "")
	for Index = 1, 3000 do
		Seen[Index] = `old:{Index}`
	end
	Store:Write("seenbound", { Ops = { { Id = Leg, Kind = "Add", Amount = 1, Tx = "seenboundtx" } }, Seen = Seen })

	local Resolved = Store:Log():Resolve("seenbound", { seenboundtx = { Commit = false } })

	local Retired = false
	for _, Id in Resolved.Record.Seen do
		if Id == Leg then
			Retired = true
		end
	end

	T:Is("a rolled back leg written into Seen", Retired, false)
	T:Is("the size of Seen after a rollback", #Resolved.Record.Seen, 3000)
	T:Is("anything left pending", TxStamp.HasPending(Resolved.Record), false)
end)

Cases.Case("Prepare refuses a reducer that does not return state", function(T: Case)
	local function Bad(): any?
		return true
	end

	local Store = Ledgered(T, Bad)
	local Op: any = { Id = "leg1", Kind = "Delta", Tx = "tx1", TxHome = "Home" }
	local Verdict = Store:Log():Prepare("preptable", Op, Schema.New(Bad, COUNTED))

	T:Is("preparing against a reducer that returns a boolean", Verdict, "Rejected")
	T:Is("ops left on the key", #Store:Record("preptable").Ops, 0)
end)

Cases.Case("a junk snapshot is dropped rather than folded", function(T: Case)
	local Store = Ledgered(T)
	Store:Write("junksnap", { Snapshot = "corrupted", Ops = {}, Seen = {} })

	local Folded = Store:Stored("junksnap")

	T:Is("a snapshot that is not a table", Store:Record("junksnap").Snapshot, nil)
	T:Is("gold", Folded.Gold, 0)
	T:Is("the op count", Folded.N, 0)
end)

Cases.Case("ops the datastore cannot describe are dropped", function(T: Case)
	local Store = Ledgered(T)
	Store:Write("poison", {
		Ops = {
			{ Id = "good", Kind = "Add", Amount = 5 },
			{ Id = "nokind", Amount = 9 },
			{ Id = "numtx", Kind = "Add", Amount = 9, Tx = 7 },
			{ Kind = "Add", Amount = 9 },
		},
		Seen = {},
	})

	local Record = Store:Record("poison")
	local Kept: { [string]: boolean } = {}
	for _, Op in Record.Ops do
		Kept[Op.Id] = true
	end

	T:Is("ops kept from a poisoned record", #Record.Ops, 1)
	T:Is("the good one survived", Kept["good"], true)
	T:Is("the one with no kind", Kept["nokind"], nil)
	T:Is("the one whose Tx is a number", Kept["numtx"], nil)
end)

Cases.Case("compaction refuses a state with a gap in an array", function(T: Case)
	local function Gappy(Current: any, Op: any): any?
		if Op.Kind ~= "Gap" then
			return Counter(Current, Op)
		end
		local Items = { "a", "b" }
		Items[9] = "far"
		return { Gold = Current.Gold, N = Current.N + 1, Items = Items }
	end

	local Store = Ledgered(T, Gappy)
	Store:Log():Append("gappy", { NewOp.New("Add", { Amount = 1 }) })
	Store:Log():Append("gappy", { NewOp.New("Gap") })

	Store:Log():Compact("gappy", Schema.New(Gappy, COUNTED))

	local Record = Store:Record("gappy")
	T:Is("the snapshot is still the base the first write stored", Record.Snapshot.N, 0)
	T:Is("the log is kept as it was", #Record.Ops, 2)
	T:Warns("it said why", "cannot be compacted")
	T:Warns("it named the sparse array", "sparse array")
end)

Cases.Case("compaction refuses a state mixing array and string keys", function(T: Case)
	local function Mixed(Current: any, Op: any): any?
		if Op.Kind ~= "Mix" then
			return Counter(Current, Op)
		end
		local Bag: any = { "one" }
		Bag.Named = true
		return { Gold = Current.Gold, N = Current.N + 1, Bag = Bag }
	end

	local Store = Ledgered(T, Mixed)
	Store:Log():Append("mixedkeys", { NewOp.New("Mix") })

	Store:Log():Compact("mixedkeys", Schema.New(Mixed, COUNTED))

	local Record = Store:Record("mixedkeys")
	T:Is("the snapshot is still the base the first write stored", Record.Snapshot.N, 0)
	T:Is("the log is kept as it was", #Record.Ops, 1)
	T:Warns("it named the mixed keys", "mixes array and string keys")
end)

Cases.Case("Trim compacts only an overgrown log", function(T: Case)
	local Store = Ledgered(T)

	Store:Log():Append("trimsmall", { NewOp.New("Add", { Amount = 1 }) })
	local Left = Store:Log():Trim("trimsmall", Store:Format(), Store:Record("trimsmall"))

	T:Is("ops left on a short log", #Left.Ops, 1)
	T:Is("the snapshot of a short log is still the base the first write stored", Store:Record("trimsmall").Snapshot.Gold, 0)

	local Bulk: { any } = {}
	for _ = 1, 130 do
		table.insert(Bulk, NewOp.New("Add", { Amount = 1 }))
	end
	Store:Log():Append("trimbig", Bulk)

	local Packed = Store:Log():Trim("trimbig", Store:Format(), Store:Record("trimbig"))
	local Snapshot: any = Packed.Snapshot

	T:Is("ops left once an overgrown log is trimmed", #Packed.Ops, 0)
	T:Is("gold in the snapshot it wrote", if Snapshot then Snapshot.Gold else nil, 130)
end)

Cases.Case("an older build cannot compact away a kind it does not know", function(T: Case)
	local Badged: any = { Gold = 0, Badge = "" }

	local function Older(State: any, Op: any): any?
		if Op.Kind ~= "Fund" then
			return nil
		end
		return { Gold = State.Gold + Op.Amount, Badge = State.Badge }
	end
	local function Newer(State: any, Op: any): any?
		if Op.Kind == "Fund" then
			return { Gold = State.Gold + Op.Amount, Badge = State.Badge }
		elseif Op.Kind == "Bonus" then
			return { Gold = State.Gold + 500, Badge = Op.Badge }
		end
		return nil
	end

	local Store = T:Store({ Default = Badged, Reducer = Newer })
	local Ahead = Store:Format()
	local Behind = Schema.New(Older, Store.Store.Initial, {})

	Store.Store:Edit("deploy", "Fund", { Amount = 100 }):Wait()
	local Granted = Store.Store:Edit("deploy", "Bonus", { Badge = "founder" }):Wait()
	Store.Store:Edit("deploy", "Fund", { Amount = 40 }):Wait()

	local Before: any = Ahead:Fold(Store:Record("deploy"))
	Store:Log():Compact("deploy", Behind)
	local After: any = Ahead:Fold(Store:Record("deploy"))

	local Kinds: { string } = {}
	for _, Op in Store:Record("deploy").Ops do
		table.insert(Kinds, Op.Kind)
	end

	T:Is("the write the newer build answered true to", Granted, true)
	T:Is("gold before an older build compacted", Before.Gold, 640)
	T:Is("gold after it", After.Gold, 640)
	T:Is("the badge it granted", After.Badge, "founder")
	T:Is("what is held back for a build that knows the kind", table.concat(Kinds, ","), "Bonus,Fund")
end)

Cases.Case("a kind both builds know is still not absorbed on a refusal", function(T: Case)
	local function Older(State: any, Op: any): any?
		if Op.Kind ~= "Spend" or State.Gold < Op.Amount then
			return nil
		end
		local Next = table.clone(State)
		Next.Gold -= Op.Amount
		return Next
	end
	local function Newer(State: any, Op: any): any?
		if Op.Kind ~= "Spend" then
			return nil
		end
		if Op.Voucher ~= true and State.Gold < Op.Amount then
			return nil
		end
		local Next = table.clone(State)
		Next.Gold -= (if Op.Voucher then 0 else Op.Amount)
		Next.Unlocked = true
		return Next
	end

	local Store = T:Store({ Default = { Gold = 0, Unlocked = false }, Reducer = Newer })
	local Behind = Schema.New(Older, Store.Store.Initial, {})

	local Granted = Store.Store:Edit("shared", "Spend", { Amount = 100, Voucher = true }):Wait()
	Store:Log():Compact("shared", Behind)
	local After: any = Store:Stored("shared")

	T:Is("the newer build granting it", Granted, true)
	T:Is("the unlock, after an older build compacted the key", After.Unlocked, true)
	T:Is("the op it could not account for, held back", #Store:Record("shared").Ops, 1)
end)

Cases.Case("compacting never moves a refused op behind a later one", function(T: Case)
	local Store = Ledgered(T)

	Store.Store:Edit("reorder", "Spend", { Amount = 50 }):Wait()
	Store.Store:Edit("reorder", "Add", { Amount = 200 }):Wait()

	local Before: any = Store:Stored("reorder")
	Store:Log():Compact("reorder", Store:Format())
	local After: any = Store:Stored("reorder")

	T:Is("gold before compaction, the spend having been refused", Before.Gold, 200)
	T:Is("gold after it, with the spend not replayed onto the funded balance", After.Gold, 200)
end)

Cases.Case("a settled Once name is still absorbed by compaction", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("retried", { Gold = 0 })

	for _ = 1, 60 do
		Bank.Store:Edit("retried", "Fund", { Amount = 1, Once = "same" }):Wait()
	end

	Bank:Log():Compact("retried", Bank:Format())

	T:Is("ops left after sixty retries of one name", #Bank:Record("retried").Ops, 0)
	T:Is("gold, having applied once", Bank:Amount("retried"), 1)
end)

Cases.Case("an edit the reducer refuses never reaches the log", function(T: Case)
	local Store = Ledgered(T)

	local Ok, Why = Store.Store:Edit("refused", "Spend", { Amount = 50 }):Wait()
	local Bare = #Store:Record("refused").Ops

	for _ = 1, 200 do
		Store.Store:Edit("refused", "Add", { Amount = 1 }):Wait()
		Store:Log():Trim("refused", Store:Format(), Store:Record("refused"))
	end
	local Record = Store:Record("refused")

	T:Is("an edit the reducer turned down", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("ops it left behind", Bare, 0)
	T:Is("the key still compacting afterwards", Record.Snapshot ~= nil, true)
	T:Is("ops left after two hundred more edits", #Record.Ops < 130, true)
	T:Is("gold, counting only what applied", Store:Stored("refused").Gold, 200)
end)

Cases.Case("a refusal while a transaction is parked is still written", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("parked", { Gold = 0 })

	Bank:Marker("hold1", { Status = "Pending", Total = 2, Gen = "one", Adopted = {} })
	Bank:Park("parked", { Id = "tx:hold1:1", Kind = "Fund", Amount = 500, Tx = "hold1" })

	local Ok, Why = Bank.Store:Edit("parked", "Give", { Amount = -100 }):Wait()

	local Carried = false
	for _, Op in Bank:Record("parked").Ops do
		if Op.Kind == "Give" then
			Carried = true
		end
	end

	T:Is("an edit that only holds if the parked leg commits", Ok, false)
	T:Is("the reason, which leaves it open", Why, "Unresolved")
	T:Is("the op, kept so the leg can still decide it", Carried, true)
end)

Cases.Case("an apply that only holds if the parked leg commits leaves it open", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("parkedlive", { Gold = 0 })

	Bank:Marker("hold3", { Status = "Pending", Total = 2, Gen = "one", Adopted = {} })
	Bank:Park("parkedlive", { Id = "tx:hold3:1", Kind = "Fund", Amount = 500, Tx = "hold3" })

	local Active: any = Bank:Session("parkedlive")
	local Ok, Why = Active:Apply("Give", { Amount = -100 })

	T:Is("the leg the session found parked", Active.Parked, 1)
	T:Is("an apply that only holds if the parked leg commits", Ok, false)
	T:Is("the reason, which leaves it open", Why, "Unresolved")
end)

Cases.Case("an op that holds no way is not written while a leg is parked", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 10 })

	Bank:Park("a", {
		Id = "tx:barrier:1",
		Kind = "Give",
		Amount = 1,
		Tx = "barrier",
		TxGen = "barriergen",
		TxAt = T:Now(),
		TxTerms = "barrierterms",
		TxSticky = "barrier",
	})

	local Wrote = Bank.Store:Edit("a", "Give", { Amount = -999 }):Wait()

	Bank:Log():Resolve("a", { barrier = { Commit = false, Gen = "barriergen", Since = T:Now() } })

	for _ = 1, 4 do
		Bank.Store:Edit("a", "Give", { Amount = 1 }):Wait()
		Bank:Log():Compact("a", Bank:Format())
	end

	T:Is("the op that holds no way", Wrote, false)
	T:Is("ops left after four compactions", #Bank:Record("a").Ops, 0)
	T:Is("gold", Bank:Amount("a"), 14)
end)

Cases.Case("an op taken in for a leg that aborted stops holding the log open", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("wedge", { Gold = 100, Touches = 0 })

	Bank:Marker("wedgetx", { Status = "Pending", Total = 2, Gen = "one", At = T:Now(), Adopted = {} })
	Bank:Park("wedge", { Id = "tx:wedgetx:1", Kind = "Fund", Amount = 500, Tx = "wedgetx", TxGen = "one", TxAt = T:Now() })

	local Ok, Why = Bank.Store:Edit("wedge", "Give", { Amount = -120 }):Wait()

	T:Advance(Windows.TX + 1)
	Bank.Store:Resettle("wedge"):Wait()

	for _ = 1, 40 do
		Bank.Store:Edit("wedge", "Fund", { Amount = 1 }):Wait()
	end

	local Before = #Bank:Record("wedge").Ops
	Bank:Log():Compact("wedge", Bank:Format())

	T:Is("the edit that only held if the leg committed", Ok, false)
	T:Is("the reason it gave", Why, "Unresolved")
	T:Is("ops carried before the compaction", Before, 41)
	T:Is("ops left once the leg had aborted and the key compacted", #Bank:Record("wedge").Ops, 0)
	T:Is("gold, counting only what applied", Bank:Amount("wedge"), 140)
	T:Silent("nothing said the key was stuck", "cannot be compacted")
end)

local function Parked(Bank: Fixture, Key: string, Txid: string)
	Bank:Marker(Txid, { Status = "Pending", Total = 2, Gen = `{Txid}gen`, At = 0, Adopted = {} })
	Bank:Park(Key, {
		Id = `tx:{Txid}:1`,
		Kind = "Give",
		Amount = -50,
		Tx = Txid,
		TxGen = `{Txid}gen`,
		TxAt = 0,
		TxTerms = `{Txid}terms`,
		TxSticky = Txid,
	})
end

local function Landed(Record: any, Amount: number): boolean
	for _, Op in Record.Ops do
		if Op.Tx == nil and Op.Amount == Amount then
			return true
		end
	end
	return false
end

Cases.Case("an edit that only holds if the parked leg aborts is not written", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("unless", { Gold = 60, Touches = 0 })
	Parked(Bank, "unless", "takes")

	local Ok, Why = Bank.Store:Edit("unless", "Give", { Amount = -30 }):Wait()
	local Written = Landed(Bank:Record("unless"), -30)

	Bank:Log():Resolve("unless", { takes = { Commit = true, Gen = "takesgen", Since = 1 } })
	for _ = 1, 3 do
		Bank.Store:Edit("unless", "Fund", { Amount = 1 }):Wait()
		Bank:Log():Compact("unless", Bank:Format())
	end

	T:Is("the edit, which held on the plain state only", Ok, false)
	T:Is("the reason, which leaves it open", Why, "Unresolved")
	T:Is("the op, kept out of the log", Written, false)
	T:Is("gold once the leg committed and three funds landed", Bank:Amount("unless"), 13)
	T:Is("ops left after three compactions", #Bank:Record("unless").Ops, 0)
	T:Warns("it said the op only holds if the transaction does not go through", "only holds if it does not go through")
	T:Silent("nothing said the key was stuck", "cannot be compacted")
end)

Cases.Case("an apply that only holds if a leg parked after it aborts waits for the leg to commit", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("waits", { Gold = 60, Touches = 0 })

	local Active: any = Bank:Session("waits")
	local Ok = Active:Apply("Give", { Amount = -30 })
	Parked(Bank, "waits", "later")

	local Flushed = Active:Flush():Wait()
	local Held = #Active.Pending
	local Early = Landed(Bank:Record("waits"), -30)

	Bank:Log():Resolve("waits", { later = { Commit = true, Gen = "latergen", Since = 1 } })
	local Again, Why = Active:Flush():Wait()
	local Folded = Active:Get().Gold
	for _ = 1, 3 do
		Bank.Store:Edit("waits", "Fund", { Amount = 1 }):Wait()
		Bank:Log():Compact("waits", Bank:Format())
	end

	T:Is("the hopeful apply", Ok, true)
	T:Is("the flush while the leg was parked", Flushed, true)
	T:Is("the op, still queued", Held, 1)
	T:Is("the op, kept out of the log meanwhile", Early, false)
	T:Is("the flush once the leg had committed, which turned the op away", Again, false)
	T:Is("the reason", Why, "Refused")
	T:Is("ops still queued", #Active.Pending, 0)
	T:Is("gold the session folds without it", Folded, 10)
	T:Is("gold on disk after three funds", Bank:Amount("waits"), 13)
	T:Is("ops left after three compactions", #Bank:Record("waits").Ops, 0)
	T:Silent("nothing said the key was stuck", "cannot be compacted")
end)

Cases.Case("an apply that only holds if a leg parked after it aborts lands once it does", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("lands", { Gold = 60, Touches = 0 })

	local Active: any = Bank:Session("lands")
	Active:Apply("Give", { Amount = -30 })
	Parked(Bank, "lands", "gone")

	Active:Flush():Wait()
	local Early = Landed(Bank:Record("lands"), -30)

	Bank:Log():Resolve("lands", { gone = { Commit = false, Gen = "gonegen", Since = 1 } })
	local Again = Active:Flush():Wait()

	T:Is("the op, kept out of the log while the leg was parked", Early, false)
	T:Is("the flush once the leg had aborted", Again, true)
	T:Is("the op, landed", Landed(Bank:Record("lands"), -30), true)
	T:Is("gold on disk", Bank:Amount("lands"), 30)
	T:Is("ops still queued", #Active.Pending, 0)
end)

Cases.Case("an op that holds once the leg commits is still written", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	Bank:Park("a", {
		Id = "tx:gate:1",
		Kind = "Give",
		Amount = 100,
		Tx = "gate",
		TxGen = "gategen",
		TxAt = T:Now(),
		TxTerms = "gateterms",
		TxSticky = "gate",
	})

	Bank.Store:Edit("a", "Give", { Amount = -50 }):Wait()

	local Carried = false
	for _, Op in Bank:Record("a").Ops do
		if Op.Tx == nil and Op.Amount == -50 then
			Carried = true
		end
	end

	Bank:Log():Resolve("a", { gate = { Commit = true, Gen = "gategen", Since = T:Now() } })

	T:Is("the op was kept for the commit", Carried, true)
	T:Is("gold once the leg landed", Bank:Amount("a"), 50)
end)

Cases.Case("an op taken in for a leg that committed is kept by a build that cannot apply it", function(T: Case)
	local Newer = T:Store({ Default = Suite.Reducers.MONEY, Reducer = Crafter, Balance = "Gold" })
	local Older = T:Bank()

	Newer:Seed("forge", { Gold = 0, Touches = 0 })
	Newer:Park("forge", {
		Id = "tx:forge:1",
		Kind = "Give",
		Amount = 100,
		Tx = "forge",
		TxGen = "forgegen",
		TxAt = T:Now(),
		TxTerms = "forgeterms",
		TxSticky = "forge",
	})

	local Ok, Why = Newer.Store:Edit("forge", "Craft", { Amount = -50 }):Wait()
	Newer:Log():Resolve("forge", { forge = { Commit = true, Gen = "forgegen", Since = T:Now() } })

	T:No("the craft, which only holds if the leg commits", Ok)
	T:Is("the reason, which leaves it open", Why, "Unresolved")
	T:Is("gold once the leg committed", Newer:Amount("forge"), 50)

	Older:Log():Compact("forge", Older:Format())

	T:Is("gold after an older build compacted the key", Newer:Amount("forge"), 50)
	T:Warns("the older build said what it kept", "this build does not apply")
end)

Cases.Case("an op taken in for two transactions is kept while either of them committed", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("twogates", { Gold = 0, Touches = 0 })

	for _, Held in { { Name = "alpha", Gen = "agen" }, { Name = "bravo", Gen = "bgen" } } do
		Bank:Park("twogates", {
			Id = `tx:{Held.Name}:1`,
			Kind = "Give",
			Amount = 100,
			Tx = Held.Name,
			TxGen = Held.Gen,
			TxAt = T:Now(),
			TxTerms = `{Held.Name}terms`,
			TxSticky = Held.Name,
		})
	end

	Bank.Store:Edit("twogates", "Give", { Amount = -150 }):Wait()
	Bank:Log():Resolve("twogates", {
		alpha = { Commit = true, Gen = "agen", Since = T:Now() },
		bravo = { Commit = false, Gen = "bgen", Since = T:Now() },
	})

	T:Is("gold once one committed and the other went away", Bank:Amount("twogates"), 100)

	Bank:Log():Compact("twogates", Bank:Format())

	local Kept = false
	for _, Op in Bank:Record("twogates").Ops do
		if Op.Amount == -150 then
			Kept = true
		end
	end

	T:Ok("the op, kept because a transaction it was taken in for did commit", Kept)
	T:Is("gold after the compaction", Bank:Amount("twogates"), 100)
	T:Warns("the compaction said what it kept", "kept 1 op(s) through compaction")
end)

Cases.Case("an op an older build marked for a parked transaction is absorbed as before", function(T: Case)
	local Bank = T:Bank()
	Bank:Write("legacy", {
		Snapshot = { Gold = 100, Touches = 0 },
		Ops = { { Id = "legacy1", Kind = "Give", Amount = -999, TxOnly = true } },
		Seen = {},
	})

	Bank:Log():Compact("legacy", Bank:Format())

	T:Is("ops left once the key compacted", #Bank:Record("legacy").Ops, 0)
	T:Is("gold, counting only what applied", Bank:Amount("legacy"), 100)
	T:Silent("nothing said the key was stuck", "cannot be compacted")
end)

Cases.Case("a compaction holds back a reserved kind this build does not handle", function(T: Case)
	local Store = Ledgered(T)

	Store.Store:Edit("hb", "Add", { Amount = 5 }):Wait()
	Store:Append("hb", { { Id = "future1", Kind = "__Nothing", At = 1 } :: any })
	Store.Store:Edit("hb", "Add", { Amount = 7 }):Wait()

	Store:Log():Compact("hb", Store:Format())

	local Record = Store:Record("hb")
	local Kept = false
	for _, Op in Record.Ops do
		if Op.Id == "future1" then
			Kept = true
		end
	end

	local Burned = false
	for _, Id in Record.Seen do
		if Id == "future1" then
			Burned = true
		end
	end

	T:Is("the op a later build still has to apply", Kept, true)
	T:Is("its id being burned into the seen list", Burned, false)
end)

Cases.Case("the build floor decides who may park a leg", function(T: Case)
	local function Step(State: any): any
		return State
	end

	local Store = T:Store({ Migrations = { Step, Step, Step, Step, Step } })
	Store:Seed("floorprep", { Gold = 100, Touches = 0 })

	local Stored = Store:Record("floorprep")
	Stored.Floor = 5
	Store:Write("floorprep", Stored)

	local Leg: any = { Id = "tx:floorprep:1", Kind = "Fund", Amount = 5, Tx = "floorprep", TxHome = "Home" }

	local Behind = Log.New(Store.Store.Wrapper, 0)
	local Ok, Raised = pcall(function()
		return Behind:Prepare("floorprep", Leg, Store:Format())
	end)

	T:Is("an older build parking a leg on a record it may not write", Ok, false)
	T:Is("the reason", if type(Raised) == "table" then (Raised :: any).Why else nil, "Behind")
	T:Is("nothing was parked", Store:Pending("floorprep"), false)

	local Ahead = Log.New(Store.Store.Wrapper, 5)
	T:Is("a build that meets the floor parks it", Ahead:Prepare("floorprep", Leg, Store:Format()), "Prepared")
	T:Is("and the leg is on the key", Store:Pending("floorprep"), true)
end)

Cases.Case("the build floor decides who may resolve a leg", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("floorleg", { Gold = 100 })
	Bank:Park("floorleg", { Id = "tx:floor1:1", Kind = "Give", Amount = -10, Tx = "floor1", TxGen = "g1", TxAt = T:Now() })

	local Stored = Bank:Record("floorleg")
	Stored.Floor = 5
	Bank:Write("floorleg", Stored)

	local Ruling: any = { floor1 = { Commit = false, Gen = "g1", Since = T:Now() } }
	local Behind = Log.New(Bank.Store.Wrapper, 0)

	local Ok, Raised = pcall(function()
		return Behind:Resolve("floorleg", Ruling)
	end)

	T:Is("an older build resolving a leg on a record it may not write", Ok, false)
	T:Is("the reason", if type(Raised) == "table" then (Raised :: any).Why else nil, "Behind")
	T:Is("the leg is left exactly where it was", Bank:Pending("floorleg"), true)

	local Ahead = Log.New(Bank.Store.Wrapper, 5)
	Ahead:Resolve("floorleg", Ruling)

	T:Is("a build that meets the floor settles it", Bank:Pending("floorleg"), false)
	T:Is("and the leg was rolled back rather than applied", #Bank:Record("floorleg").Ops, 0)
end)

local function OnDisk(Held: Fixture, Key: string): boolean
	return (Held.Direct:Current(Key)) ~= nil
end

Cases.Case("a key erased once keeps its record, since the names on it still have to be checked", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("keptrec", { Gold = 100 })
	Bank.Store:Edit("keptrec", "Fund", { Amount = 5, Once = "gift1" }):Wait()

	T:Is("erasing it", (Bank.Store:Erase("keptrec"):Wait()), true)

	T:Is("the record is still on the datastore", OnDisk(Bank, "keptrec"), true)
	T:Is("and it still knows the name it applied", Bank:Knows("keptrec", Tags.ONCE, "gift1"), true)

	T:Advance(Windows.TOMB + 60)

	T:Is("still there once the tomb has run out", OnDisk(Bank, "keptrec"), true)
	T:Is("and still knowing the name, which outlives the tomb", Bank:Knows("keptrec", Tags.ONCE, "gift1"), true)
end)

Cases.Case("erasing a key whose tomb has run out takes its record off the datastore", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("gonerec", { Gold = 100 })

	T:Is("the first erase", (Bank.Store:Erase("gonerec"):Wait()), true)
	T:Is("the record it left behind", OnDisk(Bank, "gonerec"), true)

	T:Advance(Windows.TOMB + 60)

	T:Is("erasing it again once the tomb has run out", (Bank.Store:Erase("gonerec"):Wait()), true)
	T:Is("the record is off the datastore", OnDisk(Bank, "gonerec"), false)
end)

Cases.Case("an edit that meets an erase taking the key off is turned away rather than lost", function(T: Case)
	local Bank = T:Bank("nodeA")
	local Other = T:Bank("nodeB")
	Bank:Seed("leaverec", { Gold = 100 })
	T:Is("the first erase", (Bank.Store:Erase("leaverec"):Wait()), true)
	T:Advance(Windows.TOMB + 60)

	local Late: any = nil
	local Spec = Bank:Fault(Fault.Removes():OnKey("leaverec"):Only(1):Meddle(function()
		Late = table.pack(Other.Store:Edit("leaverec", "Fund", { Amount = 5 }):Wait())
	end))
	T:Is("erasing it again", (Bank.Store:Erase("leaverec"):Wait()), true)
	Bank:Healed()

	T:Is("the edit ran inside the removal", Spec.Fired == 1 and Late ~= nil, true)
	T:Is("the edit", Late and Late[1], false)
	T:Is("the reason", Late and Late[2], "Busy")
	T:Is("the record is off the datastore", OnDisk(Bank, "leaverec"), false)
	T:Ok("the same edit once the key is gone", (Other.Store:Edit("leaverec", "Fund", { Amount = 5 }):Wait()))
	T:Is("the gold it wrote", Bank:Amount("leaverec"), 5)
end)

Cases.Case("an erase whose removal fails turns writes away only for a short while", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("stuckrec", { Gold = 100 })
	T:Is("the first erase", (Bank.Store:Erase("stuckrec"):Wait()), true)
	T:Advance(Windows.TOMB + 60)

	Bank:NoRetries()
	Bank:Fault(Fault.Removes():OnKey("stuckrec"))
	T:Is("erasing it again", (Bank.Store:Erase("stuckrec"):Wait()), true)
	Bank:Healed()

	T:Is("the record is still there", OnDisk(Bank, "stuckrec"), true)
	local _, Why = Bank.Store:Edit("stuckrec", "Fund", { Amount = 5 }):Wait()
	T:Is("an edit straight after", Why, "Busy")

	T:Advance(Windows.LEAVING + 1)
	T:Ok("an edit once the mark has run out", (Bank.Store:Edit("stuckrec", "Fund", { Amount = 5 }):Wait()))
	T:Is("the gold it wrote", Bank:Amount("stuckrec"), 5)
	T:Is("the mark, cleared by that write", Bank:Record("stuckrec").Removing, nil)
end)

Cases.Case("a commit onto a key another server filled compacts it and is written", function(T: Case)
	Sizes.Set({ Log = 4096 })
	local Bank = T:Bank("nodeA")
	local Other = T:Bank("nodeB")
	local Active: any = Bank:Session("fullcommit")
	for Index = 1, 7 do
		T:Ok(`another server's edit {Index}`, (Other.Store:Edit("fullcommit", "Fund", { Amount = 1, Pad = string.rep("x", 500) }):Wait()))
	end
	T:Is("the ops waiting on the key", #Bank:Record("fullcommit").Ops, 7)

	local Ok, Why = Active:Commit("Fund", { Amount = 10, Pad = string.rep("y", 500) }):Wait()
	T:Is("the commit", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("the gold", Bank:Amount("fullcommit"), 17)
end)

Cases.Case("a commit onto a key compaction cannot shrink answers full", function(T: Case)
	Sizes.Set({ Log = 4096 })
	local Bank = T:Bank()
	local Active: any = Bank:Session("fullwedge")
	Bank:Append("fullwedge", { { Id = "legacy:1", Kind = "Legacy", Payload = string.rep("x", 3500) } :: any })

	local Ok, Why = Active:Commit("Fund", { Amount = 10, Pad = string.rep("y", 500) }):Wait()
	T:Is("the commit", Ok, false)
	T:Is("the reason", Why, "Full")
	T:Warns("it said the key is full", "even after compacting")
	T:Is("the gold", Bank:Amount("fullwedge"), 0)
end)

Cases.Case("a key whose oldest op this build will not apply stops taking writes", function(T: Case)
	Sizes.Set({ Value = 65536, State = 4096, Op = 1024, Log = 2048, Compact = 512 })

	local Store = Ledgered(T)
	Store:Append("wedged", { { Id = "legacy:1", Kind = "Legacy", Payload = string.rep("x", 200) } :: any })

	local Why: any = nil
	for _ = 1, 60 do
		local Ok, Reason = Store.Store:Edit("wedged", "Add", { Amount = 1, Pad = string.rep("y", 60) }):Wait()
		pcall(function()
			Store:Log():Compact("wedged", Store:Format())
		end)
		if not Ok then
			Why = Reason
			break
		end
	end

	T:Is("writes stop once the log fills up behind it", Why, "Full")
	T:Warns("it named the op holding the key", "this build does not apply")
	T:Is("the game can still read what did land", Store:Stored("wedged").Gold > 0, true)

	T:Is("a reset goes through", (Store.Store:Reset("wedged"):Wait()), true)
	T:Warns("but it says it did not free the key", "a reset cannot clear that", 1)
	T:Is("and writes still do not go through", (Store.Store:Edit("wedged", "Add", { Amount = 1 }):Wait()), false)

	T:Is("erasing it is what frees the key", (Store.Store:Erase("wedged"):Wait()), true)
	T:Is("and the log is empty again", #Store:Record("wedged").Ops, 0)
end)

local function Kept(Held: Fixture, Key: string): string
	local Names: { string } = {}
	for _, Op in Held:Record(Key).Ops do
		table.insert(Names, tostring(Op.Kind))
	end
	return if #Names == 0 then "none" else table.concat(Names, ",")
end

Cases.Case("a write the reducer would refuse never reaches the log", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("spendrace", { Gold = 100, Touches = 0 })

	local First, Second: any = nil, nil
	T:Race({
		function()
			First = Bank.Store:Edit("spendrace", "Give", { Amount = -100 }):Wait()
		end,
		function()
			Second = Bank.Store:Edit("spendrace", "Give", { Amount = -100 }):Wait()
		end,
	})

	T:Is("one of the two racing spends took", First == true or Second == true, true)
	T:Is("and only one of them", First == true and Second == true, false)
	T:Is("the log holds the one that took and nothing else", Kept(Bank, "spendrace"), "Give")
	T:Is("gold left", Bank:State("spendrace").Gold, 0)
end)

Cases.Case("an op whose reducer throws never reaches the log", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("thrower", { Gold = 10, Touches = 0 })
	Bank.Store:Edit("thrower", "Fund", { Amount = 5 }):Wait()

	local Ok, Why = Bank.Store:Edit("thrower", "Boom", {}):Wait()

	T:Is("an edit whose reducer throws", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("the log is untouched by it", Kept(Bank, "thrower"), "Fund")
	T:Is("and the key still reads", Bank:State("thrower").Gold, 15)
end)

Cases.Case("a guard that runs again judges the record its op lands on", function(T: Case)
	local Bank = T:Bank("nodeA")
	local Beside = T:Bank("nodeB")

	Bank:Seed("recheck", { Gold = 0, Touches = 0 })
	Bank:Park("recheck", {
		Id = "tx:recheck:1",
		Kind = "Give",
		Amount = 100,
		Tx = "recheck",
		TxGen = "rgen",
		TxAt = T:Now(),
		TxTerms = "rterms",
		TxSticky = "recheck",
	})

	T:Race({
		function()
			Beside:Log():Resolve("recheck", { recheck = { Commit = true, Gen = "rgen", Since = T:Now() } })
		end,
		function()
			Bank.Store:Edit("recheck", "Give", { Amount = -50 }):Wait()
		end,
	})

	local Found: any = nil
	for _, Op in Bank:Record("recheck").Ops do
		if Op.Amount == -50 then
			Found = Op
		end
	end

	T:Ok("two writes met on the key and one ran its transform again", T.Service.Conflicts > 0)
	T:Ok("the op the second run wrote", Found ~= nil)
	T:Is("what it was taken in for, cleared once the leg had committed", if Found ~= nil then Found.TxOnly else "no op", nil)
	T:Is("gold once the leg committed and the op applied", Bank:Amount("recheck"), 50)
end)

Cases.Case("two servers appending one op run its transform again and write it once", function(T: Case)
	local Bank = T:Bank("nodeA")
	local Beside = T:Bank("nodeB")

	Bank:Seed("sameop", { Gold = 0, Touches = 0 })
	local Op = NewOp.New("Fund", { Amount = 25 })

	T:Race({
		function()
			Bank:Append("sameop", { Op })
		end,
		function()
			Beside:Append("sameop", { Op })
		end,
	})

	local Count = 0
	for _, Held in Bank:Record("sameop").Ops do
		if Held.Id == Op.Id then
			Count += 1
		end
	end

	T:Ok("two writes met on the key and one ran its transform again", T.Service.Conflicts > 0)
	T:Is("times the op is in the log", Count, 1)
	T:Is("gold, counting it once", Bank:Amount("sameop"), 25)
end)

Cases.Case("an older build cannot compact away a bump on a field it does not know", function(T: Case)
	local Old = T:Store({ Default = { Gold = 0 }, Reducer = Suite.Reducers.Keep, Data = "CaseDeployBump", Node = "nodeX" })
	local New = T:Store({ Default = { Gold = 0, Gems = 0 }, Reducer = Suite.Reducers.Keep, Data = "CaseDeployBump", Node = "nodeX" })

	T:Ok("the older build writes the shard first, so its base has no Gems", (Old.Store:Bump("pot", "Gold", 1):Wait()))
	T:Ok("the newer build's bump", (New.Store:Bump("pot", "Gems", 5):Wait()))
	for _ = 1, 129 do
		Old.Store:Bump("pot", "Gold", 1):Wait()
	end
	T:Advance(Windows.TALLY_KEEP + 1)

	T:Is("gems the newer build counts after the older build tried to compact the shard", New.Store:Total("pot", "Gems", 0):Wait(), 5)
	T:Is("gold the older build counts", Old.Store:Total("pot", "Gold", 0):Wait(), 130)
	T:Warns("the older build said it held the bump it does not apply", "this build does not apply")
end)

Cases.Case("an older build cannot compact away a field transfer whose field it does not know", function(T: Case)
	local Old = T:Store({ Default = { Gold = 0 }, Reducer = Suite.Reducers.Keep, Data = "CaseDeployUnits" })
	local New = T:Store({ Default = { Gold = 0, Stock = 10 }, Reducer = Suite.Reducers.Keep, Data = "CaseDeployUnits", Field = "Stock" })
	Old:Seed("shelf", { Gold = 0 })
	Old:Seed("cart", { Gold = 0 })

	T:Ok("the transfer on the newer build", (New.Store:Transfer("shelf", "cart", 3, "unit1", "Stock"):Wait()))
	local Before = New:Amount("shelf", "Stock") + New:Amount("cart", "Stock")
	for _ = 1, 130 do
		Old.Store:Edit("shelf", "Touch"):Wait()
	end

	T:Is("units before the older build wrote", Before, 20)
	T:Is("units after the older build tried to compact the sender", New:Amount("shelf", "Stock") + New:Amount("cart", "Stock") + New:Aside("shelf", "Stock"), 20)
	T:Warns("the older build said it could not compact the key", "cannot be compacted")
end)

Cases.Case("erasing a key nobody wrote says nothing about money", function(T: Case)
	local Bank = T:Store({ Default = { Gold = 100, Touches = 0 }, Reducer = Suite.Reducers.Banker, Balance = "Gold" })
	Bank:Seed("written", { Gold = 100, Touches = 0 })

	T:Is("erasing a key nobody ever wrote", (Bank.Store:Erase("neverwritten"):Wait()), true)
	T:Is("erasing a key that held the same balance", (Bank.Store:Erase("written"):Wait()), true)

	T:Warns("it named the balance the written key lost, once", "destroyed 100 Gold", 1)
	T:Is("the key nobody wrote still reads as the default", Bank:Amount("neverwritten"), 100)
end)

Cases.Case("an append whose op does not come back from the datastore says so", function(T: Case)
	local Store = Ledgered(T)

	local Says = T:Throws("an append of an op a record cannot read back", function()
		Store:Log():Append("lostop", { { Id = 5, Kind = "Touch" } :: any })
	end)

	T:Is("it names the rule that did not hold", Says ~= nil and string.find(Says, "did not all come back", 1, true) ~= nil, true)
end)

local function Churn(T: Case, Held: Fixture, Key: string, Rounds: number, Size: number?, Kind: string?, Fields: any?)
	local Active: any = Held:Session(Key)
	for _ = 1, Rounds do
		T:Advance(60)
		for _ = 1, Size or 600 do
			Active:Apply(Kind or "Stamp", Fields)
		end
		Active:Flush():Wait()
		Active:Compact():Wait()
	end
end

local function Remembers(Held: Fixture, Key: string, Id: string): boolean
	local Record = Held:Record(Key)
	for _, Op in Record.Ops do
		if Op.Id == Id then
			return true
		end
	end
	return table.find(Record.Seen, Id) ~= nil
end

Cases.Case("an op retried once its id has aged out of the key answers unresolved rather than applying twice", function(T: Case)
	local Bank = T:Bank()
	local Op: any = { Id = "grant:1", Kind = "Fund", Amount = 10, IdAt = T:Now() }
	T:Ok("the first edit", (Bank.Store:EditOp("agedop", Op):Wait()))
	T:Is("a retry while the key still keeps the id", (Bank.Store:EditOp("agedop", Op):Wait()), true)

	Churn(T, Bank, "agedop", 5)
	T:Is("the key no longer keeps the id", Remembers(Bank, "agedop", "grant:1"), false)

	local Ok, Why = Bank.Store:EditOp("agedop", Op):Wait()
	T:Is("the retry", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Warns("it said the key no longer keeps the id", "no longer keeps ids")
	T:Is("the gold, granted once", Bank:Amount("agedop"), 10)
end)

Cases.Case("a new op sent after a key dropped old ids is written, even from a clock a little behind", function(T: Case)
	local Bank = T:Bank()
	Churn(T, Bank, "newop", 5)
	T:Is("the key has dropped ids", Bank:Record("newop").Horizon ~= nil, true)

	T:Ok("an op sent now", (Bank.Store:EditOp("newop", { Id = "fresh:1", Kind = "Fund", Amount = 1, IdAt = T:Now() } :: any):Wait()))
	T:Ok("an op from a clock five seconds behind", (Bank.Store:EditOp("newop", { Id = "fresh:2", Kind = "Fund", Amount = 1, IdAt = T:Now() - 5 } :: any):Wait()))
	T:Is("the gold", Bank:Amount("newop"), 2)
end)

Cases.Case("a confirm retried once its id has aged out of the key answers unresolved rather than selling twice", function(T: Case)
	local Shelf = T:Shelf()
	local Sent = T:Now()
	T:Ok("the first confirm", (Shelf.Store:Confirm("agedshop", "order1", "Sell", { IdAt = Sent }):Wait()))

	Churn(T, Shelf, "agedshop", 5, nil, "Restock", { Count = 0 })
	T:Is("the key no longer keeps the id", Remembers(Shelf, "agedshop", "cf:order1"), false)

	local Ok, Why = Shelf.Store:Confirm("agedshop", "order1", "Sell", { IdAt = Sent }):Wait()
	T:Is("the retry", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("the stock, sold once", Shelf:Stored("agedshop").Stock, 9)
	T:Silent("the id was not warned about as an extra field", "only means something")
end)

Cases.Case("a commit retried once its id has aged out of the key answers unresolved rather than applying twice", function(T: Case)
	local Bank = T:Bank()
	local Active: any = Bank:Session("agedcommit")
	local Op: any = { Id = "commit:1", Kind = "Fund", Amount = 10, IdAt = T:Now() }
	T:Ok("the first commit", (Active:CommitOp(table.clone(Op)):Wait()))

	Churn(T, Bank, "agedcommit", 5)
	T:Is("the key no longer keeps the id", Remembers(Bank, "agedcommit", "commit:1"), false)

	local Ok, Why = Active:CommitOp(table.clone(Op)):Wait()
	T:Is("the retry", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Warns("it said the key no longer keeps the id", "no longer keeps ids")
	T:Is("the gold, granted once", Bank:Amount("agedcommit"), 10)
end)

Cases.Case("an op retried from before its key was erased answers unresolved", function(T: Case)
	local Bank = T:Bank()
	local Op: any = { Id = "grant:2", Kind = "Fund", Amount = 10, IdAt = T:Now() }
	T:Ok("the first edit", (Bank.Store:EditOp("erasedop", Op):Wait()))
	T:Advance(60)
	T:Ok("the erase", (Bank.Store:Erase("erasedop"):Wait()))

	local Ok, Why = Bank.Store:EditOp("erasedop", Op):Wait()
	T:Is("the retry", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("the gold on the erased key", Bank:Amount("erasedop"), 0)
end)

Cases.Case("IdAt on an op whose id Ledger picks is dropped with a warning, and a wrong one is refused", function(T: Case)
	local Bank = T:Bank()
	T:Ok("an edit carrying IdAt", (Bank.Store:Edit("idatedit", "Fund", { Amount = 1, IdAt = T:Now() - 3600 }):Wait()))
	T:Warns("it said IdAt means nothing there", "only means something")
	T:Is("the op it wrote carries no IdAt", Bank:Record("idatedit").Ops[1].IdAt, nil)

	local Ok, Why = Bank.Store:EditOp("idatedit", { Id = "bad:1", Kind = "Fund", Amount = 1, IdAt = "yesterday" } :: any):Wait()
	T:Is("an op whose IdAt is not a time", Ok, false)
	T:Is("the reason", Why, "Invalid")
end)

Cases.Case("the record of when a key absorbed its ids stays small and covers what it keeps", function(T: Case)
	local Bank = T:Bank()
	Churn(T, Bank, "runs", 60, 50)

	local Record = Bank:Record("runs")
	local Covered = 0
	for _, Run in Record.Absorbed or {} do
		Covered += Run.Count
	end
	T:Is("the runs it keeps, at most sixteen", #(Record.Absorbed or {}) <= 16, true)
	T:Is("the ids they cover", Covered, #Record.Seen)
	T:Is("a horizon, once ids were dropped", type(Record.Horizon), "number")
	T:Is("the horizon, behind the newest run", type(Record.Horizon) == "number" and Record.Horizon <= T:Now() - 60, true)
end)

local function Rerun(Gates: { boolean }): Transform.Outcome
	local Open = false
	local List: { Rules.Rule } = {
		Rules.Allowed(function(): boolean
			return Open
		end),
		Rules.Fresh({ { Id = "keep", Kind = "Fund" }, { Id = "turn", Kind = "Fund" } } :: any, function()
			return function(Op: any): boolean?
				return Op.Id ~= "turn"
			end
		end),
	}

	return Transform.Run(function(_Key: string, Apply: (any) -> any): any
		local Last: any = nil
		for _, Gate in Gates do
			Open = Gate
			Last = Apply({ Ops = {}, Seen = {} })
		end
		local Before = { Ops = {}, Seen = {} }
		return { Before = Before, After = Last or Before, Changed = Last ~= nil }
	end, "rerun", List)
end

Cases.Case("a transform the datastore runs twice starts the second run from a fresh pass", function(T: Case)
	local Quieted = Rerun({ false, true })
	T:Is("a second run the guard lets through, after a first run it stopped", Quieted.Changed, true)
	T:Is("the op the second run wrote", #Quieted.After.Ops, 1)

	local Stopped = Rerun({ true, false })
	T:Is("a second run the guard stops, after a first run that wrote", Stopped.Changed, false)
	T:Is("ops the first run turned away, which the second run never judged", Stopped.Notes.Turned, nil)
end)

Cases.Case("a write that landed but lost its answer, and whose retry meets a newer build, answers Unresolved and not Behind", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("k", { Gold = 10 })

	Bank:Fault(Fault.Updates():OnKey("k"):Only(1):Swallow())
	Bank:Fault(Fault.Updates():OnKey("k"):Only(2):Meddle(function()
		Bank.Direct:UpdateAsync("k", function(Current: any): any
			local Record = table.clone(Current)
			Record.Floor = 1
			Record.Version = 1
			return Record
		end)
	end))

	local Ok, Why = Bank.Store:Edit("k", "Fund", { Amount = 5 }):Wait()
	T:Is("the edit, whose first try landed", Ok, false)
	T:Is("the reason, since this build cannot read the record to say what the op did", Why, "Unresolved")
	T:Is("the op is on the key once", #Bank:Record("k").Ops, 1)
end)

Cases.Case("a write that landed but lost its answer, and whose retry meets an erase its reducer refuses, answers Unresolved and not Refused", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("g", { Gold = 60 })

	Bank:Fault(Fault.Updates():OnKey("g"):Only(1):Swallow())
	Bank:Fault(Fault.Updates():OnKey("g"):Only(2):Meddle(function()
		Bank.Direct:UpdateAsync("g", function(Current: any): any
			local Tomb = table.clone(Current)
			Tomb.Ops = {}
			Tomb.Seen = {}
			Tomb.Snapshot = nil
			Tomb.Erased = T:Now()
			Tomb.Horizon = T:Now()
			return Tomb
		end)
	end))

	local Ok, Why = Bank.Store:Edit("g", "Give", { Amount = -50 }):Wait()
	T:Is("the edit, whose first try landed before the erase", Ok, false)
	T:Is("the reason, since that try may have gone through", Why, "Unresolved")
	T:Warns("it says the try before may have landed", "may have gone through on a try whose answer was lost", 1)
	T:Is("nothing was written on the erased key", #Bank:Record("g").Ops, 0)
end)

Cases.Case("a reset that landed but lost its answer, and whose retry meets a parked leg, still answers", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("r", { Gold = 70 })

	Bank:Fault(Fault.Updates():OnKey("r"):Only(1):Swallow())
	Bank:Fault(Fault.Updates():OnKey("r"):Only(2):Meddle(function()
		Bank:Marker("later", { Status = "Pending", Total = 2, Gen = "lg", At = T:Now(), Adopted = {} })
		Bank:Park("r", { Id = "tx:later:1", Kind = "Fund", Amount = 5, Tx = "later", TxGen = "lg", TxAt = T:Now() })
	end))

	local Ok, Why = Bank.Store:Reset("r"):Wait()
	T:Ok("the reset answered, rather than throwing", Ok == true or Why ~= nil)
	T:Ok("and it did not say no to a reset that landed", Ok == true or Why == "Unresolved")
	T:Silent("nothing threw in the background", "work Ledger was doing in the background threw")
	T:Is("the leg is still parked", Bank:Pending("r"), true)
end)

Cases.Case("a write its reducer refuses on the first try still answers Refused", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("h", { Gold = 10 })

	local Ok, Why = Bank.Store:Edit("h", "Give", { Amount = -50 }):Wait()
	T:Is("the edit", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Silent("nothing says a try may have landed", "may have gone through on a try whose answer was lost")
end)

return Cases
