--!strict

--[=[

	Walk: The cases for Calls/Walk, stepped directly with the replies it hears.

	A step that runs a transaction is answered by hand. Refuse sets the verdict the part's refusal
	leaves on the transaction's context, with the part's state in the note. Swords is a final
	quantity on 4 parts.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Hash = require("../src/Encode/Hash")
local Heard = require("./Heard")
local Machine = require("../src/Machine/Machine")
local Parts = require("../src/Record/Parts")
local Tx = require("../src/Calls/Tx")
local Walk = require("../src/Calls/Walk")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local NOW = Heard.NOW
local PRINT = 7
local SWORDS: Parts.Declared = { Name = "Swords", Parts = 4, Mode = "Final", Stock = 8, Proceeds = {}, Print = PRINT, Place = "Gold$P:Swords:4" }
local BODY = Parts.TakeOp(PRINT, 1)

type Shape = { Free: number?, Sealed: boolean?, Closed: boolean? }
type Setup = { Only: number?, View: { [number]: Walk.View } }

local function Start(Name: string?, Home: number?, Fill: ((Setup: Setup) -> ())?, Body: Parts.Op?)
	local Setup: Setup = { View = {} }
	if Fill then
		Fill(Setup)
	end
	local Asked: Walk.Asked = {
		Declared = SWORDS,
		Body = Body or BODY,
		Legs = {},
		Server = 9,
		Home = Home or 0,
		Only = Setup.Only,
		Name = Name,
		Stamp = NOW,
		Print = 3,
		Names = { "d1", "d2", "d3" },
		View = Setup.View,
	}
	local Context = Walk.Context(Asked)
	local Call, Steps = Machine.Start(Walk.Machine, Context, NOW)
	return Call, Steps, Context
end

local function Asked(Each: Machine.Asked): (string, string)
	local Ask = Each.Ask
	if Ask.Kind == "Send" then
		local Fence = Ask.Request.Fence :: any
		return Ask.Ref.Key, `Fence {Fence.Name}`
	elseif Ask.Kind == "Run" then
		local Running = Ask.Context :: Tx.Context
		return Running.Legs[#Running.Legs].Ref.Key, `Run {Running.Use.Name}`
	end
	return "", Ask.Kind
end

local function Refuse(Context: Walk.Context, Shape: Shape)
	local State = { Print = PRINT, Opened = NOW, Free = Shape.Free or 0, Sold = 0, Sealed = Shape.Sealed, Closed = Shape.Closed, Holds = {} }
	local Running = Context.Tx :: Tx.Context
	Running.Verdict = Heard.Note({ Report = "Refused", State = State })
	return Heard.Done("Refused")
end

Describe("Walk", function()
	Test("a game name walks the parts from its hash onward under sub names, and a commit answers with its part", function()
		local First = Hash("order-1") % 4
		local Call, Steps, Context = Start("order-1")
		local Key, What = Asked(Steps[1])
		Expect(Key).toBe(Parts.Key("Swords", 4, First))
		Expect(What).toBe(`Run {Walk.Sub("order-1", First)}`)
		Steps = Machine.Step(Call, Steps[1].Id, Refuse(Context, { Free = 0 }))
		Key = Asked(Steps[1])
		Expect(Key).toBe(Parts.Key("Swords", 4, (First + 1) % 4))
		Machine.Step(Call, Steps[1].Id, Heard.Done(true))
		local Result = Machine.AnswerOf(Call) :: Walk.Result
		Expect(Result.Reply).toBe(true)
		Expect(Result.Part).toBe((First + 1) % 4)
	end)

	Test("a leg's refusal, Unresolved and Missing stop the walk, and no other part is tried", function()
		for _, Said in { "Refused", "Unresolved" } do
			local Call, Steps = Start("order-2")
			Steps = Machine.Step(Call, Steps[1].Id, Heard.Done(Said))
			Expect(#Steps).toBe(0)
			Expect((Machine.AnswerOf(Call) :: Walk.Result).Reply).toBe(Said)
		end
		local Call, Steps, Context = Start("order-2")
		local Running = Context.Tx :: Tx.Context
		Running.Verdict = Heard.Note({ Why = "Missing" })
		Steps = Machine.Step(Call, Steps[1].Id, Heard.Done("Unresolved"))
		Expect(#Steps).toBe(0)
		Expect((Machine.AnswerOf(Call) :: Walk.Result).Reply).toBe("Missing")
	end)

	Test("a game name fences a part its view shows dry, and goes on only when the fence reports fenced", function()
		local First = Hash("order-3") % 4
		local Call, Steps = Start("order-3", 0, function(Setup: Setup)
			Setup.View[First] = { Free = 0, Shut = true, At = NOW }
		end)
		local _, What = Asked(Steps[1])
		Expect(What).toBe(`Fence {Walk.Sub("order-3", First)}`)
		Steps = Machine.Step(Call, Steps[1].Id, Heard.Sent({ Report = "Fenced" }))
		local _, Then = Asked(Steps[1])
		Expect(Then).toBe(`Run {Walk.Sub("order-3", (First + 1) % 4)}`)
		Call, Steps = Start("order-3", 0, function(Setup: Setup)
			Setup.View[First] = { Free = 0, Shut = false, Refused = 1, At = NOW }
		end)
		Machine.Step(Call, Steps[1].Id, Heard.Sent({ Report = "Committed" }))
		local Result = Machine.AnswerOf(Call) :: Walk.Result
		Expect(Result.Reply).toBe(true)
		Expect(Result.Part).toBe(First)
	end)

	Test("a part that refused a count is dry for a walk of at least that count, and is tried by a smaller one", function()
		local Five = Parts.TakeOp(PRINT, 5)
		local Call, Steps, Context = Start(nil, 0, nil, Five)
		Machine.Step(Call, Steps[1].Id, Refuse(Context, { Free = 3 }))
		local Seen = Context.Asked.View[0]
		Expect(Seen.Refused).toBe(5)
		local First = Hash("order-6") % 4
		Call, Steps = Start("order-6", 0, function(Setup: Setup)
			Setup.View[First] = Seen
		end)
		local _, Smaller = Asked(Steps[1])
		Expect(Smaller).toBe(`Run {Walk.Sub("order-6", First)}`)
		Call, Steps = Start("order-6", 0, function(Setup: Setup)
			Setup.View[First] = Seen
		end, Five)
		local _, Same = Asked(Steps[1])
		Expect(Same).toBe(`Fence {Walk.Sub("order-6", First)}`)
		local Old: Walk.View = { Free = Seen.Free, Shut = false, Refused = 5, At = NOW - Parts.VIEW_AGE - 1 }
		Call, Steps = Start("order-6", 0, function(Setup: Setup)
			Setup.View[First] = Old
		end, Five)
		local _, Aged = Asked(Steps[1])
		Expect(Aged).toBe(`Run {Walk.Sub("order-6", First)}`)
	end)

	Test("SoldOut only when every part is known sealed or closed, else Short with the last reason", function()
		local Call, Steps, Context = Start("order-4")
		for Count = 1, 4 do
			Steps = Machine.Step(Call, Steps[1].Id, Refuse(Context, { Sealed = Count ~= 2, Closed = Count == 2 }))
		end
		Expect((Machine.AnswerOf(Call) :: Walk.Result).Reply).toBe("SoldOut")
		Call, Steps, Context = Start("order-4")
		for Count = 1, 4 do
			Steps = Machine.Step(Call, Steps[1].Id, Refuse(Context, { Sealed = Count ~= 4, Free = 0 }))
		end
		local Result = Machine.AnswerOf(Call) :: Walk.Result
		Expect(Result.Reply).toBe("Short")
		Expect(Result.Reason).toBe("Free")
	end)

	Test("a confirm a part refuses for want of its hold is Short reason Gone, and a shut part is still known shut", function()
		local Shapes: { Shape } = { { Free = 0 }, { Closed = true }, { Sealed = true } }
		for _, Shape in Shapes do
			local Confirm = Parts.ConfirmOp(PRINT, "h", 1)
			local Call, Steps, Context = Start(nil, 0, function(Setup: Setup)
				Setup.Only = 0
			end, Confirm)
			Machine.Step(Call, Steps[1].Id, Refuse(Context, Shape))
			local Result = Machine.AnswerOf(Call) :: Walk.Result
			Expect(Result.Reply).toBe("Short")
			Expect(Result.Reason).toBe("Gone")
			Expect(Context.Known[0]).toBe(if Shape.Free then nil else true)
		end
	end)

	Test("a hold refused on a part short of units and full of holds is Short for the units", function()
		local Hold = Parts.HoldOp(PRINT, "h", 2, NOW + 60)
		local Call, Steps, Context = Start(nil, 0, function(Setup: Setup)
			Setup.Only = 0
		end, Hold)
		local Holds = {}
		for Index = 1, Parts.HOLDS_MAX do
			table.insert(Holds, { Id = `x{Index}`, Count = 0, End = NOW + 60 })
		end
		local State = { Print = PRINT, Opened = NOW, Free = 1, Sold = 0, Holds = Holds }
		local Running = Context.Tx :: Tx.Context
		Running.Verdict = Heard.Note({ Report = "Refused", State = State })
		Machine.Step(Call, Steps[1].Id, Heard.Done("Refused"))
		Expect((Machine.AnswerOf(Call) :: Walk.Result).Reason).toBe("Free")
	end)

	Test("a drawn walk answers SoldOut from memory when the view shows every part shut, and Busy when all are short", function()
		local Call, Steps = Start(nil, 0, function(Setup: Setup)
			for Index = 0, 3 do
				Setup.View[Index] = { Free = 0, Shut = true, At = NOW }
			end
		end)
		Expect(#Steps).toBe(0)
		Expect((Machine.AnswerOf(Call) :: Walk.Result).Reply).toBe("SoldOut")
		Call, Steps = Start(nil, 0, function(Setup: Setup)
			for Index = 0, 3 do
				Setup.View[Index] = { Free = 0, Shut = Index == 0, Refused = 1, At = NOW }
			end
		end)
		Expect(#Steps).toBe(0)
		Expect((Machine.AnswerOf(Call) :: Walk.Result).Reply).toBe("Busy")
		Call, Steps = Start("order-5", 0, function(Setup: Setup)
			for Index = 0, 3 do
				Setup.View[Index] = { Free = 0, Shut = true, At = NOW }
			end
		end)
		Expect(#Steps).toBe(1)
		local _, What = Asked(Steps[1])
		Expect(What:sub(1, 5)).toBe("Fence")
	end)

	Test("drawn names try the home part, then the most free parts the view shows, at most PROBES of them", function()
		local Call, Steps, Context = Start(nil, 2, function(Setup: Setup)
			Setup.View[0] = { Free = 5, Shut = false, At = NOW }
			Setup.View[1] = { Free = 9, Shut = true, At = NOW }
			Setup.View[3] = { Free = 7, Shut = false, At = NOW }
		end)
		local Keys: { string } = {}
		local Names: { string } = {}
		for _ = 1, Parts.PROBES do
			local Key, What = Asked(Steps[1])
			table.insert(Keys, Key)
			table.insert(Names, What)
			Steps = Machine.Step(Call, Steps[1].Id, Refuse(Context, { Free = 0 }))
		end
		Expect(#Steps).toBe(0)
		Expect(table.concat(Keys, " ")).toBe(`{Parts.Key("Swords", 4, 2)} {Parts.Key("Swords", 4, 3)} {Parts.Key("Swords", 4, 0)}`)
		Expect(table.concat(Names, " ")).toBe("Run d1 Run d2 Run d3")
		Expect((Machine.AnswerOf(Call) :: Walk.Result).Reply).toBe("Short")
		Call, Steps, Context = Start(nil, 1)
		for _ = 1, Parts.PROBES do
			Steps = Machine.Step(Call, Steps[1].Id, Refuse(Context, { Free = 0 }))
		end
		Expect(#Steps).toBe(0)
	end)
end)

return nil
