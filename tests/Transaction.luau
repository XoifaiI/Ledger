--!strict

--[=[

	Transaction: The cases for Calls/Tx, run end to end on keys by tests/Replay.

	tests/Replay answers each effect as it is sent. Every key is in the store of tests/Gold, whose
	money field is Gold. The Tent words cases step the machine directly with replies from
	tests/Heard.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Answer = require("../src/Core/Answer")
local Asks = require("../src/Machine/Asks")
local Blockers = require("../src/Record/Blockers")
local Book = require("../src/Record/Book")
local Clock = require("../src/Machine/Clock")
local Game = require("./Gold")
local Heard = require("./Heard")
local Machine = require("../src/Machine/Machine")
local Replay = require("./Replay")
local Sizes = require("../src/Core/Constants/Sizes")
local Step = require("../src/Record/Step")
local Tx = require("../src/Calls/Tx")
local Types = require("../src/Record/Types")
local Windows = require("../src/Core/Constants/Windows")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

type Keys = Replay.Keys

local NOW = Clock.Now()
local DEFAULT = Game.DEFAULT
local Gold, Record = Game.Gold, Game.Record
local Fate, Role = Book.Fate, Book.Role

local function Ref(Key: string): Book.Ref
	return { Store = "Gold", Key = Key }
end

local function Seed(Amount: number): unknown
	local Op: Types.Op = { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = Amount } }
	return Step(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = { Op } }, NOW, DEFAULT).Stored
end

local function Put(Keys: Keys, Key: string, Asked: Types.Request)
	Keys[Key] = assert(Step(Keys[Key], Asked, NOW, DEFAULT).Stored, "the setup write did not land")
end

local function Leg(Key: string, Change: Types.Leg): Tx.Leg
	return { Ref = Ref(Key), MustExist = true, Change = Change }
end

local function Transfer(Name: string, Amount: number): Tx.Context
	local Use: Tx.Use = { Name = Name, Stamp = NOW }
	local Legs = { Leg("a", { Field = 1, Amount = -Amount }), Leg("d", { Field = 1, Amount = Amount }) }
	return Tx.Context(Use, Legs, 2, 16)
end

Describe("Transaction incarnations", function()
	local function Erasable(Key: string, Change: Types.Leg): Tx.Leg
		return { Ref = Ref(Key), MustExist = false, Erasable = true, Change = Change }
	end

	local function Start(): (Machine.Call<Tx.Context, any>, { Machine.Asked })
		local Use: Tx.Use = { Name = Book.Drawn(16, 9), Stamp = NOW }
		local Legs = { Erasable("a", { Field = 1, Amount = -5 }), Erasable("d", { Field = 1, Amount = 5 }) }
		return Machine.Start(Tx.Run, Tx.Context(Use, Legs, 2, 16, {}, "f1"), NOW)
	end

	local function Sent(Asked: { Machine.Asked }): Types.Request
		local Ask = Asked[1].Ask
		return if Ask.Kind == "Send" then Ask.Request else error("not a send")
	end

	Test("the legs it does not know are read at once, and each Tent and Commit carries what was found", function()
		local Op: Types.Op = { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = 10 }, Create = "ia" }
		local KeyA = Step(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = { Op } }, NOW, DEFAULT).Stored
		local Call, Asked = Start()
		Expect(#Asked).toBe(2)
		Expect(Asked[1].Ask.Kind == "Read" and Asked[2].Ask.Kind == "Read").toBe(true)
		local Reads = Asked
		Machine.Step(Call, Reads[1].Id, Heard.Read(KeyA))
		Asked = Machine.Step(Call, Reads[2].Id, Heard.Read(nil))
		local Tent = assert(Sent(Asked).Tent)
		Expect(Tent.Id).toBe("ia")
		Expect(Tent.Create).toBeNil()
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Mine", Attempt = 1 }))
		local Commit = assert(Sent(Asked).Commit)
		Expect(Commit.Create).toBe("f1")
		Expect(Commit.Id).toBeNil()
	end)

	Test("a read that fails answers Unresolved and sends nothing", function()
		local Call, Asked = Start()
		Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Asked = Machine.Step(Call, Asked[2].Id, Heard.Failed())
		Expect(#Asked).toBe(0)
		Expect(Machine.AnswerOf(Call)).toBe(Answer.Unresolved)
	end)

	Test("a Commit sent again after one that may have written carries the id, not a create", function()
		local Call, Asked = Start()
		Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Asked = Machine.Step(Call, Asked[2].Id, Heard.Read(nil))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Mine", Attempt = 1 }))
		Expect(assert(Sent(Asked).Commit).Create).toBe("f1")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Fenced", Attempt = 1, Final = false }, true))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Mine", Attempt = 2 }))
		local Again = assert(Sent(Asked).Commit)
		Expect(Again.Id).toBe("f1")
		Expect(Again.Create).toBeNil()
	end)
