--!strict
--!optimize 2

--[=[
	Shutdown: One rule per case for CloseAll, the last thing a server runs.

	A shutdown has seconds, so CloseAll cuts every queue down to its last write and lowers the tries.
	That is safe for a session, because a later push carries every op an earlier one did.
	An inbound transfer is where it does not hold, since the deliver alone carries the money.
	A dropped write says Closed and never Unresolved, because it never ran at all.

	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, and it runs the next time you press play.
--]=]

local Suite = require("../Suite")

local Fault = Suite.Fault
local Insides = Suite.Insides

local Ledger = Insides.Ledger
local Registry = Insides.Registry
local SetInterval = Insides.SetInterval

type Case = Suite.Case
type Fixture = Suite.Fixture

local Cases = Suite.File("Shutdown")

local DEADLINE = 5

local function Counted(Set: any): number
	local Count = 0
	for _ in Set do
		Count += 1
	end
	return Count
end

local function Waiting(Store: Fixture, Key: string): number
	local Queue = Store.Store.Wrapper.Queues[Key]
	return if Queue ~= nil then Queue:GetLength() else 0
end

local function Lined(Store: Fixture, Key: string, Least: number): number
	local Stop = os.clock() + DEADLINE
	while Waiting(Store, Key) < Least and os.clock() < Stop do
		task.wait()
	end
	return Waiting(Store, Key)
end

local function Settled(Done: () -> boolean)
	local Stop = os.clock() + DEADLINE
	while not Done() and os.clock() < Stop do
		task.wait()
	end
end

local function Hold(Store: Fixture, UserId: number, Active: any)
	Store.Store.Loaded[UserId] = {
		Active = Active,
		Ticks = 0,
		Ticker = SetInterval(30, function() end)
	}
end

Cases.Case("CloseAll saves every unsaved op on every store", function(T: Case)
	local First = T:Bank("node1")
	local Second = T:Bank("node2")
	First:Seed("a", { Gold = 0 })
	Second:Seed("b", { Gold = 0 })

	local Left, Right = First:Session("a"), Second:Session("b")
	for _ = 1, 3 do
		Left:Apply("Fund", { Amount = 10 })
	end
	for _ = 1, 2 do
		Right:Apply("Fund", { Amount = 10 })
	end
	Hold(First, 1, Left)
	Hold(Second, 2, Right)

	T:Is("nothing is on disk before the shutdown", First:Amount("a"), 0)

	Ledger.CloseAll()

	T:Is("the first store's ops landed", First:Amount("a"), 30)
	T:Is("the second store's ops landed", Second:Amount("b"), 20)
end)

Cases.Case("CloseAll lets go of every session it saved", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	local Active = Bank:Session("a")
	Active:Apply("Fund", { Amount = 10 })
	Hold(Bank, 1, Active)

	T:Is("the store is holding one session", Counted(Bank.Store.Loaded), 1)

	Ledger.CloseAll()

	T:Is("sessions still held", Counted(Bank.Store.Loaded), 0)
	T:Is("save jobs still tracked", Counted(Bank.Store.Saving), 0)
	T:Is("the session knows it was released", Active.Released, true)
end)

Cases.Case("CloseAll waits for the saves rather than firing them off", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	local Active = Bank:Session("a")
	Active:Apply("Fund", { Amount = 40 })
	Hold(Bank, 1, Active)

	Ledger.CloseAll()

	T:Is("the op is durable the moment CloseAll returns", Bank:Amount("a"), 40)
end)

Cases.Case("CloseAll lowers retries so shutdown is bounded", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	T:Is("attempts before the shutdown are the everyday ones", Bank.Store.Wrapper.Attempts ~= 2, true)

	Ledger.CloseAll()

	T:Is("attempts on the record store", Bank.Store.Wrapper.Attempts, 2)
	T:Is("attempts on the marker store", Bank.Store.TxWrapper.Attempts, 2)
end)

Cases.Case("one store that cannot save does not stop the others", function(T: Case)
	local Doomed = T:Bank("node1")
	local Fine = T:Bank("node2")
	Doomed:Seed("a", { Gold = 0 })
	Fine:Seed("b", { Gold = 0 })

	local Lost, Kept = Doomed:Session("a"), Fine:Session("b")
	Lost:Apply("Fund", { Amount = 10 })
	Kept:Apply("Fund", { Amount = 70 })
	Hold(Doomed, 1, Lost)
	Hold(Fine, 2, Kept)

	Doomed:Fault(Fault.Updates())

	Ledger.CloseAll()

	T:Is("the store that could still write saved", Fine:Amount("b"), 70)
	T:Is("the broken store let go of its session anyway", Counted(Doomed.Store.Loaded), 0)
	T:Is("no save job was left tracked", Counted(Doomed.Store.Saving), 0)
end)

Cases.Case("CloseAll twice is harmless", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	local Active = Bank:Session("a")
	Active:Apply("Fund", { Amount = 25 })
	Hold(Bank, 1, Active)

	Ledger.CloseAll()
	local Again = pcall(Ledger.CloseAll)

	T:Is("the second call", Again, true)
	T:Is("the op is still durable", Bank:Amount("a"), 25)
end)

