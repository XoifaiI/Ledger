--!strict
--!optimize 2

--[=[

	Once: One rule per case for a caller named op that lands at most one time.

	The same name offered again across a replay, a compaction, a fresh session, two servers at once,
	and a key that was erased and came back. Names age out at the prune window, transaction ids
	included.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau
--]=]

local Suite = require("../Suite")

local Tags = require("../../src/Core/Constants/Tags")

type Case = Suite.Case

local Horizons = Suite.Horizons

local DAY = 86400
local PRUNE_HORIZON = 30 * DAY
local PAST_PRUNE = 31 * DAY
local ONCE_MARGIN = Horizons.ONCE_MARGIN
local ONCE_FLOOR = Horizons.ONCE_FLOOR

local Cases = Suite.File("Once")

local function Named(Active: any, Kind: string, Name: string, Amount: number): boolean
	return (Active:Apply(Kind, { Amount = Amount, Once = Name }))
end

Cases.Case("an op named Once is remembered when it is accepted", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 100 })

	local Active = Bank:Session("a")
	T:Is("unknown before it runs", Active:DidApply("grant1"), false)
	T:Is("the apply was accepted", Named(Active, "Fund", "grant1", 50), true)
	T:Is("remembered after it ran", Active:DidApply("grant1"), true)
	T:Is("gold moved once", Active:Get().Gold, 150)
end)

Cases.Case("an op named Once is not remembered when the reducer refuses it", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 10 })

	local Active = Bank:Session("a")
	T:Is("a reducer that refused", Named(Active, "Give", "grant1", -500), false)
	T:Is("nothing was remembered", Active:DidApply("grant1"), false)
	T:Is("gold untouched", Active:Get().Gold, 10)
end)

Cases.Case("a refused Once name is still free to use later", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 10 })

	local Active = Bank:Session("a")
	Named(Active, "Give", "grant1", -500)
	Named(Active, "Fund", "topup", 1000)

	T:Is("the same name once funds arrived", Named(Active, "Give", "grant1", -500), true)
	T:Is("remembered this time", Active:DidApply("grant1"), true)
	T:Is("gold after it landed", Active:Get().Gold, 510)
end)

Cases.Case("a replay under the same Once name changes nothing", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	local Active = Bank:Session("a")
	T:Is("the first", Named(Active, "Fund", "grant1", 50), true)
	T:Is("the replay", Named(Active, "Fund", "grant1", 50), false)
	T:Is("the third", Named(Active, "Fund", "grant1", 50), false)

	Active:Flush():Wait()
	T:Is("gold in the session", Active:Get().Gold, 50)
	T:Is("gold on disk", Bank:Amount("a"), 50)
end)

