--!strict
--!optimize 2

--[=[
	Transactions: One rule per case for the two phase commit and its markers.

	Each leg is parked on its key first, one write to the marker decides the whole set, and every leg
	is resolved against that decision last. A coordinator that stops leaves a marker, and another
	server finishes it. The marker decides, and never the server that asked.
	A generation is what stops one transaction settling another's legs. Reaping a marker means proving
	every key it named has forgotten it.

	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, and it runs the next time you press play.
--]=]

local Suite = require("../Suite")

local Fault = Suite.Fault
local Insides = Suite.Insides

local IsStorable = Insides.IsStorable
local Log = Insides.Log
local Mark = Insides.Mark
local Registry = Insides.Registry
local Session = Insides.Session
local Tx = Insides.Tx

type Case = Suite.Case
type Fixture = Suite.Fixture

local Cases = Suite.File("Transactions")

local function Swap(Shop: Fixture, A: string, B: string, Price: number, Id: string): (boolean, any)
	return Shop.Store
		:Tx(Id, {
			{ Key = A, Kind = "Delta", Fields = { Gold = Price, Drop = "Sword" } },
			{ Key = B, Kind = "Delta", Fields = { Gold = -Price, Gain = "Sword" } },
		})
		:Wait()
end

local function Cross(Shop: Fixture, Vault: Fixture, A: string, B: string, Amount: number, Id: string): (boolean, any)
	return Shop.Store
		:Tx(Id, {
			{ Key = A, Kind = "Delta", Fields = { Gold = -Amount } },
			{ Key = B, Kind = "Vault", Fields = { Coins = Amount }, Store = Vault.Store },
		})
		:Wait()
end

local function Wares(Shop: Fixture, Key: string, Gold: number, Sword: boolean)
	Shop:Seed(Key, { Gold = Gold, Items = if Sword then { Sword = true } else {} })
end

local function CraftSwap(Shop: Fixture, A: string, B: string, Status: string, Price: number): string
	local Txid = `swap{A}`

	Shop:Marker(Txid, { Status = Status, Total = 2, Adopted = {} })
	Shop:Park(A, { Id = `tx:{Txid}:1`, Kind = "Delta", Gold = Price, Drop = "Sword", Tx = Txid })
	Shop:Park(B, { Id = `tx:{Txid}:2`, Kind = "Delta", Gold = -Price, Gain = "Sword", Tx = Txid })
	return Txid
end

local function Craft(Bank: Fixture, Key: string, Status: string, MarkerGen: string?, LegGen: string?, Born: number, At: number): string
	local Txid = `gen{Key}`

	Bank:Marker(Txid, {
		Status = Status,
		Total = 2,
		Gen = MarkerGen,
		At = Born,
		Adopted = {},
		Keys = `{Bank.Data}\0{Key}`,
	})
	Bank:Park(Key, {
		Id = `tx:{Txid}:1`,
		Kind = "Give",
		Amount = 25,
		Tx = Txid,
		TxGen = LegGen,
		TxAt = At,
	})
	return Txid
end

