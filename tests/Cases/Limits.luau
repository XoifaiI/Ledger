--!strict
--!optimize 2

--[=[

	Limits: One rule per hardcoded ceiling, driven past its edge.

	Each case drives past a cap and asks what the caller was told and whether the store still works.
	The reason matters as much as the refusal, since a caller that cannot tell Full from Unresolved
	cannot write a retry.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau
--]=]

local Suite = require("../Suite")

local Windows = require("../../src/Core/Constants/Windows")
local Sizes = require("../../src/Core/Constants/Sizes")
local Measure = require("../../src/Encode/Measure")
local TxStamp = require("../../src/Record/TxStamp")
local Compact = require("../../src/Record/Compact")
local Recovery = require("../../src/Protocol/Recovery")
local TableUtil = require("../../src/Util/TableUtil")
local Sweep = require("../../src/Store/Registry").Sweep()

local Fault = Suite.Fault

type Case = Suite.Case
type Fixture = Suite.Fixture

local SWEEP_LIMIT = 256
local SEEN_LIMIT = 2048
local MAX_PENDING = 4096
local RECOVER_LIMIT = 32
local REAP_LIMIT = 64
local MAX_DEPTH = 64
local MAX_LEGS = 4

local Cases = Suite.File("Limits")

local function Blobber(State: any, Op: any): any?
	if Op.Kind ~= "Stash" then
		return nil
	end

	local Next = table.clone(State)
	Next.Blobs = table.clone(State.Blobs)
	table.insert(Next.Blobs, Op.Text)
	return Next
end

local function Stashing(T: Case, Data: string): Fixture
	return T:Store({ Default = { Blobs = {} }, Reducer = Blobber, Data = Data })
end

local function Deep(Levels: number): { [string]: any }
	local Root: { [string]: any } = {}
	local At = Root
	for _ = 1, Levels do
		local Next: { [string]: any } = {}
		At.Down = Next
		At = Next
	end
	At.Leaf = 1
	return Root
end

Cases.Case("walking a value that points at itself stops instead of overflowing", function(T: Case)
	local Ring: any = {}
	Ring.Self = Ring

	T:Is("measuring a value that points at itself", pcall(Measure, Ring), false)
	T:Is("freezing a value that points at itself", pcall(TableUtil.DeepFreeze, Ring), true)
	T:Is("copying a value that points at itself", pcall(TableUtil.DeepCopy, Ring), true)

	local Chain: any = {}
	local Node = Chain
	for _ = 1, 40 do
		Node.Next = {}
		Node = Node.Next
	end
	T:Is("measuring a value nested less than the cap", pcall(Measure, Chain), true)
end)

Cases.Case("a jammed log blames the parked transaction not the datastore", function(T: Case)
	local Store = Stashing(T, "CaseJam")
	local Text = string.rep("x", 900000)

	Store:Marker("jam1", { Status = "Pending", Total = 2, Gen = "one", Adopted = {} })
	Store:Write("jam", {
		Envelope = 1,
		Seen = {},
		Ops = {
			{ Id = "big1", Kind = "Stash", Text = Text },
			{ Id = "big2", Kind = "Stash", Text = Text },
			{ Id = "tx:jam1:1", Kind = "Stash", Text = "", Tx = "jam1", TxHome = Store.Marked },
		},
	})

	local Active = Store:Session("jam")
	local Ok, Why = Active:Apply("Stash", { Text = "small" })

	T:Is("an op on a log a parked transaction is holding open", Ok, false)
	T:Is("the reason", Why, "Busy")
	T:Warns("it names the parked transaction as the cause", "transaction is parked on it")
	T:Silent("it does not send them looking at the datastore", "check the datastore")
end)