Cases.Case("a Once name is still known after the log is compacted", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	local Active = Bank:Session("a")
	Named(Active, "Fund", "grant1", 50)
	Active:Flush():Wait()
	Active:Compact():Wait()

	T:Is("the log was compacted", #Bank:Record("a").Ops, 0)
	T:Is("the name survived it", Active:DidApply("grant1"), true)
	T:Is("a replay after compaction", Named(Active, "Fund", "grant1", 50), false)
	T:Is("gold still granted once", Active:Get().Gold, 50)
end)

Cases.Case("a Once name is still known to a fresh session", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	local First = Bank:Session("a")
	Named(First, "Fund", "grant1", 50)
	First:Flush():Wait()
	First:Compact():Wait()

	local Rejoined = Bank:Session("a")
	T:Is("the name after rejoining", Rejoined:DidApply("grant1"), true)
	T:Is("a replay after rejoining", Named(Rejoined, "Fund", "grant1", 50), false)
	T:Is("gold after rejoining", Rejoined:Get().Gold, 50)
end)

Cases.Case("two servers racing one Once name apply it once", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	local Left, Right = Bank:Session("a"), Bank:Session("a")
	T:Race({
		function()
			Named(Left, "Fund", "grant1", 50)
			Left:Flush():Wait()
		end,
		function()
			Named(Right, "Fund", "grant1", 50)
			Right:Flush():Wait()
		end,
	})

	T:Is("gold on disk after both servers", Bank:Amount("a"), 50)
end)

Cases.Case("Edit can name an op Once on a key with no session", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	T:Is("the first edit", (Bank.Store:Edit("a", "Fund", { Amount = 50, Once = "grant1" }):Wait()), true)
	T:Is("the replayed edit", (Bank.Store:Edit("a", "Fund", { Amount = 50, Once = "grant1" }):Wait()), false)
	T:Is("gold after both edits", Bank:Amount("a"), 50)
	T:Is("the store knows the name", Bank.Store:DidApply("a", "grant1"):Wait(), true)
	T:Is("a name never used", Bank.Store:DidApply("a", "grant2"):Wait(), false)
end)

Cases.Case("an offline edit and a live session share one Once name", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	Bank.Store:Edit("a", "Fund", { Amount = 50, Once = "grant1" }):Wait()

	local Active = Bank:Session("a")
	T:Is("the session sees the offline name", Active:DidApply("grant1"), true)
	T:Is("the session cannot replay it", Named(Active, "Fund", "grant1", 50), false)
	T:Is("gold after both paths", Active:Get().Gold, 50)
end)

Cases.Case("a Once name and a transfer id may be the same string", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 500 })
	Bank:Seed("b", { Gold = 0 })

	Bank.Store:Transfer("a", "b", 100, "shared"):Wait()
	T:Is("the transfer landed", Bank:Amount("b"), 100)

	T:Is("a Once under the same string", (Bank.Store:Edit("b", "Fund", { Amount = 7, Once = "shared" }):Wait()), true)
	T:Is("gold after both", Bank:Amount("b"), 107)
	T:Is("the Once name is known", Bank.Store:DidApply("b", "shared"):Wait(), true)
end)

Cases.Case("a Once name and a transaction id may be the same string", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 500 })
	Bank:Seed("b", { Gold = 0 })

	Bank.Store
		:Tx("shared", {
			{ Key = "a", Kind = "Give", Fields = { Amount = -100 } },
			{ Key = "b", Kind = "Fund", Fields = { Amount = 100 } },
		})
		:Wait()
	T:Is("the transaction landed", Bank:Amount("b"), 100)

	T:Is("a Once under the same string", (Bank.Store:Edit("b", "Fund", { Amount = 7, Once = "shared" }):Wait()), true)
	T:Is("gold after both", Bank:Amount("b"), 107)
end)

Cases.Case("ClearDelivered forgets every name older than the horizon", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 500 })
	Bank:Seed("b", { Gold = 0 })

	Bank.Store:Transfer("a", "b", 100, "tip1"):Wait()
	Bank.Store:Edit("b", "Fund", { Amount = 7, Once = "grant1" }):Wait()

	T:Is("the transfer entry before the prune", Bank:Knows("b", Tags.TRANSFER, "tip1"), true)
	T:Is("the Once entry before the prune", Bank:Knows("b", Tags.ONCE, "grant1"), true)

	T:Advance(PAST_PRUNE)
	Bank.Store:ClearDelivered("b"):Wait()

	T:Is("the transfer entry after the prune", Bank:Knows("b", Tags.TRANSFER, "tip1"), false)
	T:Is("the Once entry after the prune, which ages out on the same rule", Bank:Knows("b", Tags.ONCE, "grant1"), false)

	T:Is("a replay a month after the name was applied", (Bank.Store:Edit("b", "Fund", { Amount = 7, Once = "grant1" }):Wait()), true)
	T:Is("gold after the prune and replay", Bank:Amount("b"), 114)
end)

Cases.Case("ClearDelivered keeps a transaction id it used to drop", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 500 })
	Bank:Seed("b", { Gold = 0 })

	Bank.Store
		:Tx("deal1", {
			{ Key = "a", Kind = "Give", Fields = { Amount = -100 } },
			{ Key = "b", Kind = "Fund", Fields = { Amount = 100 } },
		})
		:Wait()
	T:Is("the transaction id before the prune", Bank:Knows("b", Tags.TX, "deal1"), true)

	Bank.Store:ClearDelivered("b"):Wait()
	T:Is("the transaction id after the prune", Bank:Knows("b", Tags.TX, "deal1"), true)
