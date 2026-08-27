--!strict
--!optimize 2

--[=[
	Escrow: One rule per case for the money path, reserve deliver settle.

	A transfer is three writes on two keys. The money leaves the sender into a hold, it is paid in on
	the receiver, and the hold clears last. That order is the design, because clearing the hold first
	would let a server that stopped destroy the money.
	A name means one move for good. Recovery decides an unfinished one by asking the receiver, and
	the tombstone cases are about money sent to a key that was erased.

	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, and it runs the next time you press play.
--]=]

local Suite = require("../Suite")

local Fault = Suite.Fault
local Insides = Suite.Insides
local Reducers = Suite.Reducers

local Log = Insides.Log
local Recovery = Insides.Recovery
local Transfer = Insides.Transfer
local Tx = Insides.Tx

type Case = Suite.Case
type Fixture = Suite.Fixture

local DAY = 86400
local PAST_REDRIVE = 9 * DAY
local PAST_PRUNE = 31 * DAY

local Cases = Suite.File("Escrow")

local function Deliver(Bank: Fixture, To: string, Tid: string, Amount: number, At: number, Mark: string?)
	Bank:Append(To, {
		{ Id = Mark or `del:{Tid}`, Kind = "__TransferDeliver", Tid = Tid, Amount = Amount, At = At } :: any,
	})
end

local function Reserve(Bank: Fixture, From: string, To: string, Amount: number, Id: string?): string
	return (Transfer.Reserve(Bank:Log(), Bank:Format(), From, To, Amount, Id) :: any).Tid
end

local function Funded(T: Case, Amounts: { [string]: number }): Fixture
	local Bank = T:Bank()
	for Key, Gold in Amounts do
		Bank:Seed(Key, { Gold = Gold })
	end
	return Bank
end

