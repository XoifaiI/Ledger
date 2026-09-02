--!strict
--!optimize 2

--[=[

	Servers: One rule per case for two servers writing one datastore, and for a transaction broken at
	each call it makes.

	Two fixtures over one datastore name are two servers: each holds its own hook, wrapper and queues,
	so a race between them is a real one rather than a marker written by hand. A sweep drives the same
	transaction once per call it makes, takes that call and every one after it away, and asks the same
	questions each time: does the money add up, is the key on one side of the transaction or the
	other, and did anything stay parked. Each sweep counts what it actually broke, since a fault the
	retries absorbed has tested the retries.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau servers
--]=]

local Suite = require("../Suite")

local Windows = require("../../src/Core/Constants/Windows")

local Fault = Suite.Fault

type Case = Suite.Case
type Fixture = Suite.Fixture

local Cases = Suite.File("Servers")

local START = 100
local MOVED = 10
local CALLS = 4
local TRIES = 4
local PASSES = 20

local function Pair(T: Case): (Fixture, Fixture)
	return T:Bank("nodeA"), T:Bank("nodeB")
end

local function Funded(Held: Fixture, A: string, B: string)
	Held:Seed(A, { Gold = START, Touches = 0 })
	Held:Seed(B, { Gold = 0, Touches = 0 })
end

local function Move(Held: Fixture, A: string, B: string, Amount: number, Id: string): (boolean, any)
	return Held.Store
		:Tx(Id, {
			{ Key = A, Kind = "Give", Fields = { Amount = -Amount } },
			{ Key = B, Kind = "Give", Fields = { Amount = Amount } },
		})
		:Wait()
end

local function Gold(Held: Fixture, Key: string): number
	return Held:State(Key).Gold
end

local function Quiet(T: Case, Held: Fixture, Keys: { string }): number
	for Pass = 1, TRIES do
		T:Advance(Windows.REAP + Windows.TX)
		Held.Store:ReapMarkers()

		local Left = false
		for _, Key in Keys do
			Held.Store:Resettle(Key):Wait()
			if Held:Pending(Key) then
				Left = true
			end
		end

		if not Left then
			return Pass
		end
	end

	return TRIES + 1
end

local function Swept(T: Case, Label: string, Marked: boolean, Made: () -> any): number
	local Bank = T:Bank()
	local Fired = 0

	for Call = 1, CALLS do
		local A, B = `{Label}{Call}a`, `{Label}{Call}b`
		Funded(Bank, A, B)

		local Spec = Made():After(Call - 1)
		if Marked then
			Bank:MarkerFault(Spec)
		else
			Bank:Fault(Spec)
		end

		local Ok = Move(Bank, A, B, MOVED, `{Label}{Call}`)

		Bank:Healed()
		local Passes = Quiet(T, Bank, { A, B })
		Fired += Spec.Fired

		T:Is(`broken at call {Call}, the fault fired at all`, Spec.Fired > 0, true)
		T:Is(`broken at call {Call}, recovery got there`, Passes <= TRIES, true)

		local Left, Right = Gold(Bank, A), Gold(Bank, B)
		T:Is(`broken at call {Call}, the money adds up`, Left + Right, START)
		T:Is(`broken at call {Call}, both keys are on one side of it`, (Left == START and Right == 0) or (Left == START - MOVED and Right == MOVED), true)
		if Ok then
			T:Is(`broken at call {Call}, a yes means the money moved`, Right, MOVED)
		end
		T:Is(`broken at call {Call}, nothing is left parked on the sender`, Bank:Pending(A), false)
		T:Is(`broken at call {Call}, nothing is left parked on the receiver`, Bank:Pending(B), false)
	end

	return Fired
end

Cases.Case("two servers spending the same money never both get it", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "spendA", "spendB")

	local First, Second: any = nil, nil
	T:Race({
		function()
			First = Move(One, "spendA", "spendB", 60, "spend1")
		end,
		function()
			Second = Move(Two, "spendA", "spendB", 60, "spend2")
		end,
	})

	Quiet(T, One, { "spendA", "spendB" })
	local Left, Right = Gold(One, "spendA"), Gold(One, "spendB")

	T:Is("both servers were told yes", First == true and Second == true, false)
	T:Is("the money adds up", Left + Right, START)
	T:Is("the receiver holds one payment or none", Right == 0 or Right == 60, true)
	T:Is("a server told yes is the one on the key", (First == true or Second == true) == (Right == 60), true)
	T:Is("nothing is left parked on the sender", One:Pending("spendA"), false)
	T:Is("nothing is left parked on the receiver", One:Pending("spendB"), false)
end)