local function Generations(T: Case, Status: string, Drift: number, Left: number, Label: string)
	local Bank = T:Bank()
	local Key = `gk{Status}{if Drift < 0 then "old" else "new"}`
	local Born = T:Now()

	Bank:Seed(Key, { Gold = 100 })
	local Txid = Craft(Bank, Key, Status, "one", "two", Born, Born + Drift)
	Bank.Store:Resettle(Key):Wait()

	local Marker = Bank:Mark(Txid)
	T:Is(`{Label}: ops left on the key`, #Bank:Record(Key).Ops, Left)
	T:Is(`{Label}: gold`, Bank:Amount(Key), 100)
	T:Is(`{Label}: the marker still stands`, type(Marker), "table")
	T:Is(`{Label}: nothing was adopted`, next((Marker :: any).Adopted), nil)
end

local function Waited(T: Case, Bank: Fixture, Legs: number, Seconds: number): string?
	local Id = `wait{Legs}`
	local Key = `wait{Legs}key`

	Bank:Seed(Key, { Gold = 100 })
	Bank:Marker(Id, { Status = "Pending", Total = Legs, Gen = "one", At = T:Now(), Adopted = {} })
	Bank:Park(Key, { Id = `tx:{Id}:1`, Kind = "Give", Amount = 25, Tx = Id })

	T:Advance(Seconds)
	Bank.Store:Resettle(Key):Wait()

	local Left = Bank:Mark(Id)
	return if type(Left) == "table" then (Left :: any).Status else nil
end

Cases.Case("a lost decision leaves prepared legs alone", function(T: Case)
	local Bank = T:Bank()

	Bank.Store:Edit("lostA", "Fund", { Amount = 100 }):Wait()
	Bank.Store:Edit("lostB", "Fund", { Amount = 100 }):Wait()

	Bank:Fault(Fault.Updates():OnKey("lostB"))
	Bank:MarkerFault(Fault.Updates():After(2))

	local Ok, Why = Bank.Store
		:Tx("lost1", {
			{ Key = "lostA", Kind = "Give", Fields = { Amount = -50 } },
			{ Key = "lostB", Kind = "Give", Fields = { Amount = 50 } },
		})
		:Wait()

	Bank:Healed()

	local Marker = Bank:Mark("lost1")
	T:Is("the transaction answered", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("the marker status", if type(Marker) == "table" then Marker.Status else nil, "Pending")
	T:Is("a leg is still pending on the key that prepared", Bank:Pending("lostA"), true)

	T:Advance(Tx.TIMEOUT + 1)
	Bank.Store:Resettle("lostA"):Wait()
	Bank.Store:Resettle("lostB"):Wait()

	T:Is("gold on the prepared key once the marker times out", Bank:Amount("lostA"), 100)
	T:Is("gold on the key that never prepared", Bank:Amount("lostB"), 100)
	T:Is("anything left pending on the prepared key", Bank:Pending("lostA"), false)
end)

Cases.Case("an edit compacted away is not called refused", function(T: Case)
	local Bank = T:Bank()

	Bank.Store:Edit("packed", "Fund", { Amount = 100 }):Wait()

	local Op: any = { Id = "packed:1", Kind = "Touch" }
	Bank:Append("packed", { Op })
	Bank:Log():Compact("packed", Bank:Format())

	local Before = Bank:State("packed").Touches
	local Ok, Why = Bank.Store:Written("packed", Op, "edit 'Touch'")

	T:Is("the touch is folded into the snapshot", Before, 1)
	T:Is("the op is no longer carried by the log", Log.Holds(Bank:Record("packed"), Op.Id), false)
	T:Is("the answer", Ok, false)
	T:Is("the reason for an op the log can no longer speak for", Why, "Unresolved")
	T:Is("the touch after asking again", Bank:State("packed").Touches, 1)
end)

Cases.Case("an edit whose verdict hangs on a stuck leg is unresolved", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("hungA", { Gold = 50 })
	Bank:Marker("hung1", { Status = "Pending", Total = 2, Adopted = {} })
	Bank:Park("hungA", { Id = "tx:hung1:1", Kind = "Give", Amount = -40, Tx = "hung1" })

	local Ok, Why = Bank.Store:Edit("hungA", "Give", { Amount = -50 }):Wait()

	T:Is("an edit whose verdict hangs on a stuck leg", Ok, false)
	T:Is("the reason", Why, "Unresolved")

	T:Advance(Tx.TIMEOUT + 1)
	Bank.Store:Resettle("hungA"):Wait()

	T:Is("gold once the leg aborts and the edit folds final", Bank:Amount("hungA"), 0)
	T:Is("anything left pending", Bank:Pending("hungA"), false)
end)

Cases.Case("an edit the leg cannot overturn stays answered", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("sureA", { Gold = 50 })
	Bank:Marker("sure1", { Status = "Pending", Total = 2, Adopted = {} })
	Bank:Park("sureA", { Id = "tx:sure1:1", Kind = "Give", Amount = -40, Tx = "sure1" })

	local Ok, Why = Bank.Store:Edit("sureA", "Fund", { Amount = 5 }):Wait()

	T:Is("an edit the stuck leg cannot overturn", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("the leg is still pending", Bank:Pending("sureA"), true)
	T:Is("gold with the leg still skipped", Bank:Amount("sureA"), 55)
end)

Cases.Case("a done transaction is not called busy", function(T: Case)
	local Bank = T:Bank("node1")
	local Other = T:Bank("node2")

	Bank.Store:Edit("doneA", "Fund", { Amount = 100 }):Wait()
	Bank.Store:Edit("doneB", "Fund", { Amount = 100 }):Wait()
	Bank.Store:Edit("doneC", "Fund", { Amount = 100 }):Wait()

	local First = Bank.Store
		:Tx("done1", {
			{ Key = "doneA", Kind = "Give", Fields = { Amount = -40 } },
			{ Key = "doneB", Kind = "Give", Fields = { Amount = 40 } },
		})
		:Wait()

	Other:MarkerFault(Fault.Updates():After(2))
	Other.Store
		:Tx("stuck1", {
			{ Key = "doneA", Kind = "Give", Fields = { Amount = -1 } },
			{ Key = "doneC", Kind = "Give", Fields = { Amount = 1 } },
		})
		:Wait()
	Other:Healed()

	local Ok, Why = Bank.Store
		:Tx("done1", {
			{ Key = "doneA", Kind = "Give", Fields = { Amount = -40 } },
			{ Key = "doneB", Kind = "Give", Fields = { Amount = 40 } },
		})
		:Wait()

	T:Is("the first attempt", First, true)
	T:Is("a leg of another transaction is parked on the shared key", Bank:Pending("doneA"), true)
	T:Is("asking again for a transaction that already went through", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("gold on the sending key", Bank:Amount("doneA"), 60)
	T:Is("gold on the receiving key", Bank:Amount("doneB"), 140)
end)

Cases.Case("a renamed amount never half applies", function(T: Case)
	local Bank = T:Bank()

	Bank.Store:Edit("termsA", "Fund", { Amount = 100 }):Wait()
	Bank.Store:Edit("termsB", "Fund", { Amount = 100 }):Wait()

	Bank:MarkerFault(Fault.Updates():After(2))
	Bank.Store
		:Tx("terms1", {
			{ Key = "termsA", Kind = "Give", Fields = { Amount = -43 } },
			{ Key = "termsB", Kind = "Give", Fields = { Amount = 43 } },
		})
		:Wait()
	Bank:Healed()

	local Ok, Why = Bank.Store
		:Tx("terms1", {
			{ Key = "termsA", Kind = "Give", Fields = { Amount = -23 } },
			{ Key = "termsB", Kind = "Give", Fields = { Amount = 23 } },
		})
		:Wait()

	T:Advance(Tx.TIMEOUT + 1)
	Bank.Store:Resettle("termsA"):Wait()
	Bank.Store:Resettle("termsB"):Wait()

	T:Is("asking again under the same name with a different amount", Ok, false)
	T:Is("the reason", Why, "Spent")
	T:Is("gold on the sending key", Bank:Amount("termsA"), 100)
	T:Is("gold on the receiving key", Bank:Amount("termsB"), 100)
	T:Is("money is conserved", Bank:Amount("termsA") + Bank:Amount("termsB"), 200)
end)

Cases.Case("markers behind a wall of unreapable ones are still reaped", function(T: Case)
	local Bank = T:Bank()
	local Born = T:Now()

	for Index = 1, 70 do
		Bank:Marker(string.format("aaa-stuck-%04d", Index), {
			Status = "Pending",
			Total = 2,
			Gen = "one",
			At = Born,
			Adopted = {},
		})
	end
	for Index = 1, 30 do
		Bank:Marker(string.format("zzz-done-%04d", Index), {
			Status = "Aborted",
			Total = 0,
			Gen = "one",
			At = Born,
			Adopted = {},
		})
	end

	T:Advance(Tx.REAP_HORIZON + 60)
	local Reaped = Bank.Store:ReapMarkers()

	T:Is("the finished markers sitting behind the stuck ones", Reaped, 30)
	T:Is("what is left, which is the stuck ones only", #Bank:Marks(), 70)
end)

Cases.Case("a finished marker behind more stuck ones than one pass can walk is still reaped", function(T: Case)
	local Bank = T:Bank()
	local Stuck = 120
	local Deals = 6
	local Born = T:Now()

	for Index = 1, Stuck do
		Bank:Marker(string.format("aaa-wall-%04d", Index), {
			Status = "Pending",
			Total = 2,
			Gen = "one",
			At = Born,
			Adopted = {},
		})
	end

	Bank:Seed("wallA", { Gold = 1000 })
	Bank:Seed("wallB", { Gold = 0 })

	for Index = 1, Deals do
		Bank.Store
			:Tx(string.format("zzz-deal-%02d", Index), {
				{ Key = "wallA", Kind = "Give", Fields = { Amount = -1 } },
				{ Key = "wallB", Kind = "Give", Fields = { Amount = 1 } },
			})
			:Wait()
	end

	T:Advance(Tx.REAP_HORIZON + 60)

	Bank.Store:ReapMarkers()

	T:Is("the deals went through", Bank:Amount("wallB"), Deals)
	T:Is("markers left standing, which should be the stuck ones only", #Bank:Marks(), Stuck)
end)

Cases.Case("a finished marker behind a shard full of stuck cleanup keys is still reaped", function(T: Case)
	local Bank = T:Bank()
	local Victim = "zzz-victim"
	local Shard = Tx.Roll.Shard(Victim)
	local Wall = Tx.REAP_PAGE + 6

	for Index = 1, Wall do
		local Try = 0
		local Id = ""
		repeat
			Try += 1
			Id = string.format("wall-%03d-%03d", Index, Try)
		until Tx.Roll.Shard(Id) == Shard

		Bank:Marker(Id, { Status = "Pending", Total = 2, Gen = "one", At = T:Now(), Adopted = {} })
		T:Advance(60)
	end

	Bank:Marker(Victim, { Status = "Committed", Total = 1, Gen = "one", At = T:Now(), Adopted = {}, Dead = true })
	T:Advance(Tx.REAP_HORIZON + 60)

	local Reaped = Bank.Store:ReapMarkers()

	T:Is("the finished marker sitting past a whole page of cleanup keys", Reaped, 1)
	T:Is("nothing is left of it", Bank:Mark(Victim), nil)
	T:Is("the stuck ones are all still there", #Bank:Marks(), Wall)
end)

Cases.Case("a transaction writes its name on the cleanup list before it opens a marker", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("rollA", { Gold = 100 })
	Bank:Seed("rollB", { Gold = 0 })

	for Index = 1, 3 do
		Bank.Store
			:Tx(string.format("roll-%02d", Index), {
				{ Key = "rollA", Kind = "Give", Fields = { Amount = -5 } },
				{ Key = "rollB", Kind = "Give", Fields = { Amount = 5 } },
			})
			:Wait()
	end

	local Rolled = Bank:Rolled()

	T:Ok("the first name is on the list", Rolled["roll-01"])
	T:Ok("the second name is on the list", Rolled["roll-02"])
	T:Ok("the third name is on the list", Rolled["roll-03"])
	T:Is("gold that moved", Bank:Amount("rollB"), 15)
	T:Is("markers standing, one for each transaction", #Bank:Marks(), 3)
end)

Cases.Case("a transaction Id cannot use the prefix Ledger keeps for itself", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("mineA", { Gold = 100 })
	Bank:Seed("mineB", { Gold = 0 })

	local Says = T:Throws("an Id under Ledger's own prefix", function()
		Bank.Store:Tx("__mine", {
			{ Key = "mineA", Kind = "Give", Fields = { Amount = -5 } },
			{ Key = "mineB", Kind = "Give", Fields = { Amount = 5 } },
		})
	end)

	T:Ok("it said the prefix belongs to Ledger", string.find(tostring(Says), "keeps that prefix", 1, true) ~= nil)
	T:Is("nothing moved", Bank:Amount("mineB"), 0)
end)

Cases.Case("a coordinator that dies between its legs is healed by the retry", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("healA", { Gold = 100 })
	Bank:Seed("healB", { Gold = 100 })

	Bank:Fault(Fault.Updates():After(3))
	Bank.Store
		:Tx("heal1", {
			{ Key = "healA", Kind = "Give", Fields = { Amount = -10 } },
			{ Key = "healB", Kind = "Give", Fields = { Amount = 10 } },
		})
		:Wait()
	Bank:Healed()

	local Stranded = Bank:Pending("healB")

	T:Advance(Tx.REAP_HORIZON + 1)
	local Reaped = Bank.Store:ReapMarkers()

	local Ok = (Bank.Store
		:Tx("heal1", {
			{ Key = "healA", Kind = "Give", Fields = { Amount = -10 } },
			{ Key = "healB", Kind = "Give", Fields = { Amount = 10 } },
		})
		:Wait())

	T:Is("a leg is left parked by the crash", Stranded, true)
	T:Is("the marker is not reaped while its own leg is parked", Reaped, 0)
	T:Is("the retry", Ok, true)
	T:Is("gold on the sending key", Bank:Amount("healA"), 90)
	T:Is("gold on the receiving key", Bank:Amount("healB"), 110)
	T:Is("money is conserved", Bank:Amount("healA") + Bank:Amount("healB"), 200)
end)

Cases.Case("a name reused once its marker is gone is still spent", function(T: Case)
	local Bank = T:Bank()

	Bank.Store:Edit("goneA", "Fund", { Amount = 100 }):Wait()
	Bank.Store:Edit("goneB", "Fund", { Amount = 100 }):Wait()

	local First = (Bank.Store
		:Tx("gone1", {
			{ Key = "goneA", Kind = "Give", Fields = { Amount = -10 } },
			{ Key = "goneB", Kind = "Give", Fields = { Amount = 10 } },
		})
		:Wait())

	local Marker = Bank:Buried("gone1")

	local Ok, Why = Bank.Store
		:Tx("gone1", {
			{ Key = "goneA", Kind = "Give", Fields = { Amount = -50 } },
			{ Key = "goneB", Kind = "Give", Fields = { Amount = 50 } },
		})
		:Wait()

	local Honest = (Bank.Store
		:Tx("gone1", {
			{ Key = "goneA", Kind = "Give", Fields = { Amount = -10 } },
			{ Key = "goneB", Kind = "Give", Fields = { Amount = 10 } },
		})
		:Wait())

	T:Is("the first transaction", First, true)
	T:Is("the marker every leg already adopted", Marker, true)
	T:Is("the same name for a different amount", Ok, false)
	T:Is("the reason", Why, "Spent")
	T:Is("an honest retry of the original terms", Honest, true)
	T:Is("gold on the sending key", Bank:Amount("goneA"), 90)
	T:Is("gold on the receiving key", Bank:Amount("goneB"), 110)
	T:Is("money is conserved", Bank:Amount("goneA") + Bank:Amount("goneB"), 200)
end)

Cases.Case("a name reused once its leg is compacted is still spent", function(T: Case)
	local Bank = T:Bank()

	Bank.Store:Edit("packA", "Fund", { Amount = 100 }):Wait()
	Bank.Store:Edit("packB", "Fund", { Amount = 100 }):Wait()

	Bank.Store
		:Tx("pack1", {
			{ Key = "packA", Kind = "Give", Fields = { Amount = -10 } },
			{ Key = "packB", Kind = "Give", Fields = { Amount = 10 } },
		})
		:Wait()

	Bank:Log():Compact("packA", Bank:Format())
	Bank:Log():Compact("packB", Bank:Format())

	local Ok, Why = Bank.Store
		:Tx("pack1", {
			{ Key = "packA", Kind = "Give", Fields = { Amount = -50 } },
			{ Key = "packB", Kind = "Give", Fields = { Amount = 50 } },
		})
		:Wait()

	local Honest = (Bank.Store
		:Tx("pack1", {
			{ Key = "packA", Kind = "Give", Fields = { Amount = -10 } },
			{ Key = "packB", Kind = "Give", Fields = { Amount = 10 } },
		})
		:Wait())

	T:Is("the same name for a different amount", Ok, false)
	T:Is("the reason", Why, "Spent")
	T:Is("an honest retry of the original terms", Honest, true)
	T:Is("gold on the sending key", Bank:Amount("packA"), 90)
	T:Is("gold on the receiving key", Bank:Amount("packB"), 110)
	T:Is("money is conserved", Bank:Amount("packA") + Bank:Amount("packB"), 200)
end)

Cases.Case("a leg from a dead generation is retired by an abort", function(T: Case)
	Generations(T, "Aborted", -30, 0, "a leg older than an aborted marker")
end)

Cases.Case("a newer generation survives an abort", function(T: Case)
	Generations(T, "Aborted", 30, 1, "a leg newer than an aborted marker")
end)

Cases.Case("a commit never retires another generation", function(T: Case)
	Generations(T, "Committed", -30, 1, "a leg older than a committed marker")
	Generations(T, "Committed", 30, 1, "a leg newer than a committed marker")
end)

Cases.Case("a leg born with the marker is never retired", function(T: Case)
	Generations(T, "Aborted", 0, 1, "a leg stamped in the same second as an aborted marker")
end)

Cases.Case("a marker is not reaped against a leg born in the same second", function(T: Case)
	local Bank = T:Bank()
	local Born = T:Now()

	Bank:Seed("tiereap", { Gold = 100 })
	local Txid = Craft(Bank, "tiereap", "Committed", "one", "two", Born, Born)

	T:Advance(Tx.REAP_HORIZON + 1)
	Bank.Store:ReapMarkers()

	T:Is("a marker whose leg it cannot prove predates it", type(Bank:Mark(Txid)), "table")
	T:Is("the leg is still there", Bank:Pending("tiereap"), true)
end)

Cases.Case("a marker is never reaped against its own live leg", function(T: Case)
	local Bank = T:Bank()
	local Born = T:Now()

	Bank:Seed("ownleg", { Gold = 100 })
	local Txid = Craft(Bank, "ownleg", "Committed", "one", "one", Born, Born - 30)

	T:Advance(Tx.REAP_HORIZON + 1)
	Bank.Store:ReapMarkers()

	T:Is("a marker reaped while a leg of its own generation is parked", type(Bank:Mark(Txid)), "table")

	Bank.Store:Resettle("ownleg"):Wait()
	T:Is("gold once its own leg settles", Bank:Amount("ownleg"), 125)
end)

Cases.Case("a marker with no keys is never reaped while a leg lives", function(T: Case)
	local Bank = T:Bank()
	local Born = T:Now()

	Bank:Seed("keyless", { Gold = 100 })
	Bank:Marker("keyless1", { Status = "Committed", Total = 1, Gen = "one", At = Born, Adopted = {} })
	Bank:Park("keyless", { Id = "tx:keyless1:1", Kind = "Give", Amount = 25, Tx = "keyless1", TxGen = "one", TxAt = Born })

	T:Advance(Tx.REAP_HORIZON + 1)
	Bank.Store:ReapMarkers()
	local Left = Bank:Mark("keyless1")

	Bank.Store:Resettle("keyless"):Wait()

	T:Is("a committed marker naming no keys, reaped while its leg lives", type(Left), "table")
	T:Is("gold once that leg settles", Bank:Amount("keyless"), 125)
	T:Is("anything left pending", Bank:Pending("keyless"), false)
end)

Cases.Case("a leg without a generation still settles", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("gklegacy", { Gold = 100 })
	Craft(Bank, "gklegacy", "Aborted", nil, nil, T:Now(), T:Now())
	Bank.Store:Resettle("gklegacy"):Wait()

	T:Is("a leg carrying no generation at all is settled", #Bank:Record("gklegacy").Ops, 0)
	T:Is("gold", Bank:Amount("gklegacy"), 100)
end)

Cases.Case("a marker is never reaped while a leg still holds it", function(T: Case)
	local Bank = T:Bank()
	local Born = T:Now()

	Bank:Seed("reapheld", { Gold = 100 })
	local Txid = Craft(Bank, "reapheld", "Committed", "one", "one", Born, Born)

	T:Advance(Tx.REAP_HORIZON + 1)
	Bank.Store:ReapMarkers()

	T:Is("a committed marker whose leg is still parked survives the reap", type(Bank:Mark(Txid)), "table")

	Bank.Store:Resettle("reapheld"):Wait()
	T:Is("gold once the parked leg finally settles", Bank:Amount("reapheld"), 125)
	T:Is("anything left pending", Bank:Pending("reapheld"), false)
end)

Cases.Case("a transaction swaps both sides", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "swapA", 100, true)
	Wares(Shop, "swapB", 100, false)

	local Ok = Swap(Shop, "swapA", "swapB", 25, "swap1")
	local SA, SB = Shop:State("swapA"), Shop:State("swapB")

	T:Is("the swap", Ok, true)
	T:Is("the seller's gold", SA.Gold, 125)
	T:Is("the seller still holding the sword", SA.Items.Sword, nil)
	T:Is("the buyer's gold", SB.Gold, 75)
	T:Is("the buyer got the sword", SB.Items.Sword, true)
	T:Is("anything left pending on the seller", Shop:Pending("swapA"), false)
	T:Is("anything left pending on the buyer", Shop:Pending("swapB"), false)
end)

Cases.Case("a transaction aborts when a leg refuses", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "poorA", 100, true)
	Wares(Shop, "poorB", 10, false)

	local Ok, Why = Swap(Shop, "poorA", "poorB", 25, "poor1")
	local SA, SB = Shop:State("poorA"), Shop:State("poorB")

	T:Is("a swap the buyer cannot afford", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("the seller's gold", SA.Gold, 100)
	T:Is("the seller keeps the sword", SA.Items.Sword, true)
	T:Is("the buyer's gold", SB.Gold, 10)
	T:Is("anything left pending on the seller", Shop:Pending("poorA"), false)
	T:Is("anything left pending on the buyer", Shop:Pending("poorB"), false)
end)

Cases.Case("a stale pending marker aborts for a bystander", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "staleA", 100, true)
	Wares(Shop, "staleB", 100, false)
	local Txid = CraftSwap(Shop, "staleA", "staleB", "Pending", 25)

	T:Advance(Tx.TIMEOUT + 1)
	Shop.Store:Resettle("staleA"):Wait()
	Shop.Store:Resettle("staleB"):Wait()

	T:Is("the seller's gold", Shop:State("staleA").Gold, 100)
	T:Is("the seller keeps the sword", Shop:State("staleA").Items.Sword, true)
	T:Is("the buyer's gold", Shop:State("staleB").Gold, 100)
	T:Is("anything left pending on the seller", Shop:Pending("staleA"), false)
	T:Is("the timed out marker is buried", Shop:Buried(Txid), true)
end)

Cases.Case("a committed marker heals after a crash", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "healA", 100, true)
	Wares(Shop, "healB", 100, false)
	local Txid = CraftSwap(Shop, "healA", "healB", "Committed", 25)

	Shop.Store:Resettle("healA"):Wait()
	Shop.Store:Resettle("healB"):Wait()

	T:Is("the seller's gold", Shop:State("healA").Gold, 125)
	T:Is("the seller gave up the sword", Shop:State("healA").Items.Sword, nil)
	T:Is("the buyer's gold", Shop:State("healB").Gold, 75)
	T:Is("the buyer got the sword", Shop:State("healB").Items.Sword, true)
	T:Is("the finished marker is buried", Shop:Buried(Txid), true)
end)

Cases.Case("a busy key refuses a new transaction", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "busyA", 100, true)
	Wares(Shop, "busyB", 100, false)
	CraftSwap(Shop, "busyA", "busyB", "Pending", 25)

	local Ok, Why = Swap(Shop, "busyA", "busyB", 10, "busy1")

	T:Is("a swap onto a key another transaction holds", Ok, false)
	T:Is("the reason", Why, "Busy")
	T:Is("the seller's gold", Shop:State("busyA").Gold, 100)
	T:Is("the buyer's gold", Shop:State("busyB").Gold, 100)
end)

Cases.Case("a retry after busy succeeds", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "retryA", 100, true)
	Wares(Shop, "retryB", 100, false)
	CraftSwap(Shop, "retryA", "retryB", "Pending", 25)

	local Blocked, Why = Swap(Shop, "retryA", "retryB", 25, "retry1")

	T:Advance(Tx.TIMEOUT + 1)
	Shop.Store:Resettle("retryA"):Wait()
	Shop.Store:Resettle("retryB"):Wait()

	local Retried = Swap(Shop, "retryA", "retryB", 25, "retry1")
	local SA, SB = Shop:State("retryA"), Shop:State("retryB")

	T:Is("the blocked attempt", Blocked, false)
	T:Is("the reason it was blocked", Why, "Busy")
	T:Is("the same name retried once the key freed up", Retried, true)
	T:Is("the seller's gold", SA.Gold, 125)
	T:Is("the seller gave up the sword", SA.Items.Sword, nil)
	T:Is("the buyer's gold", SB.Gold, 75)
	T:Is("the buyer got the sword", SB.Items.Sword, true)
end)

Cases.Case("an aborted husk heals in one call", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "huskA", 100, true)
	Wares(Shop, "huskB", 100, false)
	Shop:Marker("husk1", { Status = "Aborted", Total = 2, Adopted = {} })

	local Ok, Why = Swap(Shop, "huskA", "huskB", 25, "husk1")

	T:Is("a swap under a name whose husk marker was left aborted", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("the husk is buried", Shop:Buried("husk1"), true)
	T:Is("the seller's gold", Shop:State("huskA").Gold, 125)
	T:Is("the buyer's gold", Shop:State("huskB").Gold, 75)
	T:Is("anything left pending on the seller", Shop:Pending("huskA"), false)
end)

Cases.Case("a husk naming more legs than the retry still heals", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "wideA", 100, true)
	Wares(Shop, "wideB", 100, false)
	Shop:Marker("wide1", { Status = "Aborted", Total = 5, Gen = "dead", At = T:Now(), Adopted = {} })

	local Ok, Why = Swap(Shop, "wideA", "wideB", 25, "wide1")

	T:Is("a swap under a husk naming more legs than the retry drives", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("the husk is buried", Shop:Buried("wide1"), true)
	T:Is("the seller's gold", Shop:State("wideA").Gold, 125)
	T:Is("the buyer's gold", Shop:State("wideB").Gold, 75)
	T:Is("anything left pending on the seller", Shop:Pending("wideA"), false)
end)

Cases.Case("a zero total husk also heals", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "zeroA", 100, true)
	Wares(Shop, "zeroB", 100, false)
	Shop:Marker("zero1", { Status = "Aborted", Total = 0, Adopted = {} })

	local Ok = Swap(Shop, "zeroA", "zeroB", 25, "zero1")

	T:Is("a swap under a zero total husk", Ok, true)
	T:Is("the husk is buried", Shop:Buried("zero1"), true)
	T:Is("the seller's gold", Shop:State("zeroA").Gold, 125)
	T:Is("the buyer's gold", Shop:State("zeroB").Gold, 75)
end)

Cases.Case("a name reused for other keys is refused", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "namedA", 100, true)
	Wares(Shop, "namedB", 100, false)
	Shop:Marker("named1", { Status = "Pending", Total = 2, Adopted = {}, Keys = "another\0set\1of\0keys" })

	local Ok, Why = Swap(Shop, "namedA", "namedB", 25, "named1")

	T:Is("a name that already meant a different set of keys", Ok, false)
	T:Is("the reason", Why, "Spent")
	T:Is("the seller's gold", Shop:State("namedA").Gold, 100)
	T:Is("the buyer's gold", Shop:State("namedB").Gold, 100)
	T:Is("anything left pending on the seller", Shop:Pending("namedA"), false)
	T:Is("anything left pending on the buyer", Shop:Pending("namedB"), false)
end)

Cases.Case("a committed marker beats an abort", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "beatA", 100, true)
	Wares(Shop, "beatB", 100, false)
	Shop:Marker("beat1", { Status = "Committed", Total = 2, Adopted = {} })

	-- an op with a leg shaped id and no transaction stamp on it, which is what a settled leg looks like
	Shop:Append("beatA", { { Id = "tx:beat1:1", Kind = "Delta", Gold = 25, Drop = "Sword" } :: any })

	local Ok, Why = Swap(Shop, "beatA", "beatB", 25, "beat1")

	T:Is("a swap whose marker already says committed", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("the seller's gold", Shop:State("beatA").Gold, 125)
	T:Is("the buyer's gold", Shop:State("beatB").Gold, 75)
	T:Is("the buyer got the sword", Shop:State("beatB").Items.Sword, true)
end)

Cases.Case("a commit leaves no generation on the op", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "genA", 100, true)
	Wares(Shop, "genB", 100, false)

	local Ok = Swap(Shop, "genA", "genB", 25, "gen1")

	local Stamped = false
	for _, Op in Shop:Record("genA").Ops do
		if (Op :: any).TxGen ~= nil then
			Stamped = true
		end
	end

	T:Is("the swap", Ok, true)
	T:Is("a settled op still carrying a generation stamp", Stamped, false)
	T:Is("the seller's gold", Shop:State("genA").Gold, 125)
end)

Cases.Case("a retry after compaction moves nothing twice", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "packA", 100, true)
	Wares(Shop, "packB", 100, false)

	local First = Swap(Shop, "packA", "packB", 25, "pack1")

	Shop:Log():Compact("packA", Shop:Format())
	Shop:Log():Compact("packB", Shop:Format())

	local InSeen = false
	for _, Entry in Shop:Record("packA").Seen do
		if Entry == "tx:pack1:1" then
			InSeen = true
		end
	end

	local Retried = Swap(Shop, "packA", "packB", 25, "pack1")

	T:Is("the first swap", First, true)
	T:Is("the leg id was carried into Seen by compaction", InSeen, true)
	T:Is("the same name retried after compaction", Retried, true)
	T:Is("the seller's gold after the retry", Shop:State("packA").Gold, 125)
	T:Is("the buyer's gold after the retry", Shop:State("packB").Gold, 75)
end)