Cases.Case("a write the shutdown skips says Closed rather than Unresolved", function(T: Case)
	T:Slow()

	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })
	Bank:Fault(Fault.Updates():Stall(0.3))

	local Answers: { { Ok: any, Why: any } } = {}
	for _ = 1, 4 do
		task.spawn(function()
			local Ok, Why = Bank.Store:Edit("a", "Fund", { Amount = 1 }):Wait()
			table.insert(Answers, { Ok = Ok, Why = Why })
		end)
	end

	local Queued = Lined(Bank, "a", 3)
	Ledger.CloseAll()

	Settled(function(): boolean
		return #Answers >= 4
	end)

	local Closed, Unresolved, Landed = 0, 0, 0
	for _, Answer in Answers do
		if Answer.Ok then
			Landed += 1
		end
		if Answer.Why == "Closed" then
			Closed += 1
		elseif Answer.Why == "Unresolved" then
			Unresolved += 1
		end
	end

	T:Is("writes were lined up behind the slow one", Queued >= 2, true)
	T:Is("the ones the shutdown dropped say the server is closing", Closed > 0, true)
	T:Is("none of them were called unresolved, they never ran at all", Unresolved, 0)
	T:Is("the key carries the writes that said yes and nothing else", Bank:Amount("a"), Landed)
end)

Cases.Case("a deliver the shutdown drops leaves the money set aside", function(T: Case)
	T:Slow()

	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 100 })
	Bank:Seed("b", { Gold = 0 })

	Bank:Fault(Fault.Updates():OnKey("b"):Stall(0.4))

	local Answered = 0
	task.spawn(function()
		Bank.Store:Edit("b", "Fund", { Amount = 1 }):Wait()
		Answered += 1
	end)

	task.spawn(function()
		Bank.Store:Transfer("a", "b", 50):Wait()
		Answered += 1
	end)

	T:Is("the deliver is queued behind the slow write", Lined(Bank, "b", 1) >= 1, true)

	task.spawn(function()
		Bank.Store:Edit("b", "Fund", { Amount = 2 }):Wait()
		Answered += 1
	end)
	T:Is("the deliver and the edit behind it are both queued", Lined(Bank, "b", 2) >= 2, true)

	Ledger.CloseAll()
	Settled(function(): boolean
		return Answered >= 3
	end)

	T:Is("the sender paid the amount out of its balance", Bank:Amount("a"), 50)
	T:Is("the amount is set aside on the sender for recovery", Bank:Aside("a"), 50)
	T:Is("the receiver got the ordinary writes and none of the transfer", Bank:Amount("b"), 3)
end)

Cases.Case("ops dropped from a queued save are written again on the way out", function(T: Case)
	T:Slow()

	local Bank = T:Bank()
	Bank:Seed("1", { Gold = 0 })

	local Active = Bank:Session("1")
	for _ = 1, 3 do
		Active:Apply("Fund", { Amount = 10 })
	end
	Hold(Bank, 1, Active)

	Bank:Fault(Fault.Updates():OnKey("1"):Stall(0.4))

	local Answered = 0
	task.spawn(function()
		Bank.Store:Edit("1", "Fund", { Amount = 5 }):Wait()
		Answered += 1
	end)

	local Flushed: boolean? = nil
	task.spawn(function()
		Flushed = Active:Flush():Wait()
		Answered += 1
	end)
	T:Is("the save is queued behind the slow write", Lined(Bank, "1", 1) >= 1, true)

	task.spawn(function()
		Bank.Store:Edit("1", "Fund", { Amount = 7 }):Wait()
		Answered += 1
	end)
	T:Is("the save and the edit behind it are both queued", Lined(Bank, "1", 2) >= 2, true)

	Ledger.CloseAll()
	Settled(function(): boolean
		return Answered >= 3
	end)

	T:Is("the save the shutdown dropped reported that it failed", Flushed, false)
	T:Is("its ops were written again anyway", Bank:Amount("1"), 42)
	T:Is("the session has nothing left unsaved", #Active.Pending, 0)
end)

Cases.Case("a thin budget goes to the session with the most to lose", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("1", { Gold = 0 })
	Bank:Seed("2", { Gold = 0 })

	local Heavy, Light = Bank:Session("1"), Bank:Session("2")
	for _ = 1, 300 do
		Heavy:Apply("Fund", { Amount = 1 })
	end
	Light:Apply("Fund", { Amount = 1 })

	Hold(Bank, 1, Heavy)
	Hold(Bank, 2, Light)

	Bank:Budget(function(): number
		return 2
	end)

	Bank.Store:Autosave(1)
	Bank.Store:Autosave(2)

	T:Is("the session with 300 ops unsaved got through", Bank:Amount("1"), 300)
	T:Is("the session with one op waited", Bank:Amount("2"), 0)
	T:Is("the light session still has its op to save later", #Light.Pending, 1)
end)

Cases.Case("a store with no budget does not starve the rest of the sweep", function(T: Case)
	local Broke = T:Bank("node1")
	local Fine = T:Bank("node2")

	for Index = 1, 24 do
		Broke:Seed(`broke{Index}`, { Gold = 0 })
		Registry.Sweep:Add(Broke.Store, `broke{Index}`)
	end
	for Index = 1, 2 do
		Fine:Seed(`fine{Index}`, { Gold = 0 })
		Registry.Sweep:Add(Fine.Store, `fine{Index}`)
	end

	Broke:Budget(function(): number
		return 0
	end)

	T:Is("the sweep is following every key", Registry.Sweep.Count, 26)

	Registry.Sweep:Pass()

	local Left = 0
	for _, Entry in Registry.Sweep.Entries do
		if Entry.Store == Fine.Store then
			Left += 1
		end
	end

	T:Is("keys on the store that could still be written", Left, 0)
	T:Is("keys on the store with no budget are left for next time", Registry.Sweep.Count, 24)
end)

Cases.Case("CloseAll stops the sweep following stranded keys", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })
	Registry.Sweep:Add(Bank.Store, "a")

	T:Is("the sweep is following a key", Registry.Sweep.Count, 1)

	Ledger.CloseAll()

	T:Is("keys still followed after the shutdown", Registry.Sweep.Count, 0)
end)

return Cases