end)

Describe("Transaction", function()
	Test("a transfer answers true after its Tent and its Commit, and its resolve takes the amount off the sender", function()
		local X = Book.Drawn(16, 1)
		local Keys: Keys = { a = Seed(100), d = Seed(1) }
		local Reply, Updates = Replay.Run(Tx.Run, Transfer(X, 30), Keys, DEFAULT, NOW)
		Expect(Reply).toBe(true)
		Expect(Updates).toBe(3)
		Expect(Gold(Keys.a)).toBe(70)
		Expect(Gold(Keys.d)).toBe(31)
		Expect(Record(Keys.d).Work[X].Form).toBe("Pinned")
		Expect(Record(Keys.a).Timed[X].Role).toBe(Role.Leg)
	end)

	Test("a debit the sender cannot cover answers Refused, and nothing lands on the decider", function()
		local Keys: Keys = { a = Seed(10), d = Seed(1) }
		local Reply = Replay.Run(Tx.Run, Transfer(Book.Drawn(16, 2), 30), Keys, DEFAULT, NOW)
		Expect(Reply).toBe(Answer.Refused)
		Expect(Gold(Keys.a)).toBe(10)
		Expect(Gold(Keys.d)).toBe(1)
		Expect((next(Record(Keys.a).Work))).toBeNil()
	end)

	Test("a fence that is not final makes the call go again under the next attempt, and it applies once", function()
		local X = Book.Drawn(16, 3)
		local Keys: Keys = { a = Seed(100), d = Seed(1) }
		Put(Keys, "d", { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Fence = { Name = X, Stamp = NOW, Attempt = 1, Final = false } })
		local Reply = Replay.Run(Tx.Run, Transfer(X, 30), Keys, DEFAULT, NOW)
		Expect(Reply).toBe(true)
		Expect(Gold(Keys.a)).toBe(70)
		Expect(Gold(Keys.d)).toBe(31)
		local Pinned = Record(Keys.d).Work[X]
		Expect(Pinned.Attempt).toBe(2)
	end)

	Test("a final fence answers Spent and gives back the amount the sender set aside", function()
		local X = Book.Drawn(16, 4)
		local Keys: Keys = { a = Seed(100), d = Seed(1) }
		Put(Keys, "d", { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Fence = { Name = X, Stamp = NOW, Attempt = 1, Final = true } })
		local Reply = Replay.Run(Tx.Run, Transfer(X, 30), Keys, DEFAULT, NOW)
		Expect(Reply).toBe(Answer.Spent)
		Expect(Gold(Keys.a)).toBe(100)
		Expect((next(Record(Keys.a).Work))).toBeNil()
		Expect(Record(Keys.a).Timed[X].Fate).toBe(Fate.Aborted)
	end)

	Test("a retry that finds its decision answers true and writes nothing", function()
		local X = Book.Drawn(16, 5)
		local Keys: Keys = { a = Seed(100), d = Seed(1) }
		Replay.Run(Tx.Run, Transfer(X, 30), Keys, DEFAULT, NOW)
		local Reply, _, Sends = Replay.Run(Tx.Retry, Transfer(X, 30), Keys, DEFAULT, NOW)
		Expect(Reply).toBe(true)
		Expect(Sends).toBe(0)
		Expect(Gold(Keys.a)).toBe(70)
	end)

	Test("a Tent blocked by a younger undecided mark fences it and rides the abort on its resend", function()
		local X, Y = Book.Drawn(16, 6), Book.Drawn(16, 7)
		local Keys: Keys = { a = Seed(100), d = Seed(1), e = Seed(1) }
		Put(Keys, "a", {
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Tent = { Name = Y, Stamp = NOW + 5, Attempt = 1, Decider = Ref("e"), Leg = { Body = { Add = 1 } } },
		})
		local Reply = Replay.Run(Tx.Run, Transfer(X, 30), Keys, DEFAULT, NOW)
		Expect(Reply).toBe(true)
		Expect(Gold(Keys.a)).toBe(70)
		Expect(Record(Keys.a).Timed[Y].Fate).toBe(Fate.Aborted)
		Expect(Record(Keys.e).Timed[Y].Fate).toBe(Fate.Fenced)
	end)

	Test("an owed decider drops only the pinned records whose every leg it saw resolved", function()
		local X = Book.Drawn(16, 8)
		local Keys: Keys = { a = Seed(100), d = Seed(1) }
		local Names: { string } = {}
		for Index = 1, Sizes.OWED_CAP do
			Names[Index] = Book.Drawn(9, Index)
		end
		table.sort(Names)
		for Index, Name in Names do
			local Key = `l{Index}`
			Keys[Key] = if Index == 1 then nil else Seed(1)
			local Commit: Types.Commit = {
				Name = Name,
				Stamp = NOW,
				Attempt = 1,
				Legs = { Ref(Key) },
				Leg = { Field = 1, Amount = 1 },
			}
			Put(Keys, "d", { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Commit = Commit })
		end
		local Reply = Replay.Run(Tx.Run, Transfer(X, 30), Keys, DEFAULT, NOW)
		Expect(Reply).toBe(true)
		local Pinned = 0
		for _, Item in Record(Keys.d).Work do
			Pinned += if Item.Form == "Pinned" then 1 else 0
		end
		Expect(Pinned).toBe(Sizes.OWED_CAP - 7 + 1)
		Expect(Record(Keys.d).Work[Names[1]].Form).toBe("Pinned")
		Expect(Gold(Keys.d)).toBe(1 + Sizes.OWED_CAP + 30)
	end)
end)