Cases.Case("a cross store transaction commits both stores", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "xsA", 100, false)
	Vault:Seed("xsB", { Coins = 0 })

	local Ok, Why = Cross(Shop, Vault, "xsA", "xsB", 25, "xs1")

	T:Is("a transaction across two stores", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("gold in the shop", Shop:State("xsA").Gold, 75)
	T:Is("coins in the vault", Vault:State("xsB").Coins, 25)
	T:Is("anything left pending in the shop", Shop:Pending("xsA"), false)
	T:Is("anything left pending in the vault", Vault:Pending("xsB"), false)
end)

Cases.Case("a cross store transaction aborts when a store refuses", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "xrA", 100, false)
	Vault:Seed("xrB", { Coins = 10 })

	local Ok, Why = Cross(Shop, Vault, "xrA", "xrB", -25, "xr1")

	T:Is("a transaction the vault cannot honour", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("gold in the shop", Shop:State("xrA").Gold, 100)
	T:Is("coins in the vault", Vault:State("xrB").Coins, 10)
	T:Is("anything left pending in the shop", Shop:Pending("xrA"), false)
	T:Is("anything left pending in the vault", Vault:Pending("xrB"), false)
end)

Cases.Case("a down store leaves the other untouched", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "xdA", 100, false)
	Vault:Seed("xdB", { Coins = 0 })

	Vault:Fault(Fault.Updates())
	local Ok, Why = Cross(Shop, Vault, "xdA", "xdB", 25, "xd1")
	Vault:Healed()

	T:Advance(Tx.TIMEOUT + 1)
	Shop.Store:Resettle("xdA"):Wait()
	Vault.Store:Resettle("xdB"):Wait()

	T:Is("a transaction whose second store cannot be written", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("gold in the shop", Shop:State("xdA").Gold, 100)
	T:Is("coins in the vault", Vault:State("xdB").Coins, 0)
	T:Is("anything left pending in the shop", Shop:Pending("xdA"), false)
end)