Cases.Case("one transaction name driven by two servers moves the money once", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "sameA", "sameB")

	local First, Second: any = nil, nil
	T:Race({
		function()
			First = Move(One, "sameA", "sameB", 25, "same1")
		end,
		function()
			Second = Move(Two, "sameA", "sameB", 25, "same1")
		end,
	})

	Quiet(T, One, { "sameA", "sameB" })

	T:Is("the money adds up", Gold(One, "sameA") + Gold(One, "sameB"), START)
	T:Is("the receiver was paid once and not twice", Gold(One, "sameB"), 25)
	T:Is("the sender paid once", Gold(One, "sameA"), START - 25)
	T:Is("one of the two servers was told it went through", First == true or Second == true, true)
end)

Cases.Case("two servers sharing one key never half apply", function(T: Case)
	local One, Two = Pair(T)
	One:Seed("chainA", { Gold = START, Touches = 0 })
	One:Seed("chainB", { Gold = START, Touches = 0 })
	One:Seed("chainC", { Gold = START, Touches = 0 })

	T:Race({
		function()
			Move(One, "chainA", "chainB", 30, "chain1")
		end,
		function()
			Move(Two, "chainB", "chainC", 40, "chain2")
		end,
	})

	Quiet(T, One, { "chainA", "chainB", "chainC" })
	local A, B, C = Gold(One, "chainA"), Gold(One, "chainB"), Gold(One, "chainC")

	T:Is("the money adds up", A + B + C, START * 3)
	T:Is("the first key is whole or paid out", A == START or A == START - 30, true)
	T:Is("the last key is whole or paid in", C == START or C == START + 40, true)
	T:Is("the shared key agrees with what both ends did", B, START + (START - A) - (C - START))
	T:Is("nothing is left parked on the shared key", One:Pending("chainB"), false)
end)

Cases.Case("a server that stops part way leaves the money for another to finish", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "deadA", "deadB")

	One:MarkerFault(Fault.Updates():After(2))
	One:NoRetries()

	local Ok = Move(One, "deadA", "deadB", 40, "dead1")
	One:Healed()

	Quiet(T, Two, { "deadA", "deadB" })
	local Left, Right = Gold(Two, "deadA"), Gold(Two, "deadB")

	T:Is("the server that stopped was not told it went through", Ok, false)
	T:Is("the money adds up", Left + Right, START)
	T:Is("the other server left both keys on one side of it", (Left == START and Right == 0) or (Left == START - 40 and Right == 40), true)
	T:Is("nothing is left parked on the sender", Two:Pending("deadA"), false)
	T:Is("nothing is left parked on the receiver", Two:Pending("deadB"), false)
end)

Cases.Case("two servers reaping at once take each marker off once", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "reapA", "reapB")

	T:Is("the transaction", (Move(One, "reapA", "reapB", MOVED, "reap1")), true)
	T:Advance(Windows.REAP + 60)

	T:Race({
		function()
			One.Store:ReapMarkers()
		end,
		function()
			Two.Store:ReapMarkers()
		end,
	})

	T:Is("the marker is gone", One:Mark("reap1"), nil)
	T:Is("its name is off the cleanup list", One:Rolled()["reap1"], nil)
	T:Is("the money it moved is untouched", Gold(One, "reapB"), MOVED)
end)

Cases.Case("two servers writing the cleanup list in one minute both land on it", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "rollA", "rollB")
	Funded(One, "rollC", "rollD")

	T:Race({
		function()
			Move(One, "rollA", "rollB", MOVED, "rollone")
		end,
		function()
			Move(Two, "rollC", "rollD", MOVED, "rolltwo")
		end,
	})

	local Rolled = One:Rolled()

	T:Is("the first server's name is on the list", Rolled["rollone"], true)
	T:Is("the second server's name is on the list", Rolled["rolltwo"], true)
end)

Cases.Case("a session on one server reads what another server committed", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "seenA", "seenB")

	T:Is("the transaction on the second server", (Move(Two, "seenA", "seenB", 35, "seen1")), true)

	local Live = One:Session("seenA")

	T:Is("what a session on the first server loads", Live:Get().Gold, START - 35)
end)

