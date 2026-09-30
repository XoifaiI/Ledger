--!strict

--[=[

	Session: The cases for Store/Session, with the key's Save machine stepped by hand.

	The game is tests/Gold. A push is landed by running its transform on the key as the datastore
	would, and handing the machine the reply.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Answer = require("../src/Core/Answer")
local Game = require("./Gold")
local Asks = require("../src/Machine/Asks")
local Machine = require("../src/Machine/Machine")
local Queue = require("../src/Record/Queue")
local Runtime = require("../src/Store/Runtime")
local Save = require("../src/Calls/Save")
local Session = require("../src/Store/Session")
local Step = require("../src/Record/Step")
local Types = require("../src/Record/Types")
local View = require("../src/Record/View")
local Windows = require("../src/Core/Constants/Windows")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local NOW = Game.NOW

local function Held(Key: string): Queue.Queue
	return Queue.New({ Store = "Gold", Key = Key }, Game.DEFAULT, 16, nil, NOW)
end

local function Open(Key: string?): Session.Session
	return Session.New(Held(Key or "42"), nil, false, NOW)
end

Describe("Session", function()
	Test("an op is judged on the view: a refused one is not queued, and one that takes is queued and laid on it", function()
		local Player = Open()
		Expect(Player:Apply("Add", { Add = -1 })).toBe(Answer.Refused)
		Expect(Player:Apply("Add", { Add = 0, Tag = print })).toBe(Answer.Invalid)
		Expect(#Player.Queue.Items).toBe(0)
		Expect(Player:Apply("Add", { Add = 5 })).toBe(true)
		Expect(Player.Queue.Items[1].Asked.View).toBe(0)
		Expect(Player.State.Gold).toBe(5)
		Player:Close()
		Expect(Player:Apply("Add", { Add = 1 })).toBe(Answer.Closed)
	end)

	Test("a landed push is adopted with the ops still queued laid on top, and each op's fate is heard once", function()
		local Player = Open("45")
		local Heard: { any } = {}
		Player.Fates:Subscribe(function(Each: Session.Fate)
			table.insert(Heard, Each.Reply)
		end)
		Player:Apply("Add", { Add = 5 })
		local Kept = Player.Queue
		local function Land(Note: Types.Note)
			Runtime.Landed(Kept):Push(Note)
		end
		local Call, Asked = Machine.Start(Save.Machine, Save.Context(Kept, Land), NOW)
		Player:Apply("Add", { Add = 2 })
		local Ask = Asked[1].Ask
		local Note = Step(nil, if Ask.Kind == "Send" then Ask.Request else error("not a send"), NOW, Game.DEFAULT)
		Machine.Step(Call, Asked[1].Id, Asks.Noted(Note, NOW, true))
		Expect(Player.Writes).toBe(1)
		Expect(Player.State.Gold).toBe(7)
		Expect(Player.Shown:Allows(Player.Mark, 0)).toBe(false)
		Expect(#Heard).toBe(1)
		Expect(Heard[1]).toBe(true)
		Player:Adopt({ State = { Gold = 99 }, Writes = 1, Cuts = 0, Horizon = 0, Work = {} })
		Expect(Player.State.Gold).toBe(7)
	end)

	Test("an op a mark on the view could decide answers Busy, and one it cannot is queued", function()
		local function Viewed(Leg: Types.Leg): (View.View, unknown)
			local Op: Types.Op = { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = 100 } }
			local Key = Step(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = { Op } }, NOW, Game.DEFAULT).Stored
			local Tent: Types.Tent = { Name = "t", Stamp = NOW, Attempt = 1, Print = 1, Decider = { Store = "Gold", Key = "d" }, Leg = Leg }
			Key = Step(Key, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Tent = Tent }, NOW, Game.DEFAULT).Stored
			return View.Read(Key, Game.DEFAULT) :: View.View, Key
		end
		local Marked, Key = Viewed({ Field = 1, Amount = -60 })
		local Player = Session.New(Held("46"), Marked, false, NOW)
		Expect(Player:Apply("Add", { Add = -30 })).toBe(true)
		Expect(Player:Apply("Add", { Add = -20 })).toBe(Answer.Busy)
		local End: Types.End = { Name = "t", Stamp = NOW, Attempt = 1, Print = 1, Outcome = "Abort" }
		local Cleared = Step(Key, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Ends = { End } }, NOW, Game.DEFAULT).Stored
		Player:Adopt(View.Read(Cleared, Game.DEFAULT) :: View.View)
		Expect(Player:Apply("Add", { Add = -20 })).toBe(true)
		local Exclusive = Session.New(Held("47"), (Viewed({ Body = { Add = 1 } })), false, NOW)
		Expect(Exclusive:Apply("Add", { Add = 1 })).toBe(Answer.Busy)
	end)

	Test("a push is due after SAVE while ops wait, and an idle read after IDLE when none do", function()
		local Player = Open()
		Expect(Player:Due(NOW + Windows.IDLE)).toBe(Session.DUE.Read)
		Player:Read(NOW + Windows.IDLE)
		Player:Apply("Add", { Add = 1 })
		Expect(Player:Due(NOW + Windows.SAVE - 1)).toBeNil()
		Expect(Player:Due(NOW + Windows.SAVE)).toBe(Session.DUE.Push)
	end)
end)

return nil