Cases.Case("a down marker store leaves no legs anywhere", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "xmA", 100, false)
	Vault:Seed("xmB", { Coins = 0 })

	Shop:MarkerFault(Fault.Updates())
	local Ok, Why = Cross(Shop, Vault, "xmA", "xmB", 25, "xm1")
	Shop:Healed()

	T:Is("a transaction whose marker store is down", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("gold in the shop", Shop:State("xmA").Gold, 100)
	T:Is("coins in the vault", Vault:State("xmB").Coins, 0)
	T:Is("ops left on the shop key", #Shop:Record("xmA").Ops, 0)
	T:Is("ops left on the vault key", #Vault:Record("xmB").Ops, 0)
end)

Cases.Case("a repeated name moves the money once", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "onceA", 100, false)
	Vault:Seed("onceB", { Coins = 0 })

	local First = Cross(Shop, Vault, "onceA", "onceB", 25, "once1")
	local Second = Cross(Shop, Vault, "onceA", "onceB", 25, "once1")
	local Third = Cross(Shop, Vault, "onceA", "onceB", 25, "once1")

	T:Is("the first attempt", First, true)
	T:Is("the second attempt under the same name", Second, true)
	T:Is("the third attempt under the same name", Third, true)
	T:Is("no live marker is left behind", Shop:Buried("once1"), true)
	T:Is("gold in the shop, moved exactly once", Shop:State("onceA").Gold, 75)
	T:Is("coins in the vault, moved exactly once", Vault:State("onceB").Coins, 25)
end)

Cases.Case("an overgrown leg log is compacted", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "bigA", 5000, false)
	Vault:Seed("bigB", { Coins = 0 })

	local Filler: { any } = {}
	for Index = 1, 130 do
		table.insert(Filler, { Id = `pad{Index}`, Kind = "Delta", Gold = 0 })
	end
	Shop:Append("bigA", Filler)

	local Before = #Shop:Record("bigA").Ops
	local Ok = Cross(Shop, Vault, "bigA", "bigB", 25, "big1")
	local After = #Shop:Record("bigA").Ops

	T:Is("the log was overgrown before the transaction", Before >= 128, true)
	T:Is("the transaction", Ok, true)
	T:Is("the log was compacted once the leg settled", After < Before, true)
	T:Is("gold in the shop", Shop:State("bigA").Gold, 4975)
	T:Is("coins in the vault", Vault:State("bigB").Coins, 25)
end)

