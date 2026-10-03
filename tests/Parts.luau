--!strict

--[=[

	Parts: The cases for Record/Parts, with every part op run through the real Step.

	Each op is a commit with no other legs on the part, as the walk and the quantity calls send it.
	Swords is a final quantity of 3 units on 2 parts, and Pot an open one.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Requests = require("../src/Record/Requests")
local Testing = require("./Testing")
local Game = require("./Gold")
local Heard = require("./Heard")
local Key = require("../src/Record/Key")
local Limits = require("../src/Core/Constants/Limits")
local Parts = require("../src/Record/Parts")
local Step = require("../src/Record/Step")
local Types = require("../src/Record/Types")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local NOW = Heard.NOW
local PRINT = 7

local SWORDS: Parts.Declared = { Name = "Swords", Parts = 2, Mode = "Final", Stock = 3, Proceeds = {}, Print = PRINT, Place = "Gold$P:Swords:2" }
local POT: Parts.Declared = { Name = "Pot", Parts = 1, Mode = "Open", Stock = 0, Proceeds = {}, Print = PRINT, Place = "Gold$P:Pot:1" }

local Counter = 0

local function Send(Current: unknown, Body: Parts.Op, Using: Types.Build, At: number?, Name: string?): (unknown, Types.Note)
	Counter += 1
	local Clock = At or NOW
	local Commit: Requests.Commit = { Name = Name or `op{Counter}`, Stamp = Clock, Attempt = 1, Print = 1, Legs = {}, Leg = { Body = Body } }
	local Request: Requests.Request = { Writer = 0, Ack = 0, MustExist = Body.Kind ~= Parts.OP.Open, Ops = {}, Commit = Commit }
	local Note = Step(Current, Request, Clock, Using)
	return Note.Stored or Current, Note
end

local function Part(Value: unknown): Parts.Part
	return (Key.Read(Value) :: Key.Found).State :: any
end

local function Opened(Declared: Parts.Declared, Share: number): (unknown, Types.Build)
	local Using = Parts.Build(Game.DEFAULT, Declared)
	local Value = Send(nil, Parts.OpenOp(Share, NOW), Using)
	return Value, Using
end

Describe("Parts", function()
	Test("each part's share of the stock adds up to the stock", function()
		local Sum = 0
		for Index = 0, 6 do
			Sum += Parts.Share(100, 7, Index)
		end
		Expect(Sum).toBe(100)
		Expect(Parts.Share(3, 2, 0)).toBe(1)
		Expect(Parts.Share(3, 2, 1)).toBe(2)
		Expect(Parts.Key("Swords", 2, 1)).toBe("$P:Swords:2:1")
	end)

	Test("only open makes a part, with its share, and an open on a part that exists changes nothing", function()
		local Using = Parts.Build(Game.DEFAULT, SWORDS)
		local _, Missing = Send(nil, Parts.TakeOp(PRINT, 1), Using)
		Expect(Missing.Why).toBe("Missing")
		local Value = Opened(SWORDS, 2)
		Expect(Part(Value).Free).toBe(2)
		Expect(Part(Value).Opened).toBe(NOW)
		local Again = Send(Value, Parts.OpenOp(9, NOW + 5), Using)
		Expect(Part(Again).Free).toBe(2)
	end)

	Test("a take moves free units to sold, is refused short, and seals the part that sells its last unit", function()
		local Value, Using = Opened(SWORDS, 2)
		Value = Send(Value, Parts.TakeOp(PRINT, 1), Using)
		Expect(Part(Value).Free).toBe(1)
		Expect(Part(Value).Sold).toBe(1)
		local Short, Note = Send(Value, Parts.TakeOp(PRINT, 2), Using)
		Expect(Note.Report).toBe("Refused")
		Expect(Parts.Refusal(SWORDS, Part(Short), Parts.TakeOp(PRINT, 2))).toBe("Free")
		Value = Send(Short, Parts.TakeOp(PRINT, 1), Using)
		Expect(Part(Value).Sealed).toBe(true)
		local Sealed, Refused = Send(Value, Parts.CreditOp(PRINT, 1), Using)
		Expect(Refused.Report).toBe("Refused")
		Expect(Parts.Refusal(SWORDS, Part(Sealed), Parts.CreditOp(PRINT, 1))).toBe("Sealed")
	end)

	Test("a part never seals while a hold stands, and an open part never seals", function()
		local Value, Using = Opened(SWORDS, 2)
		Value = Send(Value, Parts.HoldOp(PRINT, "h", 1, NOW + 60), Using)
		Value = Send(Value, Parts.TakeOp(PRINT, 1), Using)
		Expect(Part(Value).Free).toBe(0)
		Expect(Part(Value).Sealed).toBeNil()
		local _, Note = Send(Value, Parts.TakeOp(PRINT, 1), Using)
		Expect(Parts.Refusal(SWORDS, Note.State, Parts.TakeOp(PRINT, 1))).toBe("Held")
		Value = Send(Value, Parts.ConfirmOp(PRINT, "h", 1), Using)
		Expect(Part(Value).Sold).toBe(2)
		Expect(Part(Value).Sealed).toBe(true)
		local Pot, PotUsing = Opened(POT, 1)
		Pot = Send(Pot, Parts.TakeOp(PRINT, 1), PotUsing)
		Expect(Part(Pot).Free).toBe(0)
		Expect(Part(Pot).Sealed).toBeNil()
		Pot = Send(Pot, Parts.CreditOp(PRINT, 4), PotUsing)
		Expect(Part(Pot).Free).toBe(4)
	end)

	Test("a hold ends once: by confirm, by release, or by expiry at a later write, whichever lands first", function()
		local Value, Using = Opened(SWORDS, 2)
		Value = Send(Value, Parts.HoldOp(PRINT, "h", 2, NOW + 10), Using)
		Expect(Part(Value).Free).toBe(0)
		local Later = NOW + 10 + Parts.HOLD_SLACK + 1
		local Expired = Send(Value, Parts.ReleaseOp(PRINT, "other"), Using, Later)
		Expect(Part(Expired).Free).toBe(2)
		Expect(#Part(Expired).Holds).toBe(0)
		local Gone, Note = Send(Expired, Parts.ConfirmOp(PRINT, "h", 3), Using, Later)
		Expect(Note.Report).toBe("Refused")
		Expect(Parts.Refusal(SWORDS, Part(Gone), Parts.ConfirmOp(PRINT, "h", 3))).toBe("Gone")
		local Fallback = Send(Expired, Parts.ConfirmOp(PRINT, "h", 2), Using, Later)
		Expect(Part(Fallback).Sold).toBe(2)
		local Released = Send(Value, Parts.ReleaseOp(PRINT, "h"), Using)
		Expect(Part(Released).Free).toBe(2)
		local Again, Wrote = Send(Released, Parts.ReleaseOp(PRINT, "h"), Using)
		Expect(Wrote.Report).toBe("Committed")
		Expect(Part(Again).Free).toBe(2)
	end)

	Test("a hold ending far past the longest hold expires at once, and a part keeps at most HOLDS_MAX holds", function()
		local Value, Using = Opened(SWORDS, 2)
		Value = Send(Value, Parts.HoldOp(PRINT, "far", 1, NOW + Parts.HOLD_MAX + Parts.HOLD_SLACK + 1), Using)
		local Next = Send(Value, Parts.ReleaseOp(PRINT, "none"), Using)
		Expect(Part(Next).Free).toBe(2)
		local Full = Part(Next) :: any
		Full.Holds = table.create(Parts.HOLDS_MAX, { Id = "x", Count = 0, End = NOW + 60 })
		Expect(Parts.Refusal(SWORDS, Full, Parts.HoldOp(PRINT, "y", 1, NOW + 60))).toBe("Holds")
	end)

	Test("a part opened under another declaration refuses every op, and Close keeps a closed part shut", function()
		local Value, Using = Opened(SWORDS, 2)
		local Other = Parts.TakeOp(PRINT + 1, 1)
		local _, Note = Send(Value, Other, Using)
		Expect(Note.Report).toBe("Refused")
		Expect(Parts.Refusal(SWORDS, Note.State, Other)).toBe("Invalid")
		Value = Send(Value, Parts.CloseOp(PRINT), Using)
		Expect(Part(Value).Closed).toBe(true)
		Expect(Parts.Empty(Part(Value), SWORDS)).toBe(false)
		local Shut, Refused = Send(Value, Parts.TakeOp(PRINT, 1), Using)
		Expect(Refused.Report).toBe("Refused")
		Expect(Parts.Refusal(SWORDS, Part(Shut), Parts.TakeOp(PRINT, 1))).toBe("Closed")
	end)

	Test("serials are drawn from the returned ones first, smallest first, a take's first serial is its decider value, and a write that issues none has none", function()
		local Serial: Parts.Declared = { Name = "Badges", Parts = 2, Mode = "Final", Stock = 6, First = 100, Proceeds = {}, Print = PRINT, Place = "Gold$P:Badges:2" }
		Expect(Parts.From(Serial, 1)).toBe(103)
		local Using = Parts.Build(Game.DEFAULT, Serial)
		local Value = Send(nil, Parts.OpenOp(3, NOW, 103), Using)
		Value = Send(Value, Parts.HoldOp(PRINT, "h", 1, NOW + 10), Using)
		Expect((Part(Value).Holds[1].Serials :: { number })[1]).toBe(103)
		local Took, Note = Send(Value, Parts.TakeOp(PRINT, 1), Using)
		Expect(Note.Value).toBe(104)
		local Released: Types.Note
		Took, Released = Send(Took, Parts.ReleaseOp(PRINT, "h"), Using)
		Expect(Released.Value).toBeNil()
		Expect((Part(Took).Returned :: { number })[1]).toBe(103)
		local Again, Drawn = Send(Took, Parts.TakeOp(PRINT, 1), Using)
		Expect(Drawn.Value).toBe(103)
		Again = Send(Again, Parts.HoldOp(PRINT, "g", 1, NOW + 10), Using)
		local Later = NOW + 10 + Parts.HOLD_SLACK + 1
		local Back, Fallback = Send(Again, Parts.ConfirmOp(PRINT, "g", 1), Using, Later)
		Expect(Fallback.Value).toBe(105)
		Expect(Part(Back).Sealed).toBe(true)
		local _, Credit = Send(Took, Parts.CreditOp(PRINT, 1), Using)
		Expect(Credit.Report).toBe("Refused")
	end)

	Test("a take pays its price into the proceeds, and a part holding proceeds is not empty", function()
		local Shop: Parts.Declared = { Name = "Shop", Parts = 1, Mode = "Final", Stock = 2, Proceeds = { "Coins" }, Print = PRINT, Place = "Gold$P:Shop:1" }
		local Value, Using = Opened(Shop, 2)
		Expect((Part(Value) :: any).Coins).toBe(0)
		Value = Send(Value, Parts.TakeOp(PRINT, 2, { Coins = 5 }), Using)
		Expect((Part(Value) :: any).Coins).toBe(5)
		Expect(Part(Value).Sealed).toBe(true)
		Expect(Parts.Empty(Part(Value), Shop)).toBe(false)
		Expect(table.find(Using.Money, "Coins")).toBe(2)
	end)

	Test("a delta moves units out of a closed or sealed part, and is refused moving any in", function()
		local Value, Using = Opened(SWORDS, 1)
		local function Shift(Current: unknown, Amount: number, Name: string): Types.Note
			local Commit: Requests.Commit = { Name = Name, Stamp = NOW, Attempt = 1, Print = 1, Legs = {}, Leg = { Field = 1, Amount = Amount } }
			return Step(Current, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Commit = Commit }, NOW, Using)
		end
		local Moved = Shift(Value, 2, "in")
		Expect(Moved.Report).toBe("Committed")
		Expect(Part(Moved.Stored).Free).toBe(3)
		local Closed = Send(Moved.Stored, Parts.CloseOp(PRINT), Using)
		Expect(Shift(Closed, 1, "in2").Report).toBe("Refused")
		local Tent: Requests.Tent = { Name = "t", Stamp = NOW, Attempt = 1, Print = 1, Decider = { Store = "Gold", Key = "d" }, Leg = { Field = 1, Amount = 1 } }
		Expect(Step(Closed, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Tent = Tent }, NOW, Using).Report).toBe("Refused")
		local Out = Shift(Closed, -3, "out")
		Expect(Out.Report).toBe("Committed")
		Expect(Part(Out.Stored).Free).toBe(0)
	end)

	Test("a gather plans the fewest parts, most free first, within its room, or nothing when they fall short", function()
		local Plan = Parts.Plan({ [0] = 2, [1] = 9, [2] = 4 }, 4, 12, 3) :: { { Index: number, Count: number } }
		Expect(#Plan).toBe(2)
		Expect(Plan[1].Index).toBe(1)
		Expect(Plan[1].Count).toBe(9)
		Expect(Plan[2].Index).toBe(2)
		Expect(Plan[2].Count).toBe(3)
		Expect(Parts.Plan({ [0] = 2, [1] = 9, [2] = 4 }, 4, 14, 2)).toBeNil()
		Expect(Parts.Plan({ [0] = 2 }, 4, 3, 3)).toBeNil()
	end)

	Test("a credit that takes a part to the money limit is refused by the guard every build runs, with no reason of the part's", function()
		local Pot, Using = Opened(POT, 1)
		Pot = Send(Pot, Parts.CreditOp(PRINT, Limits.MONEY_LIMIT - 2), Using)
		Expect(Part(Pot).Free).toBe(Limits.MONEY_LIMIT - 1)
		local _, Note = Send(Pot, Parts.CreditOp(PRINT, 1), Using)
		Expect(Note.Report).toBe("Refused")
		Expect(Parts.Refusal(POT, Part(Pot), Parts.CreditOp(PRINT, 1))).toBeNil()
	end)

	Test("a retry under the same name is the same decision and takes nothing more", function()
		local Value, Using = Opened(SWORDS, 2)
		Value = Send(Value, Parts.TakeOp(PRINT, 1), Using, NOW, "x")
		local Again, Note = Send(Value, Parts.TakeOp(PRINT, 1), Using, NOW, "x")
		Expect(Note.Report).toBe("Committed")
		Expect(Part(Again).Sold).toBe(1)
	end)
end)

return nil
