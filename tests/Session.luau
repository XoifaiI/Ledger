--!strict

--[=[

	Session: The cases for Server/Session, with the key's Sender stepped by hand.

	The game is tests/Gold. A push is landed by running its transform on the key as the datastore
	would, and handing the machine the reply.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Answer = require("../src/Core/Answer")
local Effect = require("../src/Server/Effect")
local Game = require("./Gold")
local Machine = require("../src/Core/Machine")
local Sender = require("../src/Server/Sender")
local Session = require("../src/Server/Session")
local Windows = require("../src/Core/Constants/Windows")
local Writer = require("../src/Server/Writer")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local NOW = Game.NOW

local function Open(): Session.Session
	return Session.New(Sender.New(nil :: any, "42", Game.DEFAULT, 16), nil, false, NOW)
end

local function Land(Sent: Effect.Effect, Current: unknown): unknown
	return if Sent.Kind == Effect.Kind.Update then Sent.Transform(Current, nil) else nil
end

Describe("Session", function()
	Test("an op is judged on the view: a refused one is not queued, and one that takes is queued and laid on it", function()
		local Player = Open()
		Expect(Player:Apply("Add", { Add = -1 })).toBe(Answer.Refused)
		Expect(Player:Apply("Add", { Add = 0, Tag = print })).toBe(Answer.Invalid)
		Expect(#Player.Key.Writer.Items).toBe(0)
		Expect(Player:Apply("Add", { Add = 5 })).toBe(true)
		Expect(Player.Key.Writer.Items[1].Asked.View).toBe(0)
		Expect(Player.State.Gold).toBe(5)
		Player:Close()
		Expect(Player:Apply("Add", { Add = 1 })).toBe(Answer.Closed)
	end)

	Test("a landed push is adopted with the ops still queued laid on top, and each op's fate is heard once", function()
		local Player = Open()
		local Heard: { any } = {}
		Player.Fates:Subscribe(function(Each: Writer.Heard)
			table.insert(Heard, Each.Reply)
		end)
		Player:Apply("Add", { Add = 5 })
		local Call, Effects, First = Machine.Start(Sender.Sending, Player.Key)
		Player:Apply("Add", { Add = 2 })
		Machine.Step(Call, First, true, Land(Effects[1], nil), nil, true)
		Expect(Player.Writes).toBe(1)
		Expect(Player.State.Gold).toBe(7)
		Expect(#Heard).toBe(1)
		Expect(Heard[1]).toBe(true)
		Player:Adopt({ State = { Gold = 99 }, Writes = 1, Cuts = 0, Horizon = 0 })
		Expect(Player.State.Gold).toBe(7)
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