Cases.Case("a decision whose acknowledgement is lost still commits", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "lostackA", 100, false)
	Vault:Seed("lostackB", { Coins = 0 })

	Shop:NoRetries()
	Shop:MarkerFault(Fault.Updates():Only(3):Swallow())
	local Ok, Why = Cross(Shop, Vault, "lostackA", "lostackB", 25, "lostack1")
	Shop:Healed()

	T:Is("a transaction whose decision landed but whose answer was lost", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("gold in the shop", Shop:State("lostackA").Gold, 75)
	T:Is("coins in the vault", Vault:State("lostackB").Coins, 25)
	T:Is("anything left pending in the shop", Shop:Pending("lostackA"), false)
	T:Is("anything left pending in the vault", Vault:Pending("lostackB"), false)
end)

Cases.Case("an adoption whose acknowledgement is lost keeps the marker", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "adoptA", 100, true)
	Wares(Shop, "adoptB", 100, false)
	local Txid = CraftSwap(Shop, "adoptA", "adoptB", "Committed", 25)

	Shop:NoRetries()
	Shop:MarkerFault(Fault.Updates():Only(1):Swallow())
	Shop.Store:Resettle("adoptA"):Wait()
	Shop:Healed()

	local Marker = Shop:Mark(Txid)
	Shop.Store:Resettle("adoptB"):Wait()

	T:Is("the marker survives an adoption whose answer was lost", Marker ~= nil, true)
	T:Is("the seller's gold", Shop:State("adoptA").Gold, 125)
	T:Is("the buyer's gold", Shop:State("adoptB").Gold, 75)
	T:Is("the buyer got the sword", Shop:State("adoptB").Items.Sword, true)
	T:Is("anything left pending on the seller", Shop:Pending("adoptA"), false)
	T:Is("anything left pending on the buyer", Shop:Pending("adoptB"), false)
end)

Cases.Case("a marker without terms still runs", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "oldA", 100, true)
	Wares(Shop, "oldB", 100, false)
	Shop:Marker("old1", { Status = "Pending", Total = 2, Adopted = {} })

	local Ok = Swap(Shop, "oldA", "oldB", 25, "old1")

	T:Is("a marker written before keys and terms existed", Ok, true)
	T:Is("the seller's gold", Shop:State("oldA").Gold, 125)
	T:Is("the buyer's gold", Shop:State("oldB").Gold, 75)
	T:Is("anything left pending on the seller", Shop:Pending("oldA"), false)
	T:Is("anything left pending on the buyer", Shop:Pending("oldB"), false)
end)

Cases.Case("a retry after a lost acknowledgement moves once", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "onceackA", 100, false)
	Vault:Seed("onceackB", { Coins = 0 })

	Shop:NoRetries()
	Shop:MarkerFault(Fault.Updates():Only(3):Swallow())
	local First = Cross(Shop, Vault, "onceackA", "onceackB", 25, "onceack1")
	Shop:Healed()

	T:Advance(Tx.TIMEOUT + 1)
	Shop.Store:Resettle("onceackA"):Wait()
	Vault.Store:Resettle("onceackB"):Wait()

	local Second = Cross(Shop, Vault, "onceackA", "onceackB", 25, "onceack1")

	T:Is("the attempt whose acknowledgement was lost", First, true)
	T:Is("the retry under the same name", Second, true)
	T:Is("gold in the shop, moved exactly once", Shop:State("onceackA").Gold, 75)
	T:Is("coins in the vault, moved exactly once", Vault:State("onceackB").Coins, 25)
end)

Cases.Case("a dead generation leg never deadlocks a committed marker", function(T: Case)
	local Bank = T:Bank()
	local Born = T:Now()

	Bank:Seed("stuckA", { Gold = 100 })
	local Txid = Craft(Bank, "stuckA", "Committed", "two", "one", Born, Born - 30)

	T:Advance(Tx.REAP_HORIZON + 1)
	for _ = 1, 4 do
		Bank.Store:Resettle("stuckA"):Wait()
		Bank.Store:ReapMarkers()
		T:Advance(Tx.REAP_HORIZON + 1)
	end

	T:Is("a leg from a dead generation is not left pending forever", Bank:Pending("stuckA"), false)
	T:Is("the marker it was blocking is reaped", Bank:Mark(Txid), nil)
	T:Is("gold is untouched", Bank:Amount("stuckA"), 100)
end)

Cases.Case("a failed pass never disowns an earlier pass's leg", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "floorA", 100, true)
	Wares(Shop, "floorB", 100, false)

	Shop:Fault(Fault.Updates():OnKey("floorB"))
	local Ok, Why = Swap(Shop, "floorA", "floorB", 25, "floor1")
	Shop:Healed()

	local Marker = Shop:Mark("floor1")
	local Left = if type(Marker) == "table" then (Marker :: any).Total else -1

	T:Is("the transaction", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("a leg that one pass prepared is not disowned by a later failing pass", Left ~= 0, true)

	T:Advance(Tx.TIMEOUT + 1)
	Shop.Store:Resettle("floorA"):Wait()
	Shop.Store:Resettle("floorB"):Wait()

	T:Is("nothing is left pending on the prepared key", Shop:Pending("floorA"), false)
	T:Is("gold on the seller", Shop:State("floorA").Gold, 100)
	T:Is("gold on the buyer", Shop:State("floorB").Gold, 100)
end)

Cases.Case("a marker is held to a deadline its leg count earns", function(T: Case)
	local Bank = T:Bank()
	local Leeway = Tx.LEG_TIMEOUT

	T:Is("a two leg marker just inside its deadline", Waited(T, Bank, 2, Leeway * 2 - 5), "Pending")
	T:Is("a four leg marker at the same age, still working", Waited(T, Bank, 4, Leeway * 2 - 5), "Pending")
end)

Cases.Case("a marker past its own deadline still aborts", function(T: Case)
	local Bank = T:Bank()
	local Leeway = Tx.LEG_TIMEOUT

	T:Is("a two leg marker past two legs worth of time", Waited(T, Bank, 2, Leeway * 2 + 5), "Aborted")
	T:Is("a four leg marker past four legs worth of time", Waited(T, Bank, 4, Leeway * 4 + 5), "Aborted")
end)