end)

Cases.Case("a transaction id is forgotten once it is older than the prune horizon", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 100 })
	Bank:Seed("b", { Gold = 100 })

	local Legs = {
		{ Key = "a", Kind = "Fund", Fields = { Amount = 100 } },
		{ Key = "b", Kind = "Fund", Fields = { Amount = 100 } },
	}
	Bank.Store:Tx("deal", Legs):Wait()
	local After = Bank:Amount("a") + Bank:Amount("b")

	Bank:Forget("a", { "tx:" })
	Bank:Forget("b", { "tx:" })

	T:Advance(PAST_PRUNE)
	Bank.Store:Edit("a", "Fund", { Amount = 0, Once = "later" }):Wait()
	Bank.Store:Edit("b", "Fund", { Amount = 0, Once = "later2" }):Wait()

	local Known = Bank:Knows("a", Tags.TX, "deal")
	local Again = (Bank.Store:Tx("deal", Legs):Wait())

	T:Is("the transaction id, once it is older than the horizon", Known, false)
	T:Is("asking again once both guards lapsed", Again, true)
	T:Is("gold after the transaction", After, 400)
	T:Is("gold after asking again under the same name a month later", Bank:Amount("a") + Bank:Amount("b"), 600)
end)

Cases.Case("a Once name is forgotten once it is older than the prune horizon", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	Bank.Store:Edit("a", "Fund", { Amount = 1, Once = "old" }):Wait()
	T:Is("the old name right after it ran", Bank.Store:DidApply("a", "old"):Wait(), true)

	T:Advance(PRUNE_HORIZON + 60)
	Bank.Store:Edit("a", "Fund", { Amount = 1, Once = "new" }):Wait()

	T:Is("the old name once the horizon passed", Bank.Store:DidApply("a", "old"):Wait(), false)
	T:Is("the new name", Bank.Store:DidApply("a", "new"):Wait(), true)
	T:Is("gold after both", Bank:Amount("a"), 2)
end)

Cases.Case("a forged OnceAt cannot erase delivery evidence", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 100 })
	Bank:Seed("b", { Gold = 0 })

	Bank.Store:Transfer("a", "b", 40, "tip"):Wait()
	local Before = Bank:Knows("b", Tags.TRANSFER, "tip")

	Bank.Store:Edit("b", "Fund", { Amount = 1, Once = "grant", OnceAt = T:Now() + 400 * DAY }):Wait()
	local After = Bank:Knows("b", Tags.TRANSFER, "tip")

	Bank:Append("b", {
		{ Id = "del2:tip", Kind = "__TransferDeliver", Tid = "tip", Amount = 40, At = T:Now() } :: any,
	})

	T:Is("the delivery was remembered", Before, true)
	T:Is("the grant landed", Bank.Store:DidApply("b", "grant"):Wait(), true)
	T:Is("a forged OnceAt does not erase the evidence", After, true)
	T:Is("gold after the same delivery arrives again", Bank:Amount("b"), 41)
end)

Cases.Case("an erased key still remembers what was already paid out", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	Bank.Store:Edit("a", "Fund", { Amount = 100, Once = "receipt:one" }):Wait()
	Bank.Store:Edit("a", "Fund", { Amount = 100, Once = "receipt:two" }):Wait()
	T:Is("gold before the erase", Bank:Amount("a"), 200)

	Bank.Store:Erase("a"):Wait()

	T:Is("the profile is fresh again", Bank:Amount("a"), 0)
	T:Is("the first receipt is still remembered", Bank.Store:DidApply("a", "receipt:one"):Wait(), true)
	T:Is("the second receipt is still remembered", Bank.Store:DidApply("a", "receipt:two"):Wait(), true)

	T:Is("a receipt replayed after the erase", (Bank.Store:Edit("a", "Fund", { Amount = 100, Once = "receipt:one" }):Wait()), false)
	T:Is("gold after the replay", Bank:Amount("a"), 0)

	T:Is("a name that was never used still works", (Bank.Store:Edit("a", "Fund", { Amount = 5, Once = "receipt:new" }):Wait()), true)
	T:Is("gold after a genuinely new grant", Bank:Amount("a"), 5)
end)