Describe("Transaction gates", function()
	Test("a Tent or a Commit at a cut's gate waits until it is SETTLE old, finishes the cut, and goes again", function()
		local Gate: Book.Gate = { Name = "wipe", Stamp = Heard.NOW - 2, Kind = Book.Cause.Reset, Print = 1, At = Heard.NOW - 2 }
		local Use: Tx.Use = { Name = Book.Drawn(16, 30), Stamp = NOW }
		local Context = Tx.Context(Use, { Leg("a", { Field = 1, Amount = -1 }), Leg("d", { Field = 1, Amount = 1 }) }, 2, 16)
		local Call, Asked = Machine.Start(Tx.Run, Context, NOW)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Gated", Gate = Gate }))
		local Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Wait" then Ask.Seconds else -1).toBe(Windows.SETTLE - 2)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Ask = Asked[1].Ask
		local Helping = (if Ask.Kind == "Run" then Ask.Context else nil) :: any
		Expect(Helping and Helping.Cut.Name).toBe("wipe")
		Expect(Helping and Helping.Cut.Helper).toBe(true)
		Expect(Helping and Helping.Ref.Key).toBe("a")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Ask = Asked[1].Ask
		Expect(Ask.Kind == "Send" and Ask.Request.Tent ~= nil).toBe(true)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Mine", Attempt = 1 }))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Gated", Gate = Gate }))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Ask = Asked[1].Ask
		Helping = (if Ask.Kind == "Run" then Ask.Context else nil) :: any
		Expect(Helping and Helping.Ref.Key).toBe("d")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Ask = Asked[1].Ask
		Expect(Ask.Kind == "Send" and Ask.Request.Commit ~= nil).toBe(true)
	end)
