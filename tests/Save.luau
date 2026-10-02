--!strict

--[=[

	Save: The cases for Calls/Save, stepped directly with the replies it hears.

	Every note is built by hand. A landing note says its op took and holds a value to write.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Requests = require("../src/Record/Requests")
local Testing = require("./Testing")
local Book = require("../src/Record/Book")
local Game = require("./Gold")
local Heard = require("./Heard")
local Machine = require("../src/Machine/Machine")
local Queue = require("../src/Record/Queue")
local Save = require("../src/Calls/Save")
local Touch = require("../src/Calls/Touch")
local Unseal = require("../src/Calls/Unseal")
local Types = require("../src/Record/Types")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local NOW = Heard.NOW
local LANDED = { Fates = { [1] = Book.Fate.Took }, Stored = { s = {}, b = "" } }

local function Op(Add: number): Queue.Asked
	return { Form = "Minted", Kind = 0, MustExist = false, Body = { Add = Add } }
end

local function Held(): Queue.Queue
	return Queue.New({ Store = "Gold", Key = "42" }, Game.DEFAULT, 16, nil, NOW)
end

local function Start(Kept: Queue.Queue, Landed: ((Note: Types.Note) -> ())?)
	return Machine.Start(Save.Machine, Save.Context(Kept, Landed), NOW)
end

local function Request(Asked: { Machine.Asked }): Requests.Request
	local Ask = Asked[1].Ask
	return if Ask.Kind == "Send" then Ask.Request else error("not a send")
end

Describe("Save", function()
	Test("a reply that settles nothing rests longer each time, and a landing that empties the queue answers Empty", function()
		local Kept = Held()
		Queue.Push(Kept, Op(5))
		local Call, Asked = Start(Kept)
		local Waits: { number } = {}
		for _ = 1, 3 do
			Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({}))
			local Ask = Asked[1].Ask
			table.insert(Waits, if Ask.Kind == "Wait" then Ask.Seconds else -1)
			Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		end
		Expect(table.concat(Waits, " ")).toBe("1 2 4")
		Machine.Step(Call, Asked[1].Id, Heard.Sent(LANDED))
		Expect(Machine.AnswerOf(Call)).toBe(Save.SAID.Empty)
		Expect(#Kept.Items).toBe(0)
	end)

	Test("a landing that leaves ops queued sends them at once, numbered on", function()
		local Kept = Held()
		Queue.Push(Kept, Op(5))
		local Call, Asked = Start(Kept)
		Queue.Push(Kept, Op(2))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent(LANDED))
		Expect(Request(Asked).Ops[1].Seq).toBe(2)
	end)

	Test("each fate goes to its op's Tell, and each landing to Landed", function()
		local Kept = Held()
		local Replies: { any } = {}
		Queue.Push(Kept, Op(5), function(_: Queue.Asked, Reply: Queue.Reply)
			table.insert(Replies, Reply)
		end)
		local Landings = 0
		local Call, Asked = Start(Kept, function()
			Landings += 1
		end)
		Machine.Step(Call, Asked[1].Id, Heard.Sent(LANDED))
		Expect(Replies[1]).toBe(true)
		Expect(Landings).toBe(1)
	end)

	Test("a queue past SEQ_MAX answers Spent once every numbered op is heard", function()
		local Kept = Held()
		Kept.Next = Queue.SEQ_MAX
		Queue.Push(Kept, Op(1))
		Queue.Push(Kept, Op(2))
		local Call, Asked = Start(Kept)
		Machine.Step(Call, Asked[1].Id, Heard.Sent(LANDED))
		Expect(Machine.AnswerOf(Call)).toBe(Save.SAID.Spent)
		Expect(#Kept.Items).toBe(1)
	end)

	Test("a mark that blocks an op runs Unblock, and the next request carries the end it answers", function()
		local Kept = Held()
		Queue.Push(Kept, Op(5))
		local Name = Book.Drawn(9, 3)
		local Mark: Book.Escrow = {
			Form = "Escrow",
			Stamp = NOW,
			Attempt = 1,
			Clean = true,
			Decider = { Store = "Gold", Key = "d" },
			Field = 1,
			Amount = -1,
		}
		local Call, Asked = Start(Kept)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Whys = { [1] = "Blocked" }, Items = { [Name] = Mark } }))
		Expect(Asked[1].Ask.Kind).toBe("Run")
		local End: Requests.End = { Name = Name, Stamp = NOW, Attempt = 1, Outcome = "Abort" }
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done(End))
		local Ends = Request(Asked).Ends
		Expect(Ends and Ends[1].Name).toBe(Name)
	end)

	Test("an overdue pinned record in the way is verified and dropped, and the op is sent again", function()
		local Kept = Held()
		Queue.Push(Kept, Op(5))
		local Pinned: Book.Pinned = { Form = "Pinned", Stamp = NOW, Attempt = 1, Legs = { { Store = "Gold", Key = "a" } } }
		local Call, Asked = Start(Kept)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Whys = { [1] = "Overdue" }, Items = { [Book.Drawn(9, 3)] = Pinned } }))
		local Ask = Asked[1].Ask
		Expect(Ask.Kind == "Run" and Ask.Machine == Touch.Pinned).toBe(true)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done(true))
		Expect(Asked[1].Ask.Kind).toBe("Send")
	end)

	Test("writers on two servers help past different marks of one key, by their server numbers", function()
		local Mark: Book.Escrow = {
			Form = "Escrow",
			Stamp = NOW,
			Attempt = 1,
			Clean = true,
			Decider = { Store = "Gold", Key = "d" },
			Field = 1,
			Amount = -1,
		}
		local Picked: { string } = {}
		for _, Id in { 16, 17 } do
			local Kept = Queue.New({ Store = "Gold", Key = "42" }, Game.DEFAULT, Id, nil, NOW)
			Queue.Push(Kept, Op(5))
			local Call, Asked = Start(Kept)
			Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Whys = { [1] = "Blocked" }, Items = { x = Mark, y = Mark } }))
			local Ask = Asked[1].Ask
			table.insert(Picked, if Ask.Kind == "Run" then Ask.Context.Blocker.Name else "")
		end
		Expect(Picked[1] ~= "" and Picked[2] ~= "" and Picked[1] ~= Picked[2]).toBe(true)
	end)

	Test("a queue that does not know the key's incarnation reads it before it sends, and a failed read rests", function()
		local Kept = Queue.New({ Store = "Gold", Key = "42" }, Game.Build({ Erasable = true }), 16, nil, NOW)
		Queue.Push(Kept, Op(5))
		local Call, Asked = Start(Kept)
		Expect(Asked[1].Ask.Kind).toBe("Read")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Failed())
		Expect(Asked[1].Ask.Kind).toBe("Wait")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Expect(Asked[1].Ask.Kind).toBe("Read")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Expect(Request(Asked).Ops[1].Create).toBe(Book.Incarnation(16, 1))
	end)

	Test("a send that meets a seal an erase left over runs Unseal, then rests", function()
		local Kept = Held()
		Queue.Push(Kept, Op(5))
		local Seal: Book.Seal = { Name = "e", Stamp = NOW, Server = 9, Rt = NOW, Events = {}, Slots = {} }
		local Call, Asked = Start(Kept)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Why = "Missing", Whys = { [1] = "Missing" }, Seal = Seal, Left = true, Writes = 0 }))
		local Ask = Asked[1].Ask
		Expect(Ask.Kind == "Run" and Ask.Machine == Unseal.Machine).toBe(true)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done(true))
		Expect(Asked[1].Ask.Kind).toBe("Wait")
	end)

	Test("an Unblock that answers nothing rests before the next send", function()
		local Kept = Held()
		Queue.Push(Kept, Op(5))
		local Mark: Book.Exclusive = { Form = "Exclusive", Stamp = NOW, Attempt = 1, Clean = true, Decider = { Store = "Gold", Key = "d" } }
		local Call, Asked = Start(Kept)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Whys = { [1] = "Blocked" }, Items = { x = Mark, y = Mark } }))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Expect(Asked[1].Ask.Kind).toBe("Wait")
	end)
end)

return nil