Cases.Case("a four leg marker outlives a two leg deadline", function(T: Case)
	local Bank = T:Bank()
	local Leeway = Tx.LEG_TIMEOUT

	T:Is("a four leg marker at three legs worth of time", Waited(T, Bank, 4, Leeway * 3), "Pending")
	T:Is("gold is untouched while it is still allowed to run", Bank:Amount("wait4key"), 100)
end)

Cases.Case("a committer whose marker was aborted pulls its legs back", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("raceA", { Gold = 100 })
	Bank:Seed("raceB", { Gold = 100 })

	local Marks = Bank.DirectMarks
	Bank:MarkerFault(Fault.Updates():OnKey("race1"):Meddle(function()
		Marks:UpdateAsync("race1", function(Current: any): any
			if type(Current) ~= "table" or Current.Status ~= "Pending" then
				return nil
			end
			Current.Status = "Aborted"
			return Current
		end)
	end))

	local Ok, Why = Bank.Store
		:Tx("race1", {
			{ Key = "raceA", Kind = "Give", Fields = { Amount = -25 } },
			{ Key = "raceB", Kind = "Give", Fields = { Amount = 25 } },
		})
		:Wait()

	Bank:Healed()
	Bank.Store:Resettle("raceA"):Wait()
	Bank.Store:Resettle("raceB"):Wait()

	T:Is("a coordinator whose marker was aborted out from under it", Ok, false)
	T:Is("the reason it hands back", Why, "Spent")
	T:Is("gold on the sending key", Bank:Amount("raceA"), 100)
	T:Is("gold on the receiving key", Bank:Amount("raceB"), 100)
	T:Is("anything left pending on the sender", Bank:Pending("raceA"), false)
	T:Is("anything left pending on the receiver", Bank:Pending("raceB"), false)
end)

Cases.Case("reserved transaction fields are refused on game ops", function(T: Case)
	for _, Field in { "Tx", "TxHome", "TxSticky", "TxAt", "TxGen" } do
		local Op: any = { Id = "hand", Kind = "Delta" }
		Op[Field] = if Field == "TxAt" then 1 else "hax"

		local Storable, Why = IsStorable.Op(Op)
		T:Is(`a game op carrying {Field} is storable`, Storable, false)
		T:Is(`the refusal for {Field} says reserved`, string.find(tostring(Why), "reserved", 1, true) ~= nil, true)
	end
end)

Cases.Case("a leg prepared again after an abort is still rolled back", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "againA", 100, true)
	Wares(Shop, "againB", 100, false)
	local Txid = CraftSwap(Shop, "againA", "againB", "Pending", 25)

	T:Advance(Tx.TIMEOUT + 1)
	Shop.Store:Resettle("againA"):Wait()
	Shop.Store:Resettle("againB"):Wait()

	local Again: any = {
		Id = `tx:{Txid}:1`,
		Kind = "Delta",
		Gold = 25,
		Drop = "Sword",
		Tx = Txid,
		TxHome = Shop.Marked,
	}
	local Verdict = Shop:Log():Prepare("againA", Again, Shop:Format())
	Shop.Store:Resettle("againA"):Wait()

	T:Is("re-preparing a leg of a transaction that already aborted", Verdict, "Prepared")
	T:Is("the seller's gold", Shop:State("againA").Gold, 100)
	T:Is("the seller keeps the sword", Shop:State("againA").Items.Sword, true)
	T:Is("anything left pending on the seller", Shop:Pending("againA"), false)
end)

Cases.Case("a three legged transaction moves all or nothing", function(T: Case)
	local Shop = T:Market()
	local First, Second = T:Vault(), T:Store({ Default = Suite.Reducers.COINS, Reducer = Suite.Reducers.Vaulter, Data = "CaseOther", Field = "Coins" })
	Wares(Shop, "triA", 100, false)
	First:Seed("triB", { Coins = 0 })
	Second:Seed("triC", { Coins = 0 })

	local Committed = Shop.Store
		:Tx("tri1", {
			{ Key = "triA", Kind = "Delta", Fields = { Gold = -30 } },
			{ Key = "triB", Kind = "Vault", Fields = { Coins = 20 }, Store = First.Store },
			{ Key = "triC", Kind = "Vault", Fields = { Coins = 10 }, Store = Second.Store },
		})
		:Wait()

	local Aborted, Why = Shop.Store
		:Tx("tri2", {
			{ Key = "triA", Kind = "Delta", Fields = { Gold = -10 } },
			{ Key = "triB", Kind = "Vault", Fields = { Coins = 5 }, Store = First.Store },
			{ Key = "triC", Kind = "Vault", Fields = { Coins = -100 }, Store = Second.Store },
		})
		:Wait()

	T:Is("a three legged transaction every store can honour", Committed, true)
	T:Is("a three legged transaction the last store refuses", Aborted, false)
	T:Is("the reason", Why, "Refused")
	T:Is("gold in the shop", Shop:State("triA").Gold, 70)
	T:Is("coins in the first vault", First:State("triB").Coins, 20)
	T:Is("coins in the second vault", Second:State("triC").Coins, 10)
	T:Is("anything left pending in the shop", Shop:Pending("triA"), false)
	T:Is("anything left pending in the first vault", First:Pending("triB"), false)
	T:Is("anything left pending in the second vault", Second:Pending("triC"), false)
end)

Cases.Case("a marker taken away under a fresh transaction leaves its legs alone", function(T: Case)
	local Bank = T:Bank()
	local Born = T:Now()

	Bank:Seed("vanA", { Gold = 100 })
	local Txid = Craft(Bank, "vanA", "Committed", "vang", "vang", Born, Born)
	Bank:Unmark(Txid)

	T:Advance(5)
	Bank.Store:Resettle("vanA"):Wait()

	T:Is("the marker a slow delete took away", Bank:Mark(Txid), nil)
	T:Is("the leg of a transaction still inside its window", Bank:Pending("vanA"), true)
	T:Is("gold on the key", Bank:Amount("vanA"), 100)
end)

Cases.Case("a leg with no marker is cleared once its window has passed", function(T: Case)
	local Bank = T:Bank()
	local Born = T:Now()

	Bank:Seed("loneA", { Gold = 100 })
	local Txid = Craft(Bank, "loneA", "Committed", "loneg", "loneg", Born, Born)
	Bank:Unmark(Txid)

	T:Advance(Tx.LEG_TIMEOUT * Tx.MAX_LEGS + 1)
	Bank.Store:Resettle("loneA"):Wait()

	T:Is("the leg a coordinator never decided", Bank:Pending("loneA"), false)
	T:Is("gold on the key", Bank:Amount("loneA"), 100)
end)

Cases.Case("a buried marker is reaped once it is old enough", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("reapA", { Gold = 100 })
	Bank:Marker("reap1", { Status = "Committed", Total = 2, Gen = "reapg", At = T:Now(), Adopted = {}, Dead = true })

	T:Advance(Tx.REAP_HORIZON + 60)
	local Reaped = Bank.Store:ReapMarkers()

	T:Is("the buried marker was reaped", Reaped, 1)
	T:Is("nothing is left of it", Bank:Mark("reap1"), nil)
end)

Cases.Case("a finished marker goes sooner than one still being decided", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("graceA", { Gold = 100 })
	Bank:Marker("gracedone", { Status = "Committed", Total = 1, Gen = "graceg", At = T:Now(), Adopted = {}, Dead = true })
	Bank:Marker("gracewait", {
		Status = "Committed",
		Total = 1,
		Gen = "graceg",
		At = T:Now(),
		Adopted = {},
		Keys = Mark.Pack({ Mark.Of(Bank.Data, "graceA") }),
	})

	T:Advance(Tx.REAP_GRACE + 60)
	local Early = Bank.Store:ReapMarkers()

	T:Is("the finished marker goes on the short window", Early, 1)
	T:Is("nothing is left of it", Bank:Mark("gracedone"), nil)
	T:Is("the one still being decided stays", type(Bank:Mark("gracewait")), "table")

	T:Advance(Tx.REAP_HORIZON + 60)
	local Late = Bank.Store:ReapMarkers()

	T:Is("it goes once the long window runs out", Late, 1)
	T:Is("nothing is left of that one either", Bank:Mark("gracewait"), nil)
	T:Is("gold is untouched", Bank:Amount("graceA"), 100)
end)

Cases.Case("an orphan leg past a shrunk marker is rolled back", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "orphA", 100, false)
	Vault:Seed("orphB", { Coins = 0 })

	Vault:NoRetries()
	Vault:Fault(Fault.Updates():Only(1):Swallow())
	local Ok = Cross(Shop, Vault, "orphA", "orphB", 25, "orph1")
	Vault:Healed()

	local Orphan = Vault:Pending("orphB")
	local Marker = Shop:Buried("orph1")

	T:Advance(Tx.LEG_TIMEOUT * Tx.MAX_LEGS + 1)
	Vault.Store:Resettle("orphB"):Wait()

	T:Is("a transaction whose second leg landed but reported failure", Ok, false)
	T:Is("the leg it left behind past the shrunk marker", Orphan, true)
	T:Is("the marker, already adopted by every leg it owns", Marker, true)
	T:Is("gold in the shop", Shop:State("orphA").Gold, 100)
	T:Is("coins in the vault", Vault:State("orphB").Coins, 0)
	T:Is("anything left pending in the shop", Shop:Pending("orphA"), false)
	T:Is("anything left pending in the vault", Vault:Pending("orphB"), false)