Cases.Case("a forged OnceAt on a hand built op cannot erase delivery evidence", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 100 })
	Bank:Seed("b", { Gold = 0 })

	Bank.Store:Transfer("a", "b", 40, "tip"):Wait()
	Bank.Store:Edit("b", "Fund", { Amount = 1, Once = "grant" }):Wait()

	local Active = Bank:Session("b")
	Active:CommitOp({
		Id = "forged",
		Kind = "Fund",
		Amount = 1,
		Once = "handbuilt",
		OnceAt = T:Now() + 400 * DAY,
	} :: any):Wait()

	T:Is("the delivery is still remembered", Bank:Knows("b", Tags.TRANSFER, "tip"), true)
	T:Is("the earlier Once name is still remembered", Bank:Knows("b", Tags.ONCE, "grant"), true)

	Bank:Append("b", {
		{ Id = "del2:tip", Kind = "__TransferDeliver", Tid = "tip", Amount = 40, At = T:Now() } :: any,
	})
	T:Is("gold after the same delivery arrives again", Bank:Amount("b"), 42)
end)

Cases.Case("a backdated OnceAt past the floor is refused", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	local Active = Bank:Session("a")
	local Took, Why = Active:CommitOp({
		Id = "back1",
		Kind = "Fund",
		Amount = 1,
		Once = "gift",
		OnceAt = T:Now() - (ONCE_FLOOR + 60),
	} :: any):Wait()

	Bank.Store:Edit("a", "Fund", { Amount = 5, Once = "fresh" }):Wait()

	T:Is("a commit stamped a minute past the floor", Took, false)
	T:Is("the reason", Why, "Invalid")
	T:Is("the name it would have been written under", Bank:Knows("a", Tags.ONCE, "gift"), false)
	T:Is("gold, so nothing was granted under it", Bank:Amount("a"), 5)
	T:Warns("it said the stamp was too far back", "further back than the", 1)
end)

Cases.Case("a name stamped at the floor still turns a retry away a margin later", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	local Active = Bank:Session("a")
	local Took = Active:CommitOp({
		Id = "back2",
		Kind = "Fund",
		Amount = 1,
		Once = "gift",
		OnceAt = T:Now() - ONCE_FLOOR,
	} :: any):Wait()

	T:Advance(ONCE_MARGIN - DAY)
	Bank.Store:Edit("a", "Fund", { Amount = 5, Once = "fresh" }):Wait()

	T:Is("a commit stamped at the oldest the floor allows", Took, true)
	T:Is("the name once a later write carried one of its own", Bank:Knows("a", Tags.ONCE, "gift"), true)
	T:Is("the same name offered again", (Bank.Store:Edit("a", "Fund", { Amount = 1, Once = "gift" }):Wait()), false)
	T:Is("gold, granted one time", Bank:Amount("a"), 6)
end)

Cases.Case("a backdated OnceAt cannot age out the name", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	Bank.Store:Edit("a", "Fund", { Amount = 1, Once = "dup", OnceAt = T:Now() - 40 * DAY }):Wait()
	Bank.Store:Edit("a", "Fund", { Amount = 5, Once = "fresh" }):Wait()

	local Known = Bank.Store:DidApply("a", "dup"):Wait()
	local Replayed = Bank.Store:Edit("a", "Fund", { Amount = 1, Once = "dup" }):Wait()

	T:Is("the name is still known after a later write", Known, true)
	T:Is("a replay under it", Replayed, false)
	T:Is("gold granted once per name", Bank:Amount("a"), 6)
end)