end)

Describe("Tent words", function()
	local Blocking: { [string]: Book.Work } = {
		[Book.Drawn(16, 10)] = { Form = "Escrow", Stamp = NOW, Attempt = 1, Clean = true, Decider = Ref("e"), Field = 1, Amount = -1 },
	}

	local function Tents(...: Asks.Heard)
		local Use: Tx.Use = { Name = Book.Drawn(16, 11), Stamp = NOW }
		local Legs = { Leg("a", { Field = 1, Amount = -1 }), Leg("b", { Field = 1, Amount = -1 }), Leg("d", { Field = 1, Amount = 2 }) }
		local Replies = { ... }
		local Call, Asked = Machine.Start(Tx.Run, Tx.Context(Use, { table.unpack(Legs, 1, #Replies + 1) }, #Replies + 1, 16), NOW)
		for Order, Reply in Replies do
			Machine.Step(Call, Asked[Order].Id, Reply)
		end
		return Machine.StateOf(Call), Machine.AnswerOf(Call)
	end

	Test("each Tent reply goes where transaction 3.6 says", function()
		local Goes: { { Heard: Asks.Heard, State: string, Answer: unknown? } } = {
			{ Heard = Heard.Sent({ Report = "Mine" }), State = "Committing" },
			{ Heard = Heard.Sent({ Report = "Refused", Fate = Fate.Refused }), State = "Done", Answer = Answer.Refused },
			{ Heard = Heard.Sent({ Report = "Decided", Fate = Fate.Full }), State = "Done", Answer = Answer.Full },
			{ Heard = Heard.Sent({ Report = "Decided", Fate = Fate.Took }), State = "Fencing" },
			{ Heard = Heard.Sent({ Report = "Other" }), State = "Fencing" },
			{ Heard = Heard.Sent({ Report = "Superseded" }), State = "Fencing" },
			{ Heard = Heard.Sent({ Report = "Large" }), State = "Fencing" },
			{ Heard = Heard.Sent({ Report = "Forgotten" }), State = "Done", Answer = Answer.Expired },
			{ Heard = Heard.Sent({ Why = "Missing" }), State = "Done", Answer = Answer.Missing },
			{ Heard = Heard.Sent({ Why = "Behind" }), State = "Done", Answer = Answer.Behind },
			{ Heard = Heard.Sent({ Report = "Ahead" }), State = "Resting" },
			{ Heard = Heard.Sent({ Report = "NoRoom", Items = Blocking }), State = "Helping" },
			{ Heard = Heard.Sent({ Why = "Overdue", Items = Blocking }), State = "Helping" },
			{ Heard = Heard.Sent({ Report = "Blocked" }), State = "Fencing" },
			{ Heard = Heard.Sent({ Why = "Worn" }), State = "Done", Answer = Answer.Unresolved },
			{ Heard = Heard.Failed(), State = "Done", Answer = Answer.Unresolved },
		}
		for _, Each in Goes do
			local State, Said = Tents(Each.Heard)
			Expect(State).toBe(Each.State)
			Expect(Said).toBe(Each.Answer)
		end
	end)

	Test("when the Tents disagree, the first word in the order of 3.6 decides, with the refusal's own code", function()
		local State, Said = Tents(Heard.Sent({ Report = "Other" }), Heard.Sent({ Report = "Decided", Fate = Fate.Full }))
		Expect(State).toBe("Done")
		Expect(Said).toBe(Answer.Full)
		State = Tents(Heard.Sent({ Report = "Mine" }), Heard.Sent({ Report = "Ahead" }))
		Expect(State).toBe("Resting")
	end)
end)

Describe("Transaction decider value", function()
	local Valued = Game.Build({
		Output = function(State: any): number?
			return State.Gold
		end,
	})

	Test("the leg whose refusal answered the call is kept", function()
		local Use: Tx.Use = { Name = Book.Drawn(16, 13), Stamp = NOW }
		local Legs = { Leg("a", { Field = 1, Amount = -1 }), Leg("b", { Field = 1, Amount = -1 }), Leg("d", { Field = 1, Amount = 2 }) }
		local Context = Tx.Context(Use, Legs, 3, 16)
		local Call, Asked = Machine.Start(Tx.Run, Context, NOW)
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Mine", Attempt = 1 }))
		Machine.Step(Call, Asked[2].Id, Heard.Sent({ Report = "Refused", Attempt = 1, Fate = Book.Fate.Refused }, true))
		Expect(Context.Refuser).toBe(2)
		local Decided = Tx.Context(Use, Legs, 3, 16)
		Call, Asked = Machine.Start(Tx.Run, Decided, NOW)
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Mine", Attempt = 1 }))
		Asked = Machine.Step(Call, Asked[2].Id, Heard.Sent({ Report = "Mine", Attempt = 1 }))
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Refused", Attempt = 1, Fate = Book.Fate.Refused }, true))
		Expect(Decided.Refuser).toBe(3)
	end)

	Test("a commit's decider value rides on every resolve of commit", function()
		local Use: Tx.Use = { Name = Book.Drawn(16, 11), Stamp = NOW }
		local Legs = { Leg("a", { Body = { Add = 1 }, Slot = { "Tag" } }), Leg("d", { Field = 1, Amount = 5 }) }
		local Call, Asked = Machine.Start(Tx.Run, Tx.Context(Use, Legs, 2, 16), NOW)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Mine", Attempt = 1 }))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Committed", Attempt = 1, Value = 9 }, true))
		local Ask = Asked[1].Ask
		local Ends = if Ask.Kind == "Send" then Ask.Request.Ends or {} else {}
		Expect(Ends[#Ends].Outcome).toBe("Commit")
		Expect(Ends[#Ends].Value).toBe(9)
		Expect(Machine.AnswerOf(Call)).toBe(true)
	end)

	Test("a retry and a touch that read the decider learn the value its decision or pinned record keeps", function()
		local Name = Book.Drawn(16, 12)
		local Alone: Types.Request = {
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Commit = { Name = Name, Stamp = NOW, Attempt = 1, Legs = {}, Leg = { Field = 1, Amount = 2 } },
		}
		local Decided = Step(Seed(5), Alone, NOW, Valued).Stored
		local Use: Tx.Use = { Name = Name, Stamp = NOW }
		local Context = Tx.Context(Use, { Leg("a", { Field = 1, Amount = -2 }), Leg("d", { Field = 1, Amount = 2 }) }, 2, 16)
		local Call, Asked = Machine.Start(Tx.Retry, Context, NOW)
		Machine.Step(Call, Asked[1].Id, Heard.Read(Decided))
		Expect(Machine.AnswerOf(Call)).toBe(true)
		Expect(Context.Value).toBe(7)
		local Shared: Types.Request = {
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Commit = { Name = Name, Stamp = NOW, Attempt = 1, Legs = { Ref("a") }, Leg = { Field = 1, Amount = 2 } },
		}
		local Pinned = Step(Seed(5), Shared, NOW, Valued).Stored
		local Mark: Book.Exclusive = { Form = "Exclusive", Stamp = NOW, Attempt = 1, Clean = false, Decider = Ref("d") }
		local Found = Blockers.Read(Pinned, { Name = Name, Item = Mark, Ref = Ref("a") }) :: Blockers.Decision
		Expect(Found.Value).toBe(7)
		Expect(Blockers.End({ Name = Name, Item = Mark, Ref = Ref("a") }, "Commit", 1, Found.Value).Value).toBe(7)
	end)
end)

return nil