end)

Cases.Case("a retry after the leg ids are forgotten moves nothing twice", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "forgetA", 100, false)
	Vault:Seed("forgetB", { Coins = 0 })

	local First = Cross(Shop, Vault, "forgetA", "forgetB", 25, "forget1")
	local Remembered = Shop:Stored("forgetA")._Received["x:forget1"] ~= nil

	Shop:Forget("forgetA", { "tx:forget1:" })
	Vault:Forget("forgetB", { "tx:forget1:" })

	local Retried, Why = Cross(Shop, Vault, "forgetA", "forgetB", 25, "forget1")

	T:Is("the first attempt", First, true)
	T:Is("the transaction is remembered under its own name", Remembered, true)
	T:Is("a retry once every leg id is forgotten", Retried, true)
	T:Is("the reason", Why, nil)
	T:Is("gold in the shop, moved exactly once", Shop:State("forgetA").Gold, 75)
	T:Is("coins in the vault, moved exactly once", Vault:State("forgetB").Coins, 25)
	T:Is("anything left pending in the shop", Shop:Pending("forgetA"), false)
	T:Is("anything left pending in the vault", Vault:Pending("forgetB"), false)
end)

Cases.Case("a retry only half the keys remember is refused", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "halfA", 100, false)
	Vault:Seed("halfB", { Coins = 0 })

	local First = Cross(Shop, Vault, "halfA", "halfB", 25, "half1")
	Shop:Forget("halfA", { "tx:half1:" })
	Vault:Forget("halfB", { "tx:half1:" })

	Shop.Direct:UpdateAsync("halfA", function(Current: any): any
		local Snapshot: any = if type(Current) == "table" then Current.Snapshot else nil
		if Snapshot == nil then
			return nil
		end
		Snapshot._Received = nil
		return Current
	end)

	local Retried, Why = Cross(Shop, Vault, "halfA", "halfB", 25, "half1")

	T:Is("the first attempt", First, true)
	T:Is("a retry only one of the two keys still remembers", Retried, false)
	T:Is("the reason", Why, "Spent")
	T:Is("gold in the shop, moved exactly once", Shop:State("halfA").Gold, 75)
	T:Is("coins in the vault, moved exactly once", Vault:State("halfB").Coins, 25)
	T:Is("anything left pending in the shop", Shop:Pending("halfA"), false)
	T:Is("anything left pending in the vault", Vault:Pending("halfB"), false)
end)

Cases.Case("a leg reads the stored record and not what a session is holding", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("held", { Gold = 0, Touches = 0 })
	Bank:Seed("other", { Gold = 0, Touches = 0 })

	local Active = Bank:Session("held")
	Active:Apply("Fund", { Amount = 500 })

	local Legs = {
		{ Key = "held", Kind = "Give", Fields = { Amount = -100 } },
		{ Key = "other", Kind = "Fund", Fields = { Amount = 100 } },
	}
	local Early, EarlyWhy = Bank.Store:Tx("unflushed", Legs):Wait()

	T:Is("the gold the session is holding", Active:Get().Gold, 500)
	T:Is("the gold the record carries", Bank:Amount("held"), 0)
	T:Is("a transaction against ops the session has not written", Early, false)
	T:Is("the reason", EarlyWhy, "Refused")

	Active:Flush():Wait()
	local Late = Bank.Store:Tx("flushed", Legs):Wait()

	T:Is("the same transaction once the session flushed", Late, true)
	T:Is("gold on the key the leg spent from", Bank:Amount("held"), 400)
	T:Is("gold on the other key", Bank:Amount("other"), 100)
end)

Cases.Case("a session sees a committed leg once it flushes and not before", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("held", { Gold = 0, Touches = 0 })
	Bank:Seed("other", { Gold = 100, Touches = 0 })

	local Active = Bank:Session("held")
	local Heard = 0
	Active:Observe():Subscribe(function()
		Heard += 1
	end)

	local Sent = Bank.Store
		:Tx("paid", {
			{ Key = "held", Kind = "Fund", Fields = { Amount = 25 } },
			{ Key = "other", Kind = "Give", Fields = { Amount = -25 } },
		})
		:Wait()

	T:Is("the transaction", Sent, true)
	T:Is("gold the record carries straight after", Bank:Amount("held"), 25)
	T:Is("gold the open session reports", Active:Get().Gold, 0)
	T:Is("observers woken by a leg the session did not make", Heard, 0)

	Active:Flush():Wait()

	T:Is("gold the session reports once it flushed", Active:Get().Gold, 25)
	T:Is("observers woken by the flush", Heard, 1)
end)

Cases.Case("a transaction that leaves a leg parked follows that key", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 500, Touches = 0 })
	Bank:Seed("b", { Gold = 500, Touches = 0 })

	Bank:Fault(Fault.Updates():OnKey("b"))
	Bank:MarkerFault(Fault.Updates():After(2))
	local Sent, Why = Bank.Store
		:Tx("stranded", {
			{ Key = "a", Kind = "Give", Fields = { Amount = -50 } },
			{ Key = "b", Kind = "Give", Fields = { Amount = 50 } },
		})
		:Wait()
	Bank:Healed()

	T:Is("the transaction", Sent, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("a leg left parked on the key that prepared", Bank:Pending("a"), true)
	T:Is("keys it left the sweep following", Registry.Sweep.Count, 2)

	T:Advance(Tx.TIMEOUT + 60)
	T:Sweep()

	T:Is("anything left parked once the sweep ran on its own", Bank:Pending("a"), false)
	T:Is("gold across both keys", Bank:Amount("a") + Bank:Amount("b"), 1000)

	Registry.Sweep:Forget(Bank.Store)
end)

Cases.Case("a transaction that committed but could not resolve a leg follows that key", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("k", { Gold = 500, Touches = 0 })
	Bank:Seed("l", { Gold = 0, Touches = 0 })

	Bank:NoRetries()
	Bank:Fault(Fault.Updates():OnKey("l"):After(1))
	local Sent = Bank.Store
		:Tx("halfdone", {
			{ Key = "k", Kind = "Give", Fields = { Amount = -50 } },
			{ Key = "l", Kind = "Fund", Fields = { Amount = 50 } },
		})
		:Wait()
	Bank:Healed()

	T:Is("the transaction", Sent, true)
	T:Is("the leg whose resolve was lost", Bank:Pending("l"), true)
	T:Is("keys it left the sweep following", Registry.Sweep.Count, 2)

	T:Sweep()
	T:Is("anything left parked once the sweep ran", Bank:Pending("l"), false)
	T:Is("gold on the key it paid", Bank:Amount("l"), 50)

	Registry.Sweep:Forget(Bank.Store)
end)

Cases.Case("a transaction that parked nothing follows no keys", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("i", { Gold = 500, Touches = 0 })
	Bank:Seed("j", { Gold = 0, Touches = 0 })

	local Committed = Bank.Store
		:Tx("fine", {
			{ Key = "i", Kind = "Give", Fields = { Amount = -50 } },
			{ Key = "j", Kind = "Fund", Fields = { Amount = 50 } },
		})
		:Wait()

	T:Is("a transaction that committed cleanly", Committed, true)
	T:Is("keys it left the sweep following", Registry.Sweep.Count, 0)

	local Refused, Why = Bank.Store
		:Tx("rolled", {
			{ Key = "i", Kind = "Give", Fields = { Amount = -50 } },
			{ Key = "j", Kind = "Give", Fields = { Amount = -100000 } },
		})
		:Wait()

	T:Is("a transaction rolled back after its first leg prepared", Refused, false)
	T:Is("the reason", Why, "Refused")
	T:Is("anything left parked", Bank:Pending("i"), false)
	T:Is("keys it left the sweep following", Registry.Sweep.Count, 0)

	Registry.Sweep:Forget(Bank.Store)
end)

Cases.Case("a session loads even when it cannot settle", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("unsettled", { Gold = 0 })
	Bank:Marker("unsettled1", { Status = "Committed", Total = 1, Adopted = {} })
	Bank:Park("unsettled", { Id = "tx:unsettled1:1", Kind = "Give", Amount = 25, Tx = "unsettled1" })

	Bank:Fault(Fault.Updates())
	local Job = Session.Load(Bank:Log(), Bank:Format(), "unsettled", Bank.Store.TxWrapper)
	local Active: any = Job:Wait()
	Bank:Healed()

	T:Is("the load finished", Job:Happened(), true)
	T:Is("a session was handed back", Active ~= nil, true)
	T:Is("the gold it reports while the leg is unsettled", if Active then Active:Get().Gold else nil, 0)
	T:Is("the leg is still pending on disk", Bank:Pending("unsettled"), true)

	Bank.Store:Resettle("unsettled"):Wait()
	T:Is("gold once the key can be written again", Bank:Amount("unsettled"), 25)
	T:Is("anything left pending", Bank:Pending("unsettled"), false)
end)