Cases.Case("an edit too big for the log says Full rather than Unresolved", function(T: Case)
	local Store = Stashing(T, "CaseFull")
	local Text = string.rep("x", 900000)

	Store:Marker("brim1", { Status = "Pending", Total = 2, Gen = "one", Adopted = {} })
	Store:Park("brim", { Id = "tx:brim1:1", Kind = "Stash", Text = "", Tx = "brim1" })

	local Landed, Why = 0, nil
	for _ = 1, 4 do
		local Ok, Reason = Store.Store:Edit("brim", "Stash", { Text = Text }):Wait()
		if Ok then
			Landed += 1
		else
			Why = Reason
		end
	end

	T:Is("some writes fit before the cap", Landed > 0, true)
	T:Is("the write that did not fit", Landed < 4, true)
	T:Is("the reason it gives", Why, "Full")
end)

Cases.Case("a log of few but huge ops is still compacted", function(T: Case)
	local Store = Stashing(T, "CaseHuge")
	local Text = string.rep("x", 200000)

	local Landed = 0
	for _ = 1, 8 do
		if Store.Store:Edit("huge", "Stash", { Text = Text }):Wait() then
			Landed += 1
		end
	end

	local Record = Store:Record("huge")
	local Stashed = if type(Record.Snapshot) == "table" then #(Record.Snapshot :: any).Blobs else 0

	T:Is("every write landed", Landed, 8)
	T:Is("ops still uncompacted once they outweigh the threshold", #Record.Ops < 8, true)
	T:Is("everything stashed survived the compaction", Stashed + #Record.Ops, 8)
end)

Cases.Case("the sweep refuses to follow more keys than its cap", function(T: Case)
	local Store = Stashing(T, "CaseCap")
	local Before = Sweep.Count

	for Index = 1, SWEEP_LIMIT + 8 do
		Sweep:Add(Store.Store:Swept(), `cap{Index}`)
	end

	T:Is("keys followed once the cap is reached", Sweep.Count, SWEEP_LIMIT)
	T:Warns("it said why it stopped", "recovery sweep is already following")

	Sweep:Forget(Store.Store:Swept())
	T:Is("forgetting a store clears its keys again", Sweep.Count, Before)
end)

Cases.Case("the sweep still works after its follow list filled", function(T: Case)
	local Store = Stashing(T, "CaseCapWork")
	for Index = 1, SWEEP_LIMIT + 8 do
		Sweep:Add(Store.Store:Swept(), `full{Index}`)
	end

	local Ok = pcall(function()
		Sweep:Pass()
	end)
	Sweep:Forget(Store.Store:Swept())

	T:Is("a pass over a full follow list", Ok, true)
end)

Cases.Case("an overfull seen list is trimmed by the next compaction", function(T: Case)
	local Bank = T:Bank()

	local Stale: { string } = {}
	for Index = 1, SEEN_LIMIT * 2 do
		Stale[Index] = `old{Index}`
	end
	Bank:Write("a", { Snapshot = { Gold = 5, Touches = 0 }, Ops = {}, Seen = Stale })

	Bank:Append("a", { { Id = "fresh", Kind = "Fund", Amount = 1 } })
	local Packed = Bank:Log():Compact("a", Bank:Format())

	T:Is("the seen list was trimmed to the window", #Packed.Seen <= SEEN_LIMIT + 1, true)
	T:Is("the newest id survived the trim", Packed.Seen[#Packed.Seen], "fresh")
	T:Is("gold is untouched by the trim", Bank:Amount("a"), 6)
	T:Is("the record still refuses that id", (Bank.Store:Edit("a", "Fund", { Amount = 1 }):Wait()), true)
end)

Cases.Case("a session refuses ops past its pending cap", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })
	local Active = Bank:Session("a")

	local Accepted, Why = 0, nil :: any
	for _ = 1, MAX_PENDING + 4 do
		local Took, Reason = Active:Apply("Touch")
		if Took then
			Accepted += 1
		else
			Why = Reason
		end
	end

	T:Is("ops accepted before the cap bit", Accepted, MAX_PENDING)
	T:Is("the reason it gave", Why, "Backlog")
	T:Warns("it said why", "are already pending")

	local Saved = Active:Flush():Wait()
	T:Is("the backlog still flushes", Saved, true)
	T:Is("the session takes ops again afterwards", (Active:Apply("Touch")), true)
end)

Cases.Case("recovery handles only so many held transfers at once", function(T: Case)
	local Bank = T:Bank()

	local Born = T:Now()
	local Held: { [string]: any } = {}
	for Index = 1, RECOVER_LIMIT + 5 do
		Held[`t{Index}`] = { To = "b", Amount = 1, At = Born }
	end
	Bank:Write("a", { Snapshot = { Gold = 0, Touches = 0, _Held = Held }, Ops = {}, Seen = {} })
	Bank:Seed("b", { Gold = 0 })

	T:Advance(10 * 86400)

	local Cleared = Recovery.Transfers(Bank:Log(), Bank:Format(), "a", Held)

	T:Is("it did not claim to have finished", Cleared, false)
	T:Warns("it said what it left", "unfinished transfers")

	local Left: any = Bank:Stored("a")
	local Standing = 0
	for _ in (if type(Left._Held) == "table" then Left._Held else {}) :: any do
		Standing += 1
	end
	T:Is("it left the overflow for the next pass", Standing, 5)
	T:Is("money still adds up", Bank:Amount("a") + Bank:Amount("b") + Standing, RECOVER_LIMIT + 5)
end)

Cases.Case("reaping is capped per pass and finishes over several", function(T: Case)
	local Store = Stashing(T, "CaseReapCap")

	for Index = 1, REAP_LIMIT + 20 do
		Store:Marker(`husk{Index}`, { Status = "Aborted", Total = 1, Gen = "one", Adopted = {} })
	end
	T:Advance(Windows.REAP + 60)

	local First = Store.Store:ReapMarkers()
	T:Is("one pass is capped", First <= REAP_LIMIT, true)
	T:Is("one pass did real work", First > 0, true)

	for _ = 1, 4 do
		T:Advance(Windows.REAP_GRACE + 60)
		Store.Store:ReapMarkers()
	end

	T:Is("later passes finish the rest", #Store:Marks(), 0)
end)

Cases.Case("an op nested deeper than the cap is refused", function(T: Case)
	local Store = Stashing(T, "CaseDeep")

	T:Is("an op just inside the depth cap", (Store.Store:Edit("a", "Stash", { Text = Deep(MAX_DEPTH - 4) }):Wait()), true)
	T:Is("an op past the depth cap", (Store.Store:Edit("a", "Stash", { Text = Deep(MAX_DEPTH + 8) }):Wait()), false)
	T:Is("the store still takes an ordinary op", (Store.Store:Edit("a", "Stash", { Text = "fine" }):Wait()), true)
end)

Cases.Case("a transaction wider than the leg cap is refused", function(T: Case)
	local Bank = T:Bank()
	for Index = 1, MAX_LEGS + 1 do
		Bank:Seed(`k{Index}`, { Gold = 100 })
	end

	local Legs: { any } = {}
	for Index = 1, MAX_LEGS + 1 do
		Legs[Index] = { Key = `k{Index}`, Kind = "Fund", Fields = { Amount = 1 } }
	end

	T:Throws("one leg too many", function()
		Bank.Store:Tx("wide", Legs):Wait()
	end)

	table.remove(Legs)
	T:Is("exactly the cap", (Bank.Store:Tx("atcap", Legs):Wait()), true)
	T:Is("gold moved on the last leg", Bank:Amount(`k{MAX_LEGS}`), 101)
end)

Cases.Case("a record swollen by a stuck leg stops at the ceiling and recovers", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("swollen", { Gold = 100 })
	Bank:Marker("swollen1", { Status = "Pending", Total = 2, Gen = "one", At = T:Now(), Adopted = {} })
	Bank:Park("swollen", { Id = "tx:swollen1:1", Kind = "Give", Amount = -25, Tx = "swollen1" })

	Bank:MarkerFault(Fault.Reads())

	local Fat = string.rep("x", 60000)
	local Landed, Refused = 0, 0
	for _ = 1, 80 do
		local Ok, Why = Bank.Store:Edit("swollen", "Fund", { Amount = 1, Note = Fat }):Wait()
		if Ok then
			Landed += 1
		else
			Refused += 1
			T:Is("the reason a write past the ceiling gives", Why, "Full")
		end
	end

	local Swollen = Bank:Record("swollen")
	T:Is("writes kept landing until the ceiling", Landed > 0, true)
	T:Is("writes past the ceiling were refused rather than lost", Refused > 0, true)
	T:Is("the log is past the size compaction wants to fire at", Compact.Overgrown(Swollen), true)
	T:Is("the leg is still parked while the marker store is dark", TxStamp.HasPending(Swollen), true)
	T:Is("the record is still readable", (Bank.Store:Peek("swollen"):Wait() :: any) ~= nil, true)

	Bank:Healed()
	T:Advance(Windows.TX * 4)
	local Clean = Bank.Store:Resettle("swollen"):Wait()

	local Healed = Bank:Record("swollen")
	T:Is("the resettle finished once the marker store answered", Clean, true)
	T:Is("nothing is left pending", TxStamp.HasPending(Healed), false)
	T:Is("the gold every landed write added", Bank:Amount("swollen"), 100 + Landed)

	Bank:Log():Trim("swollen", Bank:Format(), Healed)
	T:Is("the log compacts again now the leg is gone", #Bank:Record("swollen").Ops < #Swollen.Ops, true)
end)

Cases.Case("a state filled by Ledger's own bookkeeping says whose it is", function(T: Case)
	Sizes.Set({ Value = 65536, State = 4096, Op = 1024, Log = 2048, Compact = 1024 })

	local Store = Stashing(T, "CaseOwnCap")
	local Names: any = {}
	for Index = 1, 30 do
		Names[`o:{string.rep("n", 100)}{Index}`] = T:Now()
	end
	Store:Write("mine", { Snapshot = { Blobs = {}, _Received = Names }, Ops = {}, Seen = {} })

	Store:Log():Compact("mine", Store:Format())

	T:Warns("it said the state is near the cap", "Ledger stops taking writes at")
	T:Warns("it named the largest field", "largest field '_Received'")
	T:Warns("it said the field is Ledger's own", "Ledger's own bookkeeping and your game cannot take it out")
	T:Silent("it did not tell them to take out their own data", "take out what the game no longer reads")
end)

Cases.Case("a record that cannot compact says what is blocking it", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("saidso", { Gold = 100 })
	Bank:Marker("saidso1", { Status = "Pending", Total = 2, Gen = "one", At = T:Now(), Adopted = {} })
	Bank:Park("saidso", { Id = "tx:saidso1:1", Kind = "Give", Amount = -25, Tx = "saidso1" })
	Bank:MarkerFault(Fault.Reads())

	local Fat = string.rep("x", 60000)
	for _ = 1, 30 do
		Bank.Store:Edit("saidso", "Fund", { Amount = 1, Note = Fat }):Wait()
	end
	Bank:Healed()

	T:AtMost("it says the record cannot be compacted, and does not repeat itself on every write", "cannot compact away", 4)
	T:Warns("it names the transaction holding it", "saidso1")
end)

Cases.Case("a session filled to the log cap can still flush what it took", function(T: Case)
	Sizes.Set({ Log = 999 })

	local Bank = T:Bank()
	Bank:Seed("brim", { Gold = 0, Touches = 0 })
	local Active = Bank:Session("brim")

	local Taken, Why = 0, nil
	for _ = 1, 200 do
		local Ok, Reason = Active:Apply("Touch")
		if not Ok then
			Why = Reason
			break
		end
		Taken += 1
	end

	local Flushed, FlushWhy = Active:Flush():Wait()

	T:Is("the apply the cap refused", Why, "Backlog")
	T:Is("the flush of everything the cap let in", Flushed, true)
	T:Is("no reason", FlushWhy, nil)
	T:Is("ops on disk", #Bank:Record("brim").Ops, Taken)
	T:Is("ops still pending", #Active.Pending, 0)
end)

return Cases
