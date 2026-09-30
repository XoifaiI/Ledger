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

return nil