Cases.Case("a leg settles against a marker in another store", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "homeA", 100, false)
	Vault:Seed("homeB", { Coins = 0 })

	Shop:Marker("home1", { Status = "Committed", Total = 2, Adopted = {} })
	Shop:Park("homeA", { Id = "tx:home1:1", Kind = "Delta", Gold = -25, Tx = "home1" })
	Vault:Park("homeB", { Id = "tx:home1:2", Kind = "Vault", Coins = 25, Tx = "home1", TxHome = Shop.Marked })

	Vault.Store:Resettle("homeB"):Wait()
	Shop.Store:Resettle("homeA"):Wait()

	T:Is("the vault's own marker table stayed out of it", Vault:Mark("home1"), nil)
	T:Is("coins in the vault, settled against a marker it does not keep", Vault:State("homeB").Coins, 25)
	T:Is("gold in the shop", Shop:State("homeA").Gold, 75)
	T:Is("anything left pending in the vault", Vault:Pending("homeB"), false)
	T:Is("anything left pending in the shop", Shop:Pending("homeA"), false)
	T:Is("the finished marker is buried", Shop:Buried("home1"), true)
end)

Cases.Case("a pass that reaches no key never disowns an earlier pass", function(T: Case)
	local Shop = T:Market()
	Wares(Shop, "brickA", 100, true)
	Wares(Shop, "brickB", 100, false)

	Shop:NoRetries()
	Shop:MarkerFault(Fault.Updates():Only(3))
	Shop:Fault(Fault.Reads():OnKey("brickA"):After(1))
	Shop:Fault(Fault.Updates():OnKey("brickA"):After(1))

	local Ok = Swap(Shop, "brickA", "brickB", 25, "brick1")

	Shop:Healed()
	T:Advance(Tx.LEG_TIMEOUT * Tx.MAX_LEGS + 1)
	Shop.Store:Resettle("brickA"):Wait()
	Shop.Store:Resettle("brickB"):Wait()

	T:Is("a transaction whose decision was lost and whose retry could not reach a key", Ok, false)
	T:Is("anything left pending on the first key", Shop:Pending("brickA"), false)
	T:Is("anything left pending on the second key", Shop:Pending("brickB"), false)
	T:Is("the seller's gold", Shop:State("brickA").Gold, 100)
	T:Is("the seller keeps the sword", Shop:State("brickA").Items.Sword, true)
	T:Is("the buyer's gold", Shop:State("brickB").Gold, 100)
end)

Cases.Case("a cross store marker left behind is still reaped", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "reapA", 100, false)
	Vault:Seed("reapB", { Coins = 0 })

	Shop:MarkerFault(Fault.Removes())
	local Ok = Cross(Shop, Vault, "reapA", "reapB", 25, "reap1")
	Shop:Healed()

	local Left = Shop:Mark("reap1")

	T:Advance(Tx.REAP_HORIZON + 1)
	Shop.Store:ReapMarkers()
	Vault.Store:ReapMarkers()

	T:Is("a cross store transaction whose marker could not be removed", Ok, true)
	T:Is("the marker it could not remove", type(Left), "table")
	T:Is("gold in the shop", Shop:State("reapA").Gold, 75)
	T:Is("coins in the vault", Vault:State("reapB").Coins, 25)
	T:Is("the leftover marker once a reap runs", Shop:Mark("reap1"), nil)
end)

Cases.Case("a marker naming a delimiter key is still reaped", function(T: Case)
	local Bank = T:Bank()
	local A, B = "de\1limA", "plainB"
	Bank:Seed(A, { Gold = 100 })
	Bank:Seed(B, { Gold = 100 })

	Bank:MarkerFault(Fault.Removes())
	local Ok = Bank.Store
		:Tx("delim1", {
			{ Key = A, Kind = "Give", Fields = { Amount = -25 } },
			{ Key = B, Kind = "Give", Fields = { Amount = 25 } },
		})
		:Wait()
	Bank:Healed()

	local Left = Bank:Mark("delim1")

	T:Advance(Tx.REAP_HORIZON + 1)
	Bank.Store:ReapMarkers()

	T:Is("a transaction touching a key that holds a delimiter byte", Ok, true)
	T:Is("the marker its adoption could not remove", type(Left), "table")
	T:Is("gold on the sending key", Bank:Amount(A), 75)
	T:Is("gold on the receiving key", Bank:Amount(B), 125)
	T:Is("the leftover marker once a reap runs", Bank:Mark("delim1"), nil)
end)

Cases.Case("a marker with unprefixed keys is still reaped", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("unprefixed", { Gold = 100 })
	Bank:Marker("unpref1", {
		Status = "Committed",
		Total = 1,
		Gen = "one",
		At = T:Now(),
		Adopted = {},
		Keys = `{Bank.Data}\0unprefixed`,
	})

	T:Advance(Tx.REAP_HORIZON + 1)
	Bank.Store:ReapMarkers()

	T:Is("a marker whose keys were packed without length prefixes", Bank:Mark("unpref1"), nil)
	T:Is("gold is untouched", Bank:Amount("unprefixed"), 100)
end)

Cases.Case("a session settles a leg homed in another store", function(T: Case)
	local Bank = T:Bank()
	local Away = T:Store({ Default = Suite.Reducers.MONEY, Reducer = Suite.Reducers.Banker, Balance = "Gold", Data = "CaseAway" })

	Bank:Seed("foreign", { Gold = 0 })
	Away:Marker("foreign1", { Status = "Committed", Total = 1, Adopted = {} })
	Bank:Park("foreign", { Id = "tx:foreign1:1", Kind = "Give", Amount = 25, Tx = "foreign1", TxHome = Away.Marked })

	local Active: any = Bank:Session("foreign")
	local Loaded = Active:Get().Gold
	local Applied = Active:Apply("Give", { Amount = 5 })
	Active:Release():Wait()

	T:Is("the gold a session loads once it follows the leg home", Loaded, 25)
	T:Is("an edit on top of it", Applied, true)
	T:Is("gold on disk", Bank:Amount("foreign"), 30)
	T:Is("anything left pending", Bank:Pending("foreign"), false)
	T:Is("the finished marker is buried", Away:Buried("foreign1"), true)
end)

Cases.Case("a key held by another coordinator is busy", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "coordA", 100, false)
	Vault:Seed("coordB", { Coins = 50 })

	Shop:Marker("held1", { Status = "Pending", Total = 2, Adopted = {} })
	Shop:Park("coordA", { Id = "tx:held1:1", Kind = "Delta", Gold = 5, Tx = "held1" })

	local Ok, Why = Vault.Store
		:Tx("coord1", {
			{ Key = "coordB", Kind = "Vault", Fields = { Coins = -10 } },
			{ Key = "coordA", Kind = "Delta", Fields = { Gold = 10 }, Store = Shop.Store },
		})
		:Wait()
	local Stuck = Shop:Pending("coordA")

	T:Advance(Tx.TIMEOUT + 1)
	Shop.Store:Resettle("coordA"):Wait()

	T:Is("a transaction onto a key another coordinator is holding", Ok, false)
	T:Is("the reason", Why, "Busy")
	T:Is("the other coordinator's leg is left alone", Stuck, true)
	T:Is("gold in the shop", Shop:State("coordA").Gold, 100)
	T:Is("coins in the vault", Vault:State("coordB").Coins, 50)
	T:Is("anything left pending in the shop", Shop:Pending("coordA"), false)
	T:Is("anything left pending in the vault", Vault:Pending("coordB"), false)
end)

Cases.Case("a marker naming a store this server never built is still reaped", function(T: Case)
	local Shop, Vault = T:Market(), T:Vault()
	Wares(Shop, "farA", 100, false)
	Vault:Seed("farB", { Coins = 0 })

	local Ok = Shop.Store
		:Tx("far1", {
			{ Key = "farA", Kind = "Delta", Fields = { Gold = -25 } },
			{ Key = "farB", Kind = "Vault", Fields = { Coins = 25 }, Store = Vault.Store },
		})
		:Wait()

	Shop:Marker("farstale", {
		Status = "Committed",
		Total = 2,
		Gen = "farg",
		At = T:Now(),
		Keys = Mark.Pack({ Mark.Of(Shop.Data, "farA"), Mark.Of(Vault.Data, "farB") }),
	})
	T:Advance(Tx.REAP_HORIZON + 60)

	for Index = #Registry.Stores, 1, -1 do
		if Registry.Stores[Index] == Vault.Store then
			table.remove(Registry.Stores, Index)
		end
	end

	local Reaped = Shop.Store:ReapMarkers()

	T:Is("the transaction across two stores", Ok, true)
	T:Is("markers reaped by a server missing the far store", Reaped, 2)
	T:Is("gold in the shop", Shop:State("farA").Gold, 75)
	T:Is("coins in the vault", Vault:State("farB").Coins, 25)
end)

return Cases