Cases.Case("a Once name older than the prune horizon is forgotten and pays again", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	Bank.Store:Edit("a", "Fund", { Amount = 1, Once = "old" }):Wait()
	T:Is("the name once it lands", (Bank.Store:DidApply("a", "old"):Wait()), true)

	T:Advance(PAST_PRUNE)
	Bank.Store:Edit("a", "Fund", { Amount = 5, Once = "new" }):Wait()

	T:Is("the name from before the horizon", Bank:Knows("a", Tags.ONCE, "old"), false)
	T:Is("the name from after it", Bank:Knows("a", Tags.ONCE, "new"), true)
	T:Is("what the store knows of the older name", (Bank.Store:DidApply("a", "old"):Wait()), false)

	local Replayed = Bank.Store:Edit("a", "Fund", { Amount = 1, Once = "old" }):Wait()
	T:Is("a replay under a name that aged out", Replayed, true)
	T:Is("gold once that replay has paid", Bank:Amount("a"), 7)
end)

Cases.Case("a Once name inside the prune horizon survives a jump that is almost it", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	Bank.Store:Edit("a", "Fund", { Amount = 1, Once = "held" }):Wait()

	T:Advance(PRUNE_HORIZON - DAY)
	Bank.Store:Edit("a", "Fund", { Amount = 5, Once = "later" }):Wait()

	local Replayed = Bank.Store:Edit("a", "Fund", { Amount = 1, Once = "held" }):Wait()

	T:Is("the name a day inside the window", (Bank.Store:DidApply("a", "held"):Wait()), true)
	T:Is("a replay under it", Replayed, false)
	T:Is("gold with the name still held", Bank:Amount("a"), 6)
end)

Cases.Case("a Once name that is not a non empty string is refused", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	local Active = Bank:Session("a")

	local Numeric, NumericWhy = Active:Apply("Fund", { Amount = 1, Once = 5 })
	T:Is("a numeric Once", Numeric, false)
	T:Is("the reason for a numeric Once", NumericWhy, "Invalid")

	local Empty, EmptyWhy = Active:Apply("Fund", { Amount = 1, Once = "" })
	T:Is("an empty Once", Empty, false)
	T:Is("the reason for an empty Once", EmptyWhy, "Invalid")

	local Committed, CommittedWhy = Active:Commit("Fund", { Amount = 1, Once = 5 }):Wait()
	T:Is("a commit with a numeric Once", Committed, false)
	T:Is("the reason a commit gives", CommittedWhy, "Invalid")

	local Edited, EditedWhy = Bank.Store:Edit("a", "Fund", { Amount = 1, Once = "" }):Wait()
	T:Is("an edit with an empty Once", Edited, false)
	T:Is("the reason an edit gives", EditedWhy, "Invalid")

	local Handed, HandedWhy = Active:CommitOp({ Id = "hand1", Kind = "Fund", Amount = 1, Once = 5 } :: any):Wait()
	T:Is("a hand built op with a numeric Once", Handed, false)
	T:Is("the reason a hand built op gives", HandedWhy, "Invalid")

	T:Is("gold untouched by any of it", Active:Get().Gold, 0)
end)

Cases.Case("a transaction leg refuses a Once name because the id already is one", function(T: Case)
	local Bank = T:Bank()
	local Side = T:Vault()
	Bank:Seed("a", { Gold = 500 })

	T:Throws("a leg carrying Once", function()
		Bank.Store
			:Tx("deal1", {
				{ Key = "a", Kind = "Give", Fields = { Amount = -100, Once = "legname" } },
				{ Store = Side.Store, Key = "v", Kind = "Vault", Fields = { Coins = 100 } },
			})
			:Wait()
	end)
	T:Is("gold untouched", Bank:Amount("a"), 500)
end)

Cases.Case("a hand built op named Once is still remembered across a compaction", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0 })

	local Active = Bank:Session("a")
	local Receipt = { Id = "receipt:ABC", Kind = "Fund", Amount = 500, Once = "receipt:ABC" }

	T:Is("the grant", (Active:CommitOp(table.clone(Receipt) :: any):Wait()), true)
	Active:Compact():Wait()

	local Rejoined = Bank:Session("a")
	T:Is("the receipt is still known", Rejoined:DidApply("receipt:ABC"), true)
	T:Is("a replay grants nothing", (Rejoined:CommitOp(table.clone(Receipt) :: any):Wait()), false)
	T:Is("gold granted once", Bank:Amount("a"), 500)
end)

return Cases