Cases.Case("a leg left behind by a broken write waits for its marker to be reaped", function(T: Case)
	local Bank = T:Bank()
	Funded(Bank, "waitA", "waitB")

	Bank:Fault(Fault.Updates():After(1))
	Move(Bank, "waitA", "waitB", MOVED, "wait1")
	Bank:Healed()

	T:Is("the leg is parked", Bank:Pending("waitA"), true)

	T:Advance(Windows.TX + 1)
	local Early, Why = Bank.Store:Resettle("waitA"):Wait()

	T:Is("settling it before its marker goes says so", Early, false)
	T:Is("the reason", Why, "Busy")
	T:Is("and the leg is still parked", Bank:Pending("waitA"), true)

	T:Advance(Windows.REAP + 60)
	Bank.Store:ReapMarkers()
	Bank.Store:Resettle("waitA"):Wait()

	T:Is("once the marker is reaped the leg goes", Bank:Pending("waitA"), false)
	T:Is("the sender got its money back", Gold(Bank, "waitA"), START)
	T:Is("the receiver was never paid", Gold(Bank, "waitB"), 0)
end)

Cases.Case("a transaction whose marker store goes down at any call leaves the money whole", function(T: Case)
	local Fired = Swept(T, "mdrop", true, function()
		return Fault.Updates()
	end)

	T:Is("the sweep broke something", Fired > 0, true)
end)

Cases.Case("a transaction whose marker writes are swallowed at any call leaves the money whole", function(T: Case)
	local Fired = Swept(T, "mlost", true, function()
		return Fault.Updates():Swallow()
	end)

	T:Is("the sweep broke something", Fired > 0, true)
end)

Cases.Case("a transaction whose keys go down at any call leaves the money whole", function(T: Case)
	local Fired = Swept(T, "kdrop", false, function()
		return Fault.Updates()
	end)

	T:Is("the sweep broke something", Fired > 0, true)
end)

Cases.Case("a transaction whose leg writes are swallowed at any call leaves the money whole", function(T: Case)
	local Fired = Swept(T, "klost", false, function()
		return Fault.Updates():Swallow()
	end)

	T:Is("the sweep broke something", Fired > 0, true)
end)

Cases.Case("a store where every transaction was broken still empties its marker store", function(T: Case)
	local Bank = T:Bank()

	for Call = 1, CALLS do
		local A, B = `gone{Call}a`, `gone{Call}b`
		Funded(Bank, A, B)
		Bank:MarkerFault(Fault.Updates():After(Call - 1))
		Move(Bank, A, B, MOVED, `gone{Call}`)
		Bank:Healed()
		Quiet(T, Bank, { A, B })
	end

	T:Advance(Windows.REAP + 60)
	for _ = 1, PASSES do
		Bank.Store:ReapMarkers()
	end

	T:Is("no marker is left standing", #Bank:Marks(), 0)
	T:Is("no name is left on the cleanup list", next(Bank:Rolled()), nil)
end)

Cases.Case("a fault on one server while another races it still leaves the money whole", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "crossA", "crossB")

	One:MarkerFault(Fault.Updates():After(1))

	local First, Second: any = nil, nil
	T:Race({
		function()
			First = Move(One, "crossA", "crossB", 30, "cross1")
		end,
		function()
			Second = Move(Two, "crossA", "crossB", 40, "cross2")
		end,
	})

	One:Healed()
	local Passes = Quiet(T, Two, { "crossA", "crossB" })
	local Left, Right = Gold(Two, "crossA"), Gold(Two, "crossB")

	T:Is("recovery got there", Passes <= TRIES, true)
	T:Is("the money adds up", Left + Right, START)
	T:Is("the keys are on one side of whichever of the two went through", (Left == START and Right == 0) or (Left == START - 30 and Right == 30) or (Left == START - 40 and Right == 40), true)
	T:Is("both servers were not told yes", First == true and Second == true, false)
	T:Is("the faulted server was not told yes", First, false)
	T:Is("nothing is left parked on the sender", Two:Pending("crossA"), false)
	T:Is("nothing is left parked on the receiver", Two:Pending("crossB"), false)
end)

Cases.Case("a coordinator starved past the leg timeout while another server resettles leaves the money on one side", function(T: Case)
	local Coordinator, Bystander = Pair(T)
	Funded(Coordinator, "slowA", "slowB")

	local Spec = Coordinator:Fault(Fault.Updates():Stall(Windows.LEG + 5))

	local Ok: boolean? = nil
	local Drive = T:Spawn(function()
		Ok = Move(Coordinator, "slowA", "slowB", MOVED, "slow1")
	end)

	local Rounds = 0
	while coroutine.status(Drive) ~= "dead" and Rounds < 200 do
		Rounds += 1
		T:Wait(Windows.POLL)
		Bystander.Store:Resettle("slowA"):Wait()
		Bystander.Store:Resettle("slowB"):Wait()
	end
	Coordinator:Healed()

	local Passes = Quiet(T, Bystander, { "slowA", "slowB" })
	local Left, Right = Gold(Bystander, "slowA"), Gold(Bystander, "slowB")

	T:Ok("the drive finished", coroutine.status(Drive) == "dead")
	T:Ok("the stall fired on every pass", Spec.Fired >= 3)
	T:Is("the coordinator lost every pass to the timeout", Ok, false)
	T:Warns("and said the name was spent", "that name is spent now")
	T:Is("recovery got there", Passes <= TRIES, true)
	T:Is("the money adds up", Left + Right, START)
	T:Ok("both keys are on one side of it", (Left == START and Right == 0) or (Left == START - MOVED and Right == MOVED))
	if Ok then
		T:Is("a yes means the money moved", Right, MOVED)
	end
	T:Is("nothing is left parked on the sender", Bystander:Pending("slowA"), false)
	T:Is("nothing is left parked on the receiver", Bystander:Pending("slowB"), false)
end)