Cases.Case("a transfer moves the money and holds nothing back", function(T: Case)
	local Bank = Funded(T, { payA = 100, payB = 0 })

	local Ok, Why = Bank.Store:Transfer("payA", "payB", 50):Wait()

	T:Is("the transfer", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("gold on the sender", Bank:Amount("payA"), 50)
	T:Is("gold on the receiver", Bank:Amount("payB"), 50)
	T:Is("anything still set aside", Bank:Aside("payA"), 0)
	T:Is("money is conserved", Bank:Amount("payA") + Bank:Amount("payB") + Bank:Aside("payA"), 100)
end)

Cases.Case("a transfer the sender cannot afford is refused", function(T: Case)
	local Bank = Funded(T, { poorA = 30, poorB = 0 })

	local Ok, Why = Bank.Store:Transfer("poorA", "poorB", 50):Wait()

	T:Is("a transfer the sender cannot afford", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("gold on the sender", Bank:Amount("poorA"), 30)
	T:Is("gold on the receiver", Bank:Amount("poorB"), 0)
	T:Is("anything set aside by a refusal", Bank:Aside("poorA"), 0)
end)

Cases.Case("money set aside is finished by recovery", function(T: Case)
	local Bank = Funded(T, { asideA = 100, asideB = 0 })

	Reserve(Bank, "asideA", "asideB", 50)

	T:Is("gold left to the sender once the money is set aside", Bank:Amount("asideA"), 50)
	T:Is("the amount set aside", Bank:Aside("asideA"), 50)
	T:Is("gold on the receiver before recovery", Bank:Amount("asideB"), 0)

	Bank.Store:RecoverTransfers("asideA"):Wait()

	T:Is("gold on the sender", Bank:Amount("asideA"), 50)
	T:Is("gold on the receiver", Bank:Amount("asideB"), 50)
	T:Is("anything still set aside", Bank:Aside("asideA"), 0)
	T:Is("money is conserved", Bank:Amount("asideA") + Bank:Amount("asideB") + Bank:Aside("asideA"), 100)
end)

Cases.Case("a hold with no timestamp is given back rather than written off", function(T: Case)
	local Bank = Funded(T, { stampA = 100, stampB = 0 })

	Bank:Append("stampA", {
		{ Id = "res:noat", Kind = "__TransferReserve", To = "stampB", Amount = 40, Tid = "noat" } :: any,
	})

	T:Is("the amount set aside before recovery", Bank:Aside("stampA"), 40)
	T:Is("gold on the sender before recovery", Bank:Amount("stampA"), 60)

	Bank.Store:RecoverTransfers("stampA"):Wait()

	T:Is("gold given back when the hold has no time on it", Bank:Amount("stampA"), 100)
	T:Is("anything still set aside", Bank:Aside("stampA"), 0)
	T:Is("gold on the receiver", Bank:Amount("stampB"), 0)
	T:Is("money is conserved", Bank:Amount("stampA") + Bank:Amount("stampB"), 100)
end)

Cases.Case("recovering three times delivers once", function(T: Case)
	local Bank = Funded(T, { twiceA = 100, twiceB = 0 })

	Reserve(Bank, "twiceA", "twiceB", 50)
	local Holds = Bank:State("twiceA")._Held

	Transfer.Recover(Bank:Log(), Bank:Format(), "twiceA", Holds)
	Transfer.Recover(Bank:Log(), Bank:Format(), "twiceA", Holds)
	Transfer.Recover(Bank:Log(), Bank:Format(), "twiceA", Holds)

	T:Is("gold on the receiver after three recoveries of one hold", Bank:Amount("twiceB"), 50)
	T:Is("gold on the sender", Bank:Amount("twiceA"), 50)
	T:Is("anything still set aside", Bank:Aside("twiceA"), 0)
end)

Cases.Case("a redelivery under a new op id cannot mint", function(T: Case)
	local Bank = Funded(T, { mintB = 0 })
	local Now = T:Now()

	local Batch: { any } = { { Id = "del:first", Kind = "__TransferDeliver", Tid = "first", Amount = 100, At = Now } }
	for Index = 1, 1030 do
		table.insert(Batch, { Id = `del:pad{Index}`, Kind = "__TransferDeliver", Tid = `pad{Index}`, Amount = 0, At = Now })
	end
	Bank:Append("mintB", Batch)
	local Landed = Bank:Amount("mintB")

	Deliver(Bank, "mintB", "first", 100, Now, "del2:first")

	T:Is("gold after the delivery", Landed, 100)
	T:Is("gold after the same transfer arrives again under a new op id", Bank:Amount("mintB"), 100)
end)

Cases.Case("a game edit does not disturb money set aside", function(T: Case)
	local Bank = Funded(T, { editA = 100, editB = 0 })

	Reserve(Bank, "editA", "editB", 40)
	Bank.Store:Edit("editA", "Fund", { Amount = 10 }):Wait()

	T:Is("the amount still set aside after an edit", Bank:Aside("editA"), 40)
	T:Is("gold on the sender", Bank:Amount("editA"), 70)
end)

Cases.Case("recovery settles a hold the receiver already got", function(T: Case)
	local Bank = Funded(T, { gotA = 100, gotB = 0 })

	local Tid = Reserve(Bank, "gotA", "gotB", 60)
	Deliver(Bank, "gotB", Tid, 60, T:Now())

	T:Is("gold on the sender before recovery", Bank:Amount("gotA"), 40)
	T:Is("the amount set aside before recovery", Bank:Aside("gotA"), 60)
	T:Is("gold on the receiver before recovery", Bank:Amount("gotB"), 60)

	Bank.Store:RecoverTransfers("gotA"):Wait()

	T:Is("gold on the sender", Bank:Amount("gotA"), 40)
	T:Is("anything still set aside", Bank:Aside("gotA"), 0)
	T:Is("gold on the receiver, paid once", Bank:Amount("gotB"), 60)
	T:Is("money is conserved", Bank:Amount("gotA") + Bank:Amount("gotB") + Bank:Aside("gotA"), 100)
end)

Cases.Case("the record an append hands back sees the hold", function(T: Case)
	local Bank = Funded(T, { raceA = 100, raceB = 0 })
	local Tid = "race1"

	local Handed = Bank:Log():Append("raceA", {
		{ Id = `res:{Tid}`, Kind = "__TransferReserve", To = "raceB", Amount = 30, Tid = Tid, At = T:Now() } :: any,
	})
	Deliver(Bank, "raceB", Tid, 30, T:Now())
	Bank:Append("raceA", { { Id = `set:{Tid}`, Kind = "__TransferSettle", Tid = Tid, At = T:Now() } :: any })

	local Reread: any = Bank:Stored("raceA")
	local Snapshot: any = Bank:Format():Fold(Handed)

	T:Is("the hold on the record the append handed back", Snapshot._Held ~= nil and Snapshot._Held[Tid] ~= nil, true)
	T:Is("the hold on a re-read taken after the settle", Reread._Held ~= nil and Reread._Held[Tid] ~= nil, false)
	T:Is("gold on the receiver", Bank:Amount("raceB"), 30)
end)

Cases.Case("a redelivery after the tomb expires still pays once", function(T: Case)
	local Bank = Funded(T, { tombA = 100, tombB = 0 })

	local Tid = Reserve(Bank, "tombA", "tombB", 50)
	Deliver(Bank, "tombB", Tid, 50, T:Now())
	local Paid = Bank:Amount("tombB")

	Bank.Store:Erase("tombB"):Wait()
	T:Advance(PAST_REDRIVE)

	pcall(function()
		Transfer.Post(Bank:Log(), Bank:Format(), "tombA", Tid, "tombB", 50)
	end)

	T:Is("the receiver was paid once", Paid, 50)
	T:Is("the erase took the balance", Bank:Amount("tombB"), 0)
	T:Is("the tomb still remembers what was already paid", Bank:Stored("tombB")._Received ~= nil, true)
end)

Cases.Case("a transfer refused for funds can be asked again", function(T: Case)
	local Bank = Funded(T, { poorA = 100, poorB = 0 })

	local First, FirstWhy = Bank.Store:Transfer("poorA", "poorB", 500, "gift1"):Wait()
	Bank.Store:Edit("poorA", "Fund", { Amount = 1000 }):Wait()
	local Second, SecondWhy = Bank.Store:Transfer("poorA", "poorB", 500, "gift1"):Wait()

	T:Is("a transfer the sender cannot afford", First, false)
	T:Is("the reason", FirstWhy, "Refused")
	T:Is("the same name once they can afford it", Second, true)
	T:Is("the second reason", SecondWhy, nil)
	T:Is("gold on the sender", Bank:Amount("poorA"), 600)
	T:Is("gold on the receiver", Bank:Amount("poorB"), 500)
	T:Is("money is conserved", Bank:Amount("poorA") + Bank:Amount("poorB"), 1100)
end)

Cases.Case("a cleared delivery still stops the sender refunding", function(T: Case)
	local Bank = Funded(T, { mintA = 100, mintB = 0 })

	local Tid = Reserve(Bank, "mintA", "mintB", 50)
	Deliver(Bank, "mintB", Tid, 50, T:Now())

	Bank:Forget("mintB", { "del:" })
	T:Advance(PAST_REDRIVE)
	Bank.Store:ClearDelivered("mintB"):Wait()

	local Left: any = Bank:Stored("mintB")._Received
	T:Advance(DAY)
	Bank.Store:RecoverTransfers("mintA"):Wait()

	T:Is("the only evidence left once the op id has rolled out of seen", Left ~= nil and Left[`t:{Tid}`] ~= nil, true)
	T:Is("gold on the receiver, paid once", Bank:Amount("mintB"), 50)
	T:Is("anything still set aside on the sender", Bank:Aside("mintA"), 0)
	T:Is("money is conserved", Bank:Amount("mintA") + Bank:Amount("mintB") + Bank:Aside("mintA"), 100)
end)

Cases.Case("a transfer name reused once it landed is spent", function(T: Case)
	local Bank = Funded(T, { reuseA = 1000, reuseB = 100 })

	local First = (Bank.Store:Transfer("reuseA", "reuseB", 10, "tip1"):Wait())
	local Ok, Why = Bank.Store:Transfer("reuseA", "reuseB", 900, "tip1"):Wait()
	local Honest = (Bank.Store:Transfer("reuseA", "reuseB", 10, "tip1"):Wait())

	T:Is("the first transfer", First, true)
	T:Is("the same name for a different amount", Ok, false)
	T:Is("the reason", Why, "Spent")
	T:Is("an honest retry of the original terms", Honest, true)
	T:Is("gold on the sender", Bank:Amount("reuseA"), 990)
	T:Is("gold on the receiver", Bank:Amount("reuseB"), 110)
	T:Is("money is conserved", Bank:Amount("reuseA") + Bank:Amount("reuseB"), 1100)
end)

Cases.Case("a transfer name reused for another receiver is spent", function(T: Case)
	local Bank = Funded(T, { toA = 1000, toB = 0, toC = 0 })

	Bank.Store:Transfer("toA", "toB", 100, "gift1"):Wait()
	local Ok, Why = Bank.Store:Transfer("toA", "toC", 100, "gift1"):Wait()

	T:Is("the same name aimed at a different key", Ok, false)
	T:Is("the reason", Why, "Spent")
	T:Is("gold on the sender", Bank:Amount("toA"), 900)
	T:Is("gold on the key it was first sent to", Bank:Amount("toB"), 100)
	T:Is("gold on the key it was aimed at second", Bank:Amount("toC"), 0)
	T:Is("money is conserved", Bank:Amount("toA") + Bank:Amount("toB") + Bank:Amount("toC"), 1000)
end)

Cases.Case("clearing delivered evidence keeps the money", function(T: Case)
	local Bank = Funded(T, { clearA = 100, clearB = 0 })

	Bank.Store:Transfer("clearA", "clearB", 40):Wait()
	local Before = Bank:State("clearB")

	T:Advance(PAST_REDRIVE)
	Bank.Store:ClearDelivered("clearB"):Wait()
	local Early = Bank:State("clearB")

	T:Advance(PAST_PRUNE)
	Bank.Store:ClearDelivered("clearB"):Wait()
	local After = Bank:State("clearB")

	T:Is("the receiver remembered the delivery", type(Before._Received) == "table" and next(Before._Received) ~= nil, true)
	T:Is("gold before clearing", Before.Gold, 40)
	T:Is("the evidence while a refund could still fire", next(Early._Received) ~= nil, true)
	T:Is("the evidence once no refund can fire", After._Received == nil or next(After._Received) == nil, true)
	T:Is("gold after clearing", After.Gold, 40)
end)

Cases.Case("a hold older than the redrive window is given back", function(T: Case)
	local Bank = Funded(T, { oldA = 100, oldB = 0 })

	Reserve(Bank, "oldA", "oldB", 60)
	T:Advance(PAST_REDRIVE)
	Bank.Store:RecoverTransfers("oldA"):Wait()

	T:Is("gold given back to the sender", Bank:Amount("oldA"), 100)
	T:Is("anything still set aside", Bank:Aside("oldA"), 0)
	T:Is("gold on a receiver who never got it", Bank:Amount("oldB"), 0)
end)

Cases.Case("an old hold the receiver got is settled not given back", function(T: Case)
	local Bank = Funded(T, { landedA = 100, landedB = 0 })

	local Tid = Reserve(Bank, "landedA", "landedB", 60)
	Deliver(Bank, "landedB", Tid, 60, T:Now())

	T:Advance(PAST_REDRIVE)
	Bank.Store:RecoverTransfers("landedA"):Wait()

	T:Is("gold on the sender", Bank:Amount("landedA"), 40)
	T:Is("anything still set aside", Bank:Aside("landedA"), 0)
	T:Is("gold on the receiver", Bank:Amount("landedB"), 60)
	T:Is("money is conserved", Bank:Amount("landedA") + Bank:Amount("landedB") + Bank:Aside("landedA"), 100)
end)

Cases.Case("delivery evidence older than thirty days is forgotten", function(T: Case)
	local Bank = Funded(T, { windowB = 0 })

	local Stale = T:Now()
	Deliver(Bank, "windowB", "win1", 10, Stale)
	Deliver(Bank, "windowB", "win2", 10, Stale)

	T:Advance(PAST_PRUNE)
	Deliver(Bank, "windowB", "win3", 10, T:Now())

	local Sb = Bank:State("windowB")
	local Received: any = Sb._Received

	T:Is("gold after three deliveries", Sb.Gold, 30)
	T:Is("evidence of the first, now past the window", Received["t:win1"], nil)
	T:Is("evidence of the second, now past the window", Received["t:win2"], nil)
	T:Is("evidence of the fresh one", Received["t:win3"] ~= nil, true)
	T:Is("the unnamespaced key is never written", Received["win3"], nil)
end)

Cases.Case("an old hold whose evidence was forgotten still settles", function(T: Case)
	local Bank = Funded(T, { goneA = 100, goneB = 0 })

	local Tid = Reserve(Bank, "goneA", "goneB", 60)
	Deliver(Bank, "goneB", Tid, 60, T:Now())

	T:Advance(PAST_PRUNE)
	Deliver(Bank, "goneB", "fresh", 0, T:Now())

	local Mid: any = Bank:Stored("goneB")._Received
	local Forgotten = Mid == nil or Mid[`t:{Tid}`] == nil

	Bank.Store:RecoverTransfers("goneA"):Wait()

	T:Is("the receiver has forgotten the transfer", Forgotten, true)
	T:Is("gold on the sender", Bank:Amount("goneA"), 40)
	T:Is("anything still set aside", Bank:Aside("goneA"), 0)
	T:Is("gold on the receiver, paid once", Bank:Amount("goneB"), 60)
	T:Is("money is conserved", Bank:Amount("goneA") + Bank:Amount("goneB") + Bank:Aside("goneA"), 100)
end)

Cases.Case("a hold survives a reducer that clones the state", function(T: Case)
	local function Cloning(State: any, Op: any): any?
		if Op.Kind ~= "Fund" then
			return nil
		end
		local Next = table.clone(State)
		Next.Gold += Op.Amount
		return Next
	end

	local Bank = T:Store({ Default = Reducers.MONEY, Reducer = Cloning, Balance = "Gold" })
	Bank:Seed("cloneA", { Gold = 100 })
	Bank:Seed("cloneB", { Gold = 0 })

	Reserve(Bank, "cloneA", "cloneB", 40)
	Bank.Store:Edit("cloneA", "Fund", { Amount = 10 }):Wait()

	T:Is("the amount still set aside", Bank:Aside("cloneA"), 40)
	T:Is("gold on the sender", Bank:Amount("cloneA"), 70)
end)

Cases.Case("a delivery is remembered through the transaction wrap", function(T: Case)
	local Bank = Funded(T, { wrapA = 100, wrapB = 0 })

	Bank.Store:Transfer("wrapA", "wrapB", 40):Wait()
	local Delivered = Bank:State("wrapB")
	local Marked: string = next(Delivered._Received) :: any
	local Tid = string.sub(Marked, 3)

	Bank.Store:Edit("wrapB", "Fund", { Amount = 5 }):Wait()
	local Plain = Bank:State("wrapB")

	Deliver(Bank, "wrapB", Tid, 40, T:Now(), `del2:{Tid}`)

	T:Is("gold once the transfer lands", Delivered.Gold, 40)
	T:Is("the delivery is remembered under the transfer namespace", string.sub(Marked, 1, 2), "t:")
	T:Is("gold after a plain edit", Plain.Gold, 45)
	T:Is("the edit kept the evidence", Plain._Received[Marked] ~= nil, true)
	T:Is("gold after the same transfer arrives again", Bank:Amount("wrapB"), 45)
end)

Cases.Case("a retry finishes an escrow left behind", function(T: Case)
	local Bank = Funded(T, { leftA = 100, leftB = 0 })

	Reserve(Bank, "leftA", "leftB", 40, "left1")

	T:Is("gold left to the sender while it is set aside", Bank:Amount("leftA"), 60)
	T:Is("the amount set aside", Bank:Aside("leftA"), 40)

	local Retried, Why = Bank.Store:Transfer("leftA", "leftB", 40, "left1"):Wait()

	T:Is("the retry under the same name", Retried, true)
	T:Is("the reason", Why, nil)
	T:Is("gold on the sender", Bank:Amount("leftA"), 60)
	T:Is("gold on the receiver", Bank:Amount("leftB"), 40)
	T:Is("anything still set aside", Bank:Aside("leftA"), 0)
	T:Is("money is conserved", Bank:Amount("leftA") + Bank:Amount("leftB") + Bank:Aside("leftA"), 100)
end)

Cases.Case("the same transfer name moves the money once", function(T: Case)
	local Bank = Funded(T, { onceA = 100, onceB = 0 })

	local First, FirstWhy = Bank.Store:Transfer("onceA", "onceB", 40, "once1"):Wait()
	local Second, SecondWhy = Bank.Store:Transfer("onceA", "onceB", 40, "once1"):Wait()
	local Third = Bank.Store:Transfer("onceA", "onceB", 40, "once1"):Wait()

	T:Is("the first attempt", First, true)
	T:Is("the reason", FirstWhy, nil)
	T:Is("the second attempt under the same name", Second, true)
	T:Is("the second reason", SecondWhy, nil)
	T:Is("the third attempt under the same name", Third, true)
	T:Is("gold on the sender, moved exactly once", Bank:Amount("onceA"), 60)
	T:Is("gold on the receiver, moved exactly once", Bank:Amount("onceB"), 40)
	T:Is("anything still set aside", Bank:Aside("onceA"), 0)
end)

Cases.Case("a retry after the hold was given back is refused", function(T: Case)
	local Bank = Funded(T, { spentA = 100, spentB = 0 })

	Reserve(Bank, "spentA", "spentB", 60, "spent1")
	T:Advance(PAST_REDRIVE)
	Bank.Store:RecoverTransfers("spentA"):Wait()

	T:Is("gold given back", Bank:Amount("spentA"), 100)
	T:Is("anything still set aside after the refund", Bank:Aside("spentA"), 0)

	local Retried, Why = Bank.Store:Transfer("spentA", "spentB", 60, "spent1"):Wait()

	T:Is("a retry under a name that was already given back", Retried, false)
	T:Is("the reason", Why, "Spent")
	T:Is("gold on the sender", Bank:Amount("spentA"), 100)
	T:Is("gold on the receiver", Bank:Amount("spentB"), 0)
end)

Cases.Case("a retry after the sender forgets moves nothing twice", function(T: Case)
	local Bank = Funded(T, { amnesiaA = 100, amnesiaB = 0 })

	Bank.Store:Transfer("amnesiaA", "amnesiaB", 40, "amnesia1"):Wait()
	Bank:Forget("amnesiaA", { "res:amnesia1", "set:amnesia1", "exp:amnesia1" })

	local Retried = Bank.Store:Transfer("amnesiaA", "amnesiaB", 40, "amnesia1"):Wait()

	T:Is("the retry once the sender has forgotten its own ops", Retried, true)
	T:Is("gold on the sender, moved exactly once", Bank:Amount("amnesiaA"), 60)
	T:Is("gold on the receiver, moved exactly once", Bank:Amount("amnesiaB"), 40)
	T:Is("anything still set aside", Bank:Aside("amnesiaA"), 0)
	T:Is("money is conserved", Bank:Amount("amnesiaA") + Bank:Amount("amnesiaB") + Bank:Aside("amnesiaA"), 100)
end)

Cases.Case("a retry after both sides forget moves nothing twice", function(T: Case)
	local Bank = Funded(T, { bothA = 100, bothB = 0 })

	Bank:Append("bothA", {
		{ Id = "res:both1", Kind = "__TransferReserve", To = "bothB", Amount = 40, Tid = "both1", At = T:Now() } :: any,
	})
	Deliver(Bank, "bothB", "both1", 40, T:Now())
	Bank:Append("bothA", { { Id = "set:both1", Kind = "__TransferSettle", Tid = "both1", At = T:Now() } :: any })

	T:Advance(PAST_PRUNE)
	Deliver(Bank, "bothB", "fresher", 0, T:Now())
	local Mid: any = Bank:Stored("bothB")._Received
	local Forgotten = Mid == nil or Mid["t:both1"] == nil

	Bank:Forget("bothA", { "res:both1", "set:both1", "exp:both1" })

	local Retried = Bank.Store:Transfer("bothA", "bothB", 40, "both1"):Wait()

	T:Is("the receiver has forgotten the transfer", Forgotten, true)
	T:Is("the retry once neither side remembers", Retried, true)
	T:Is("gold on the sender", Bank:Amount("bothA"), 60)
	T:Is("gold on the receiver", Bank:Amount("bothB"), 40)
	T:Is("money is conserved", Bank:Amount("bothA") + Bank:Amount("bothB") + Bank:Aside("bothA"), 100)
end)

Cases.Case("a transfer with no name moves every time", function(T: Case)
	local Bank = Funded(T, { unnamedA = 100, unnamedB = 0 })

	Bank.Store:Transfer("unnamedA", "unnamedB", 40):Wait()
	Bank.Store:Transfer("unnamedA", "unnamedB", 40):Wait()

	T:Is("gold on the sender after two unnamed transfers", Bank:Amount("unnamedA"), 20)
	T:Is("gold on the receiver", Bank:Amount("unnamedB"), 80)
	T:Is("money is conserved", Bank:Amount("unnamedA") + Bank:Amount("unnamedB") + Bank:Aside("unnamedA"), 100)
end)

Cases.Case("a key a transaction is holding refuses a transfer", function(T: Case)
	local Bank = Funded(T, { busyA = 100, busyB = 0 })

	Bank:Marker("busytx1", { Status = "Pending", Total = 2, Gen = "one", Adopted = {} })
	Bank:Park("busyA", { Id = "tx:busytx1:1", Kind = "Give", Amount = 0, Tx = "busytx1" })

	local Ok, Why = Bank.Store:Transfer("busyA", "busyB", 40):Wait()

	T:Is("a transfer off a key a transaction is holding", Ok, false)
	T:Is("the reason", Why, "Busy")
	T:Is("gold on the sender", Bank:Amount("busyA"), 100)
	T:Is("gold on the receiver", Bank:Amount("busyB"), 0)
	T:Is("anything set aside", Bank:Aside("busyA"), 0)
end)

Cases.Case("a retry honours the amount already set aside", function(T: Case)
	local Bank = Funded(T, { termsA = 500, termsB = 0 })

	Reserve(Bank, "termsA", "termsB", 10, "terms1")
	local Ok, Why = Bank.Store:Transfer("termsA", "termsB", 1000, "terms1"):Wait()

	T:Is("a retry asking for a different amount", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("gold on the sender, charged the escrowed amount", Bank:Amount("termsA"), 490)
	T:Is("gold on the receiver, paid the escrowed amount", Bank:Amount("termsB"), 10)
	T:Is("anything still set aside", Bank:Aside("termsA"), 0)
	T:Is("money is conserved", Bank:Amount("termsA") + Bank:Amount("termsB") + Bank:Aside("termsA"), 500)
end)

Cases.Case("a retry honours the receiver already set aside", function(T: Case)
	local Bank = Funded(T, { whoA = 100, whoB = 0, whoC = 0 })

	Reserve(Bank, "whoA", "whoB", 40, "who1")
	Bank.Store:Transfer("whoA", "whoC", 40, "who1"):Wait()

	T:Is("gold to the escrowed receiver", Bank:Amount("whoB"), 40)
	T:Is("gold to the receiver named on the retry", Bank:Amount("whoC"), 0)
	T:Is("money is conserved", Bank:Amount("whoA") + Bank:Amount("whoB") + Bank:Amount("whoC") + Bank:Aside("whoA"), 100)
end)

Cases.Case("a transfer that took the money but could not hand it over is recovered", function(T: Case)
	local Bank = Funded(T, { stuckA = 100, stuckB = 0 })

	Bank:Fault(Fault.Updates():After(1))
	local Ok, Why, Escrowed = Transfer.Drive(Bank:Log(), Bank:Format(), "stuckA", "stuckB", 40)
	Bank:Healed()

	T:Is("a transfer that could not hand the money over", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("it says the money is set aside", Escrowed, true)
	T:Is("gold left to the sender", Bank:Amount("stuckA"), 60)
	T:Is("the amount set aside", Bank:Aside("stuckA"), 40)
	T:Is("gold on the receiver", Bank:Amount("stuckB"), 0)

	Bank.Store:RecoverTransfers("stuckA"):Wait()

	T:Is("anything still set aside once the store answers again", Bank:Aside("stuckA"), 0)
	T:Is("gold on the receiver", Bank:Amount("stuckB"), 40)
	T:Is("money is conserved", Bank:Amount("stuckA") + Bank:Amount("stuckB") + Bank:Aside("stuckA"), 100)
end)

Cases.Case("recovery says whether it cleared", function(T: Case)
	local Bank = Funded(T, { sayA = 100, sayB = 0, sayC = 0 })

	local Nothing = Transfer.Recover(Bank:Log(), Bank:Format(), "sayA", {})

	Bank:Append("sayA", { {
		Id = "res:sayok",
		Kind = "__TransferReserve",
		To = "sayB",
		Amount = 5,
		Tid = "sayok",
		At = T:Now(),
	} :: any })
	local One = Transfer.Recover(Bank:Log(), Bank:Format(), "sayA", {
		["sayok"] = { To = "sayB", Amount = 5, At = T:Now() },
	})

	Bank:Fault(Fault.Updates())
	local Failed = Transfer.Recover(Bank:Log(), Bank:Format(), "sayA", {
		["saybad"] = { To = "sayC", Amount = 5, At = T:Now() },
	})
	Bank:Healed()

	T:Is("recovering nothing", Nothing, true)
	T:Is("recovering one hold", One, true)
	T:Is("recovering against a store that will not answer", Failed, false)
	T:Is("gold handed to the receiver", Bank:Amount("sayB"), 5)
	T:Is("gold handed to the receiver it could not reach", Bank:Amount("sayC"), 0)
end)

Cases.Case("a hold inside the margin window is left alone", function(T: Case)
	local Bank = Funded(T, { marginA = 100, marginB = 0 })

	Reserve(Bank, "marginA", "marginB", 40)
	T:Advance(7 * DAY + DAY // 2)
	Bank.Store:RecoverTransfers("marginA"):Wait()

	T:Is("the amount still set aside inside the margin", Bank:Aside("marginA"), 40)
	T:Is("gold on the sender", Bank:Amount("marginA"), 60)
	T:Is("gold on the receiver", Bank:Amount("marginB"), 0)
	T:Is("money is conserved", Bank:Amount("marginA") + Bank:Amount("marginB") + Bank:Aside("marginA"), 100)
end)

Cases.Case("the redrive and expiry edges fall on the exact second", function(T: Case)
	local function AtAge(Seconds: number, Tag: string): (number, number, number)
		local Bank = T:Bank(`node{Tag}`)
		local A, B = `edge{Tag}A`, `edge{Tag}B`
		Bank:Seed(A, { Gold = 100 })
		Bank:Seed(B, { Gold = 0 })

		Reserve(Bank, A, B, 40)
		T:Advance(Seconds)
		Bank.Store:RecoverTransfers(A):Wait()

		return Bank:Amount(A), Bank:Amount(B), Bank:Aside(A)
	end

	local FreshGold, FreshPaid, FreshAside = AtAge(7 * DAY, "1")
	T:Is("the sender exactly on the redrive edge", FreshGold, 60)
	T:Is("the receiver exactly on the redrive edge", FreshPaid, 40)
	T:Is("anything set aside exactly on the redrive edge", FreshAside, 0)

	local HeldGold, HeldPaid, HeldAside = AtAge(8 * DAY, "2")
	T:Is("the sender exactly on the expiry edge", HeldGold, 60)
	T:Is("the receiver exactly on the expiry edge", HeldPaid, 0)
	T:Is("anything still set aside exactly on the expiry edge", HeldAside, 40)

	local BackGold, BackPaid, BackAside = AtAge(8 * DAY + 1, "3")
	T:Is("the sender one second past the expiry edge", BackGold, 100)
	T:Is("the receiver one second past the expiry edge", BackPaid, 0)
	T:Is("anything still set aside one second past", BackAside, 0)
end)

Cases.Case("a replayed reserve does not charge twice", function(T: Case)
	local Bank = Funded(T, { replayA = 100, replayB = 0 })

	Bank:Append("replayA", {
		{ Id = "res:replay1", Kind = "__TransferReserve", To = "replayB", Amount = 40, Tid = "replay1", At = T:Now() } :: any,
	})

	T:Is("gold left to the sender after the reserve", Bank:Amount("replayA"), 60)
	T:Is("the amount set aside", Bank:Aside("replayA"), 40)

	Bank:Forget("replayA", { "res:replay1" })

	local Retried, Why = Bank.Store:Transfer("replayA", "replayB", 40, "replay1"):Wait()

	T:Is("the retry once the reserve op is forgotten", Retried, true)
	T:Is("the reason", Why, nil)
	T:Is("gold on the sender, charged exactly once", Bank:Amount("replayA"), 60)
	T:Is("gold on the receiver", Bank:Amount("replayB"), 40)
	T:Is("anything still set aside", Bank:Aside("replayA"), 0)
	T:Is("money is conserved", Bank:Amount("replayA") + Bank:Amount("replayB") + Bank:Aside("replayA"), 100)
end)

Cases.Case("a transfer compacts an overgrown log", function(T: Case)
	local Bank = Funded(T, { bulkA = 500, bulkB = 0 })

	local Bulk: { any } = {}
	for Index = 1, 130 do
		table.insert(Bulk, { Id = `pad{Index}`, Kind = "Fund", Amount = 1 })
	end
	Bank:Append("bulkA", Bulk)
	local Before = #Bank:Record("bulkA").Ops

	local Moved = Bank.Store:Transfer("bulkA", "bulkB", 10, "bulk1"):Wait()

	T:Is("the log was overgrown before the transfer", Before, 130)
	T:Is("the transfer", Moved, true)
	T:Is("ops left once the transfer compacted the log", #Bank:Record("bulkA").Ops, 0)
	T:Is("gold on the sender", Bank:Amount("bulkA"), 620)
	T:Is("gold on the receiver", Bank:Amount("bulkB"), 10)
end)

Cases.Case("a transfer and a transaction can share a name", function(T: Case)
	local Bank = Funded(T, { sharedA = 100, sharedB = 0 })

	local Moved, MovedWhy = Bank.Store:Transfer("sharedA", "sharedB", 40, "shared1"):Wait()
	local Committed, CommittedWhy = Bank.Store
		:Tx("shared1", {
			{ Key = "sharedB", Kind = "Fund", Fields = { Amount = 5 } },
			{ Key = "sharedA", Kind = "Fund", Fields = { Amount = 5 } },
		})
		:Wait()

	local Sb = Bank:State("sharedB")

	T:Is("the transfer", Moved, true)
	T:Is("the transfer's reason", MovedWhy, nil)
	T:Is("the transaction under the same name", Committed, true)
	T:Is("the transaction's reason", CommittedWhy, nil)
	T:Is("gold on the sender", Bank:Amount("sharedA"), 65)
	T:Is("gold on the receiver", Sb.Gold, 45)
	T:Is("the transfer is remembered under its own namespace", Sb._Received["t:shared1"] ~= nil, true)
	T:Is("the transaction is remembered under its own namespace", Sb._Received["x:shared1"] ~= nil, true)
end)

Cases.Case("erasing a key is refused while a transaction is parked on it", function(T: Case)
	local Bank = Funded(T, { parkErase = 100 })

	Bank:Marker("parked1", { Status = "Pending", Total = 2, Gen = "one", Adopted = {} })
	Bank:Park("parkErase", { Id = "tx:parked1:1", Kind = "Fund", Amount = 25, Tx = "parked1" })

	local Ok, Why = Bank.Store:Erase("parkErase"):Wait()
	local Record = Bank:Record("parkErase")

	T:Is("erasing a key a transaction is parked on", Ok, false)
	T:Is("the reason", Why, "Busy")
	T:Is("the parked leg survives", Log.HasPending(Record), true)
	T:Is("the key was not entombed", Record.Erased, nil)

	T:Advance(Tx.TIMEOUT + 1)
	Bank.Store:Resettle("parkErase"):Wait()
	T:Is("erasing once the transaction settled", (Bank.Store:Erase("parkErase"):Wait()), true)
end)

Cases.Case("resetting a key is refused while a transaction is parked on it", function(T: Case)
	local Bank = Funded(T, { parkReset = 100 })

	Bank:Marker("parked2", { Status = "Pending", Total = 2, Gen = "one", Adopted = {} })
	Bank:Park("parkReset", { Id = "tx:parked2:1", Kind = "Fund", Amount = 25, Tx = "parked2" })

	local Ok, Why = Bank.Store:Reset("parkReset"):Wait()

	T:Is("resetting a key a transaction is parked on", Ok, false)
	T:Is("the reason", Why, "Busy")
	T:Is("the parked leg survives", Log.HasPending(Bank:Record("parkReset")), true)

	T:Advance(Tx.TIMEOUT + 1)
	Bank.Store:Resettle("parkReset"):Wait()
	T:Is("resetting once the transaction settled", (Bank.Store:Reset("parkReset"):Wait()), true)
end)

Cases.Case("money sent to an erased key is turned away and stays with the sender", function(T: Case)
	local Bank = Funded(T, { tombA = 100, tombB = 0 })

	Bank.Store:Erase("tombB"):Wait()
	local Moved, Why = Bank.Store:Transfer("tombA", "tombB", 40, "tomb1"):Wait()

	T:Is("sending to a key that was erased", Moved, false)
	T:Is("the reason, since the money is set aside rather than untouched", Why, "Held")
	T:Is("gold left with the sender", Bank:Amount("tombA"), 60)
	T:Is("the amount set aside for the refund", Bank:Aside("tombA"), 40)
	T:Is("the erased key was not brought back holding money", Bank:Amount("tombB"), 0)
	T:Is("money is conserved", Bank:Amount("tombA") + Bank:Amount("tombB") + Bank:Aside("tombA"), 100)
end)

Cases.Case("a deliver for a hold taken before the erase is also turned away", function(T: Case)
	local Bank = Funded(T, { raceA = 100, raceB = 0 })

	local Tid = Reserve(Bank, "raceA", "raceB", 40, "race1")
	Bank.Store:Erase("raceB"):Wait()

	local Moved, Why = Bank.Store:Transfer("raceA", "raceB", 40, Tid):Wait()

	T:Is("handing over a hold taken before the erase", Moved, false)
	T:Is("the reason, since the money is set aside rather than untouched", Why, "Held")
	T:Is("the amount is still set aside", Bank:Aside("raceA"), 40)
	T:Is("the erased key took none of it", Bank:Amount("raceB"), 0)
	T:Is("money is conserved", Bank:Amount("raceA") + Bank:Amount("raceB") + Bank:Aside("raceA"), 100)
end)

Cases.Case("money sent to an erased key is given back once the transfer is overdue", function(T: Case)
	local Bank = Funded(T, { backA = 100, backB = 0 })

	Bank.Store:Erase("backB"):Wait()
	Bank.Store:Transfer("backA", "backB", 40, "back1"):Wait()

	T:Advance(PAST_REDRIVE)
	Bank.Store:RecoverTransfers("backA"):Wait()

	T:Is("the sender has the money back", Bank:Amount("backA"), 100)
	T:Is("nothing is still set aside", Bank:Aside("backA"), 0)
	T:Is("the erased key still has nothing", Bank:Amount("backB"), 0)
	T:Is("money is conserved", Bank:Amount("backA") + Bank:Amount("backB") + Bank:Aside("backA"), 100)
end)

Cases.Case("a cold tombstone stops turning deliveries away", function(T: Case)
	local Bank = Funded(T, { coldA = 100, coldB = 0 })

	Bank.Store:Erase("coldB"):Wait()
	T:Advance(PAST_REDRIVE)

	local Moved, Why = Bank.Store:Transfer("coldA", "coldB", 40, "cold1"):Wait()

	T:Is("sending to a key whose tombstone has gone cold", Moved, true)
	T:Is("the reason", Why, nil)
	T:Is("gold on the sender", Bank:Amount("coldA"), 60)
	T:Is("gold on the key that came back", Bank:Amount("coldB"), 40)
	T:Is("nothing is set aside", Bank:Aside("coldA"), 0)
end)

Cases.Case("an erased key takes writes without losing its tomb", function(T: Case)
	local Bank = Funded(T, { revive = 100 })

	Bank.Store:Erase("revive"):Wait()
	local Blank = Bank:Amount("revive")

	local Edited = Bank.Store:Edit("revive", "Fund", { Amount = 7 }):Wait()

	T:Is("what an erased key reads as", Blank, 0)
	T:Is("editing it", Edited, true)
	T:Is("gold once it is written to again", Bank:Amount("revive"), 7)
	T:Is("the tombstone the write cannot cancel", Bank:Record("revive").Erased ~= nil, true)
end)

Cases.Case("an expiry sees a delivery even after the evidence is cleared", function(T: Case)
	local Bank = Funded(T, { seenA = 100, seenB = 0 })

	local Tid = Reserve(Bank, "seenA", "seenB", 40)
	Deliver(Bank, "seenB", Tid, 40, T:Now())

	T:Advance(PAST_REDRIVE)
	Bank.Store:ClearDelivered("seenB"):Wait()
	local Kept: any = Bank:Stored("seenB")._Received

	Bank.Store:RecoverTransfers("seenA"):Wait()

	T:Is("clearing keeps what a refund would have to consult", Kept ~= nil and Kept[`t:{Tid}`] ~= nil, true)
	T:Is("gold on the sender", Bank:Amount("seenA"), 60)
	T:Is("anything still set aside", Bank:Aside("seenA"), 0)
	T:Is("gold on the receiver, paid once", Bank:Amount("seenB"), 40)
	T:Is("money is conserved", Bank:Amount("seenA") + Bank:Amount("seenB") + Bank:Aside("seenA"), 100)
end)

Cases.Case("a redelivery is refused once the op id falls out of seen", function(T: Case)
	local Bank = Funded(T, { seenB = 0 })

	Deliver(Bank, "seenB", "first", 100, T:Now())
	Bank:Log():Compact("seenB", Bank:Format())

	local Made = 0
	for _ = 1, 3 do
		local Bulk: { any } = {}
		for _ = 1, 700 do
			Made += 1
			table.insert(Bulk, { Id = `pad{Made}`, Kind = "Fund", Amount = 0 } :: any)
		end
		Bank:Append("seenB", Bulk)
		Bank:Log():Compact("seenB", Bank:Format())
	end

	local Remembered = false
	for _, Entry in Bank:Record("seenB").Seen do
		if Entry == "del:first" then
			Remembered = true
		end
	end
	local State: any = Bank:State("seenB")

	Deliver(Bank, "seenB", "first", 100, T:Now())

	T:Is("the op id, once the log has outgrown the seen window", Remembered, false)
	T:Is("the transfer is still remembered by name", State._Received["t:first"] ~= nil, true)
	T:Is("gold before the redelivery", State.Gold, 100)
	T:Is("gold after the same delivery arrives again", Bank:Amount("seenB"), 100)
end)

Cases.Case("clearing delivered ids cannot open the door to a second delivery", function(T: Case)
	local Bank = Funded(T, { clrpayer = 100, clrpayee = 0 })

	Bank:Fault(Fault.Updates():After(2))
	Bank.Store:Transfer("clrpayer", "clrpayee", 50, "clr1"):Wait()
	Bank:Healed()

	T:Is("the receiver was paid", Bank:Amount("clrpayee"), 50)
	T:Is("the sender is still holding", Bank:Aside("clrpayer"), 50)

	Bank.Store:ClearDelivered("clrpayee"):Wait()
	Bank:Forget("clrpayee", { "del:" })
	Bank.Store:RecoverTransfers("clrpayer"):Wait()

	T:Is("the receiver after the stranded transfer is recovered", Bank:Amount("clrpayee"), 50)
	T:Is("money is conserved", Bank:Amount("clrpayer") + Bank:Amount("clrpayee") + Bank:Aside("clrpayer"), 100)
end)

Cases.Case("clearing delivered ids still drops ones past the redrive window", function(T: Case)
	local Bank = Funded(T, { clrold = 0 })

	Deliver(Bank, "clrold", "old1", 25, T:Now())

	T:Advance(PAST_PRUNE)
	Bank.Store:ClearDelivered("clrold"):Wait()

	local Left = Bank:Names("clrold")
	local Kept = false
	for Id in Left do
		if string.sub(Id, 1, 2) == "t:" then
			Kept = true
		end
	end

	T:Is("an id no refund can still be raised against is dropped", Kept, false)
	T:Is("the money it delivered stays put", Bank:Amount("clrold"), 25)
end)

Cases.Case("a write from another server cannot cancel a tomb", function(T: Case)
	local Bank = Funded(T, { tombpayer = 100, tombdead = 0 })

	Bank.Store:Erase("tombdead"):Wait()
	Bank.Store:Edit("tombdead", "Touch"):Wait()

	local Sent, Why = Bank.Store:Transfer("tombpayer", "tombdead", 50, "tomb1"):Wait()

	T:Is("the tomb outlives a write from elsewhere", Bank:Record("tombdead").Erased ~= nil, true)
	T:Is("money sent to the erased key", Sent, false)
	T:Is("the reason it was turned away", Why, "Held")
	T:Is("nothing landed on the erased key", Bank:Amount("tombdead"), 0)
	T:Is("money is conserved", Bank:Amount("tombpayer") + Bank:Aside("tombpayer") + Bank:Amount("tombdead"), 100)
end)

Cases.Case("compacting an erased key carries its tomb forward", function(T: Case)
	local Bank = Funded(T, { packpayer = 100, packdead = 0 })

	Bank.Store:Erase("packdead"):Wait()
	Bank.Store:Edit("packdead", "Touch"):Wait()
	Bank:Log():Compact("packdead", Bank:Format())

	local Sent = Bank.Store:Transfer("packpayer", "packdead", 50, "pack1"):Wait()

	T:Is("the tomb survives compaction", Bank:Record("packdead").Erased ~= nil, true)
	T:Is("money sent to the compacted tomb", Sent, false)
	T:Is("nothing landed on the erased key", Bank:Amount("packdead"), 0)
end)

Cases.Case("a tomb still runs out once its horizon passes", function(T: Case)
	local Bank = Funded(T, { gonepayer = 100, gonedead = 0 })

	Bank.Store:Erase("gonedead"):Wait()

	T:Advance(Log.TOMB_HORIZON + DAY)
	Bank.Store:Edit("gonedead", "Touch"):Wait()

	local Sent = Bank.Store:Transfer("gonepayer", "gonedead", 50, "gone1"):Wait()

	T:Is("a tomb past its horizon is cleared by the next write", Bank:Record("gonedead").Erased, nil)
	T:Is("money sent once the tomb ran out", Sent, true)
	T:Is("it arrived", Bank:Amount("gonedead"), 50)
	T:Is("money is conserved", Bank:Amount("gonepayer") + Bank:Amount("gonedead"), 100)
end)

Cases.Case("two senders sharing a transfer name cannot destroy either amount", function(T: Case)
	local Bank = Funded(T, { shareA = 1000, shareB = 1000 })

	Transfer.Reserve(Bank:Log(), Bank:Format(), "shareA", "shareC", 100, "order")
	Transfer.Reserve(Bank:Log(), Bank:Format(), "shareB", "shareC", 250, "order")

	pcall(Transfer.Post, Bank:Log(), Bank:Format(), "shareA", "order", "shareC", 100)
	pcall(Transfer.Post, Bank:Log(), Bank:Format(), "shareB", "order", "shareC", 250)

	local Total = Bank:Amount("shareA") + Bank:Amount("shareB") + Bank:Amount("shareC") + Bank:Aside("shareA") + Bank:Aside("shareB") + Bank:Aside("shareC")

	T:Is("money is conserved across both senders", Total, 2000)
	T:Is("the second sender keeps what the first did not deliver", Bank:Amount("shareB") + Bank:Aside("shareB"), 1000)
end)

Cases.Case("two senders sharing a transfer name survive the receiver compacting", function(T: Case)
	local Bank = Funded(T, { packA = 1000, packB = 1000 })

	Transfer.Reserve(Bank:Log(), Bank:Format(), "packA", "packC", 100, "order")
	Transfer.Reserve(Bank:Log(), Bank:Format(), "packB", "packC", 250, "order")
	pcall(Transfer.Post, Bank:Log(), Bank:Format(), "packA", "order", "packC", 100)

	Bank:Log():Compact("packC", Bank:Format())
	pcall(Transfer.Post, Bank:Log(), Bank:Format(), "packB", "order", "packC", 250)

	local Total = Bank:Amount("packA") + Bank:Amount("packB") + Bank:Amount("packC") + Bank:Aside("packA") + Bank:Aside("packB") + Bank:Aside("packC")

	T:Is("money is conserved through the compaction", Total, 2000)
	T:Is("the second sender keeps what never arrived", Bank:Amount("packB") + Bank:Aside("packB"), 1000)
end)

Cases.Case("a redelivery through a compacted receiver still finishes", function(T: Case)
	local Bank = Funded(T, { againA = 1000 })

	Transfer.Reserve(Bank:Log(), Bank:Format(), "againA", "againC", 100, "order")
	Transfer.Post(Bank:Log(), Bank:Format(), "againA", "order", "againC", 100)
	Bank:Log():Compact("againC", Bank:Format())

	local Again = pcall(Transfer.Post, Bank:Log(), Bank:Format(), "againA", "order", "againC", 100)

	T:Is("sending the same transfer again", Again, true)
	T:Is("what the receiver holds after it", Bank:Amount("againC"), 100)
	T:Is("money is conserved", Bank:Amount("againA") + Bank:Amount("againC") + Bank:Aside("againA"), 1000)
end)

Cases.Case("recovery cannot settle a hold against a compacted delivery", function(T: Case)
	local Bank = Funded(T, { packRA = 1000, packRB = 1000 })

	Transfer.Reserve(Bank:Log(), Bank:Format(), "packRA", "packRC", 300, "order")
	Transfer.Reserve(Bank:Log(), Bank:Format(), "packRB", "packRC", 300, "order")
	pcall(Transfer.Post, Bank:Log(), Bank:Format(), "packRB", "order", "packRC", 300)
	Bank:Log():Compact("packRC", Bank:Format())

	T:Advance(PAST_REDRIVE)
	Recovery.Transfers(Bank:Log(), Bank:Format(), "packRA", Bank:Stored("packRA")._Held)

	local Total = Bank:Amount("packRA") + Bank:Amount("packRB") + Bank:Amount("packRC") + Bank:Aside("packRA") + Bank:Aside("packRB") + Bank:Aside("packRC")

	T:Is("money is conserved through the compaction", Total, 2000)
	T:Is("the sender whose money never arrived keeps it", Bank:Amount("packRA") + Bank:Aside("packRA"), 1000)
end)

Cases.Case("recovery cannot settle a hold against another sender's delivery", function(T: Case)
	local Bank = Funded(T, { raceA = 1000, raceB = 1000 })

	Transfer.Reserve(Bank:Log(), Bank:Format(), "raceA", "raceC", 300, "order")
	Transfer.Reserve(Bank:Log(), Bank:Format(), "raceB", "raceC", 300, "order")
	pcall(Transfer.Post, Bank:Log(), Bank:Format(), "raceB", "order", "raceC", 300)

	T:Advance(PAST_REDRIVE)
	Recovery.Transfers(Bank:Log(), Bank:Format(), "raceA", Bank:Stored("raceA")._Held)

	local Total = Bank:Amount("raceA") + Bank:Amount("raceB") + Bank:Amount("raceC") + Bank:Aside("raceA") + Bank:Aside("raceB") + Bank:Aside("raceC")

	T:Is("money is conserved once recovery has run", Total, 2000)
	T:Is("the sender whose money never arrived gets it back", Bank:Amount("raceA") + Bank:Aside("raceA"), 1000)
end)

Cases.Case("a retry once recovery owns the hold is left alone", function(T: Case)
	local Bank = Funded(T, { ownA = 100, ownB = 0 })

	Reserve(Bank, "ownA", "ownB", 40, "own1")
	T:Advance(PAST_REDRIVE)

	local Ok, Why = Bank.Store:Transfer("ownA", "ownB", 40, "own1"):Wait()

	T:Is("a retry of a hold older than the redrive window", Ok, false)
	T:Is("the reason", Why, "Held")
	T:Warns("it said recovery owns it now", "recovery owns it now")
	T:Is("the amount is still set aside", Bank:Aside("ownA"), 40)
	T:Is("money is conserved", Bank:Amount("ownA") + Bank:Amount("ownB") + Bank:Aside("ownA"), 100)
end)

Cases.Case("a refund that cannot be written leaves the money set aside", function(T: Case)
	local Bank = Funded(T, { refundA = 100, refundB = 0 })

	Reserve(Bank, "refundA", "refundB", 40, "refund1")
	T:Advance(PAST_REDRIVE)

	Bank:Fault(Fault.Updates())
	local Ok, Why = Bank.Store:RecoverTransfers("refundA"):Wait()
	Bank:Healed()

	T:Warns("it said the refund did not go through", "could not give back transfer")
	T:Is("the recovery", Ok, false)
	T:Is("the reason", Why, "Busy")
	T:Is("the amount is still set aside", Bank:Aside("refundA"), 40)
	T:Is("money is conserved", Bank:Amount("refundA") + Bank:Amount("refundB") + Bank:Aside("refundA"), 100)
end)

return Cases