local function Send(Held: Fixture, From: string, To: string, Amount: number, Id: string?): (boolean, any)
	return Held.Store:Transfer(From, To, Amount, Id):Wait()
end

Cases.Case("two servers spending one sender at once move only what it has", function(T: Case)
	local Left, Right = Pair(T)
	Left:Seed("payer", { Gold = 60, Touches = 0 })
	Left:Seed("shopL", { Gold = 0, Touches = 0 })
	Left:Seed("shopR", { Gold = 0, Touches = 0 })

	local Mine, Theirs
	T:Race({
		function()
			Mine = Send(Left, "payer", "shopL", 40, "buyL")
		end,
		function()
			Theirs = Send(Right, "payer", "shopR", 40, "buyR")
		end,
	})
	Quiet(T, Left, { "payer", "shopL", "shopR" })

	local Payer, ShopL, ShopR = Gold(Left, "payer"), Gold(Left, "shopL"), Gold(Left, "shopR")

	T:Is("the money adds up", Payer + ShopL + ShopR, 60)
	T:Is("exactly one of the two went through", (if Mine then 1 else 0) + (if Theirs then 1 else 0), 1)
	T:Is("the one that went through was paid in full", math.max(ShopL, ShopR), 40)
	T:Is("nothing is set aside afterwards", Left:Aside("payer"), 0)
end)

Cases.Case("two servers retrying one transfer id at once move the money once", function(T: Case)
	local Left, Right = Pair(T)
	Left:Seed("twiceA", { Gold = 100, Touches = 0 })
	Left:Seed("twiceB", { Gold = 0, Touches = 0 })

	local Mine, Theirs
	T:Race({
		function()
			Mine = Send(Left, "twiceA", "twiceB", 10, "tip1")
		end,
		function()
			Theirs = Send(Right, "twiceA", "twiceB", 10, "tip1")
		end,
	})
	Quiet(T, Left, { "twiceA", "twiceB" })

	T:Is("the sender", Gold(Left, "twiceA"), 90)
	T:Is("the receiver, paid once", Gold(Left, "twiceB"), 10)
	T:Is("both servers said yes", Mine and Theirs, true)
	T:Is("nothing is set aside afterwards", Left:Aside("twiceA"), 0)
end)

local function ResetUnder(T: Case, Label: string, Key: string, Call: number, PaidByThen: number)
	local Left, Right = Pair(T)
	local A, B = `{Label}A`, `{Label}B`
	Left:Seed(A, { Gold = 100, Touches = 0 })
	Left:Seed(B, { Gold = 0, Touches = 0 })

	local Wiped, Carried, Paid = nil, 0, 0
	local Spec = Left:Fault(Fault.Updates():OnKey(`{Label}{Key}`):Only(Call):Meddle(function()
		Wiped = Right.Store:Reset(A):Wait()
		Carried, Paid = Left:Aside(A), Left:Amount(B)
	end))

	local Sent = Send(Left, A, B, 10, Label)
	Left:Healed()
	Quiet(T, Left, { A, B })

	T:Is("the reset ran inside the transfer", Spec.Fired, 1)
	T:Is("the reset went through", Wiped, true)
	T:Is("the hold, carried across the reset", Carried, 10)
	T:Is("the receiver at the moment of the reset", Paid, PaidByThen)
	T:Is("the transfer went through", Sent, true)
	T:Is("the receiver, paid once", Gold(Left, B), 10)
	T:Is("the sender, reset and holding nothing", Gold(Left, A), 0)
	T:Is("nothing is set aside afterwards", Left:Aside(A), 0)
end

Cases.Case("a reset from another server before the delivery lands neither strands nor doubles the money", function(T: Case)
	ResetUnder(T, "early", "B", 1, 0)
end)

Cases.Case("a reset from another server between the delivery and the settle neither strands nor doubles the money", function(T: Case)
	ResetUnder(T, "late", "A", 2, 10)
end)

return Cases
