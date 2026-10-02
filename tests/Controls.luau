--!strict

--[=[

	Controls: Cases for rules of the chosen designs that no other file made fail when the rule was
	taken out.

	Each case names its rule, and the control of LedgerSim/spec/protocols it stands for where there
	is one. The game is tests/Gold. Land runs one request and keeps what it wrote, as the datastore
	would. The machine cases step a machine with replies from tests/Heard.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Requests = require("../src/Record/Requests")
local Testing = require("./Testing")
local Answer = require("../src/Core/Answer")
local Book = require("../src/Record/Book")
local Game = require("./Gold")
local Heard = require("./Heard")
local Key = require("../src/Record/Key")
local Machine = require("../src/Machine/Machine")
local Parts = require("../src/Record/Parts")
local Queue = require("../src/Record/Queue")
local Step = require("../src/Record/Step")
local Tx = require("../src/Calls/Tx")
local Types = require("../src/Record/Types")
local Walk = require("../src/Calls/Walk")
local Windows = require("../src/Core/Constants/Windows")

local Describe, Test, Expect, Similar = Testing.Describe, Testing.Test, Testing.Expect, Testing.Similar

type Note = Types.Note
type Op = Requests.Op
type Request = Requests.Request

local NOW = Game.NOW
local DEFAULT = Game.DEFAULT
local Build, Gold, Record = Game.Build, Game.Gold, Game.Record
local Fate = Book.Fate
local RESET = Book.Cause.Reset
local GOLD = 1
local FATES_MAX = 64
local DECIDER: Book.Ref = { Store = "Gold", Key = "d" }
local X = Book.Drawn(7, 1)
local Y = Book.Drawn(7, 2)

local function Land(Current: unknown, Asked: Request, Clock: number?, Using: Types.Build?): (unknown, Note, boolean)
	local Note = Step(Current, Asked, Clock or NOW, Using or DEFAULT)
	local Value = Note.Stored
	return if Value then Value else Current, Note, Value ~= nil
end

local function Mint(Seq: number, Add: number, Stamp: number?): Op
	return { Form = "Minted", Seq = Seq, Stamp = Stamp or NOW, Kind = 0, Body = { Add = Add } }
end

local function Ops(List: { Op }, Ack: number, Writer: number): Request
	return { Writer = Writer, Ack = Ack, MustExist = false, Ops = List }
end

local function Seed(Amount: number, Using: Types.Build?): unknown
	return (Land(nil, Ops({ Mint(1, Amount) }, 0, 1), NOW, Using))
end

local function Tent(Name: string, Leg: Requests.Leg, Stamp: number?): Request
	return Requests.Tent({ Name = Name, Stamp = Stamp or NOW, Attempt = 1, Decider = DECIDER, Leg = Leg }, true)
end

local function Commit(Name: string, Leg: Requests.Leg, Stamp: number?): Request
	return Requests.Commit({ Name = Name, Stamp = Stamp or NOW, Attempt = 1, Legs = { { Store = "Gold", Key = "a" } }, Leg = Leg }, true)
end

local function Cut(Name: string, Stamp: number?): Request
	return Requests.Cut({ Name = Name, Stamp = Stamp or NOW, Kind = RESET, Print = 7, Helper = false, Server = 16 })
end

local function Count(Items: { [string]: Book.Work }?): number
	local Total = 0
	for _ in Items or {} do
		Total += 1
	end
	return Total
end

Describe("Controls of the record", function()
	Test("a cut name that ages out raises the cut horizon, so its retry is forgotten and cuts nothing (CutCtlKeep)", function()
		local Key = Land(Seed(5), Cut("c1"))
		Expect(Record(Key).Cut.c1).never.toBeNil()
		local Later = NOW + Windows.CUT
		Key = Land(Key, Ops({ Mint(1, 3, Later) }, 0, 2), Later)
		Expect(Record(Key).Cut.c1).toBeNil()
		Expect(Record(Key).CutHorizon).toBe(NOW)
		local After, Note = Land(Key, Cut("c1"), Later)
		Expect(Note.Report).toBe("Forgotten")
		Expect(Gold(After)).toBe(3)
	end)

	Test("a cut name the room trims raises the cut horizon, so its retry is forgotten and cuts nothing (CutCtlKeep)", function()
		local Tight = Build({ CutNames = 1 })
		local Key = Land(Seed(5, Tight), Cut("c1"), NOW, Tight)
		Key = Land(Key, Ops({ Mint(1, 3) }, 0, 2), NOW, Tight)
		Key = Land(Key, Cut("c2", NOW + 1), NOW + 1, Tight)
		Expect(Record(Key).Cut.c1).toBeNil()
		Expect(Record(Key).Cut.c2).never.toBeNil()
		Expect(Record(Key).CutHorizon).toBe(NOW)
		Key = Land(Key, Ops({ Mint(2, 4, NOW + 1) }, 1, 2), NOW + 1, Tight)
		local After, Note = Land(Key, Cut("c1"), NOW + 1, Tight)
		Expect(Note.Report).toBe("Forgotten")
		Expect(Gold(After)).toBe(4)
	end)

	Test("a minted op under the horizon is judged when its writer has an entry, and forgotten when it has none", function()
		local Key = Land(nil, Ops({ Mint(1, 1) }, 0, 2))
		Key = Land(Key, Ops({ Mint(1, 1) }, 0, 1))
		local Later = NOW + Windows.MINTED
		Key = Land(Key, Ops({ Mint(2, 1, Later) }, 1, 1), Later)
		Expect(Record(Key).Horizon).toBe(NOW)
		local After, Note = Land(Key, Ops({ Mint(3, 1, NOW - 5) }, 2, 1), Later)
		Expect(Note.Fates).toBe(Similar({ Fate.Took }))
		Expect(Gold(After)).toBe(4)
		local _, Other = Land(Key, Ops({ Mint(1, 1, NOW - 5) }, 0, 3), Later)
		Expect(Other.Whys).toBe(Similar({ "Forgotten" }))
	end)

	Test("a run decides no op past its 64th fate that is not took", function()
		local Debits: { Op } = {}
		for Seq = 1, FATES_MAX + 2 do
			Debits[Seq] = Mint(Seq, -1)
		end
		local Key, Note = Land(Seed(0), Ops(Debits, 0, 2))
		Expect(#Note.Decided).toBe(FATES_MAX)
		Expect(Note.Fates[FATES_MAX]).toBe(Fate.Refused)
		Expect(Note.Fates[FATES_MAX + 1]).toBeNil()
		Expect(Note.Whys[FATES_MAX + 1]).toBe("Undecided")
		Expect(Record(Key).Writers[2].Lo).toBe(FATES_MAX)
	end)

	Test("a no that only a clean op may take answers Unresolved for an op a run decided (RecCtlCleanRule)", function()
		for _, Reason in { "Behind", "NoRoom", "Missing" } do
			for _, Dirty in { false, true } do
				local Kept = Queue.New({ Store = "Gold", Key = "42" }, DEFAULT, 16, nil, NOW)
				Queue.Push(Kept, { Form = "Timed", Kind = 1, Name = "n", Print = 7, Stamp = NOW, MustExist = false, Body = { Add = 1 } })
				local Request = assert(Queue.Build(Kept, NOW))
				local Ran: { [number]: true } = if Dirty then { [1] = true } else {}
				local Said = Queue.Learn(Kept, Request, Heard.Note({ Whys = { Reason }, Stored = false }), Ran, NOW)
				Expect(Said[1].Reply).toBe(if Dirty then Answer.Unresolved else Reason)
			end
		end
	end)

	Test("a queued hopeful op is turned away for an older cut count only by a write that landed (RecCtlTurnOk)", function()
		local Kept = Queue.New({ Store = "Gold", Key = "42" }, DEFAULT, 16, nil, NOW)
		Queue.Push(Kept, { Form = "Hopeful", Kind = 0, View = 0, MustExist = false, Body = { Add = 1 } })
		local Request = assert(Queue.Build(Kept, NOW))
		local Cancelled = Heard.Note({ Cuts = 1 })
		Cancelled.Stored = nil
		Expect(#Queue.Learn(Kept, Request, Cancelled, {}, NOW)).toBe(0)
		Request = assert(Queue.Build(Kept, NOW))
		local Landed = Heard.Note({ Cuts = 1, Stored = { s = {}, b = "" } })
		local Said = Queue.Learn(Kept, Request, Landed, {}, NOW)
		Expect(Said[1].Reply).toBe(Answer.Refused)
		Expect(Said[1].Code).toBe(Fate.Turned)
	end)
end)

Describe("Controls of the transaction", function()
	local function Newer(): Types.Build
		return Build({ Level = 1, Migrations = {
			function(State: any): unknown
				State.Gold += 100
				return State
			end,
		} })
	end

	Test("a write that would run a migration is blocked by every mark, for an op and for a commit (BuildCtlMigBlock)", function()
		local Key = Land(Seed(50), Tent(Y, { Field = GOLD, Amount = -10 }))
		local After, Note, Wrote = Land(Key, Ops({ Mint(1, 1) }, 0, 2), NOW, Newer())
		Expect(Note.Whys).toBe(Similar({ "Blocked" }))
		Expect(Count(Note.Items)).toBe(1)
		Expect(Wrote).toBe(false)
		Expect(Record(After).Level).toBe(0)
		local Still, Decided, Landed = Land(Key, Commit(X, { Body = { Add = 1 } }), NOW, Newer())
		Expect(Decided.Report).toBe("Blocked")
		Expect(Landed).toBe(false)
		Expect(Gold(Still)).toBe(50)
	end)

	Test("a key past the build's floor answers a Tent and a Commit Behind, and neither writes (BuildCtlFloor)", function()
		local Ahead = Build({ Floor = 3 })
		local Key = Seed(50, Ahead)
		local _, Tented, Wrote = Land(Key, Tent(X, { Field = GOLD, Amount = -10 }))
		Expect(Tented.Report).toBe("Behind")
		Expect(Wrote).toBe(false)
		local After, Decided, Landed = Land(Key, Commit(X, { Field = GOLD, Amount = 10 }))
		Expect(Decided.Report).toBe("Behind")
		Expect(Landed).toBe(false)
		Expect(Gold(After)).toBe(50)
	end)

	Test("a Tent and a Commit of a name the key has forgotten are forgotten and write nothing (CtlHorizonRaise)", function()
		local Named: Op = { Form = "Timed", Seq = 1, Stamp = NOW, Kind = 1, Name = "old", Print = 7, Body = { Add = 1 } }
		local Key = Land(Seed(50), Ops({ Named }, 0, 2))
		local Later = NOW + Windows.MINTED
		Key = Land(Key, Ops({ Mint(1, 1, Later) }, 0, 3), Later)
		Expect(Record(Key).Horizon).toBe(NOW)
		local _, Tented, Wrote = Land(Key, Tent(X, { Field = GOLD, Amount = -10 }), Later)
		Expect(Tented.Report).toBe("Forgotten")
		Expect(Wrote).toBe(false)
		local After, Decided, Landed = Land(Key, Commit(X, { Field = GOLD, Amount = 10 }), Later)
		Expect(Decided.Report).toBe("Forgotten")
		Expect(Landed).toBe(false)
		Expect(Gold(After)).toBe(52)
	end)

	Test("a game op leg's Tent is blocked by any mark on its key, and lists it", function()
		local Key = Land(Seed(50), Tent(Y, { Field = GOLD, Amount = -10 }))
		local After, Note, Wrote = Land(Key, Tent(X, { Body = { Add = 1 } }))
		Expect(Note.Report).toBe("Blocked")
		Expect(Count(Note.Items)).toBe(1)
		Expect(Wrote).toBe(false)
		Expect(Record(After).Work[X]).toBeNil()
	end)

	Test("while a mark is CEILING old a fence of another name still lands, and an op does not (Fence subject to Overdue)", function()
		local Key = Land(Seed(50), Tent(Y, { Field = GOLD, Amount = -10 }))
		local Later = NOW + Windows.CEILING
		local _, Refused, Wrote = Land(Key, Ops({ Mint(1, 1, Later) }, 0, 2), Later)
		Expect(Refused.Whys).toBe(Similar({ "Overdue" }))
		Expect(Wrote).toBe(false)
		local After, Note, Landed = Land(Key, Requests.Fence({ Name = X, Stamp = Later, Attempt = 1, Final = true }), Later)
		Expect(Note.Report).toBe("Fenced")
		Expect(Landed).toBe(true)
		Expect(Record(After).Timed[X].Fate).toBe(Fate.Fenced)
	end)

	Test("a Tent that hears forgotten after a request of the call may have written fences the decider (CtlCleanRule)", function()
		local function Hear(Wrote: boolean): (string, unknown)
			local Use: Tx.Use = { Name = Book.Drawn(16, 60), Stamp = Heard.NOW }
			local Legs: { Tx.Leg } = {
				{ Ref = { Store = "Gold", Key = "a" }, MustExist = true, Change = { Field = GOLD, Amount = -1 } },
				{ Ref = DECIDER, MustExist = true, Change = { Field = GOLD, Amount = 1 } },
			}
			local Call, Asked = Machine.Start(Tx.Run, Tx.Context(Use, Legs, 2, 16), Heard.NOW)
			Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Forgotten" }, Wrote))
			return Machine.StateOf(Call), Machine.AnswerOf(Call)
		end
		local State, Reply = Hear(false)
		Expect(State).toBe("Done")
		Expect(Reply).toBe(Answer.Expired)
		State, Reply = Hear(true)
		Expect(State).toBe("Fencing")
		Expect(Reply).toBeNil()
	end)
end)

Describe("Controls of the hot keys", function()
	local PRINT = 7
	local SWORDS: Parts.Declared = { Name = "Swords", Parts = 2, Mode = Parts.MODE.Final, Stock = 2, Proceeds = {}, Print = PRINT, Place = "Gold$P:Swords:2" }
	local Using = Parts.Build(DEFAULT, SWORDS)
	local Counter = 0

	local function Send(Current: unknown, Body: { [string]: any }, At: number?): (unknown, Note)
		Counter += 1
		Body.Print = PRINT
		local Clock = At or NOW
		local Asked: Requests.Commit = { Name = `control{Counter}`, Stamp = Clock, Attempt = 1, Print = 1, Legs = {}, Leg = { Body = Body } }
		local Note = Step(Current, Requests.Commit(Asked, Body.Kind ~= "Open"), Clock, Using)
		return Note.Stored or Current, Note
	end

	local function Part(Value: unknown): Parts.Part
		return (Key.Read(Value) :: Key.Found).State :: any
	end

	Test("a part never seals while an escrow mark stands on it, and seals in the write that ends the mark", function()
		local Value = Send(nil, { Kind = "Open", Share = 1, At = NOW })
		Value = Land(Value, Tent(X, { Field = GOLD, Amount = 1 }), NOW, Using)
		Expect(Record(Value).Work[X]).never.toBeNil()
		Value = Send(Value, { Kind = "Take", Count = 1 })
		Expect(Part(Value).Free).toBe(0)
		Expect(Part(Value).Sealed).toBeNil()
		local Abort: Requests.End = { Name = X, Stamp = NOW, Attempt = 1, Outcome = "Abort" }
		Value = Land(Value, Requests.Ends({ Abort }), NOW, Using)
		Expect(Record(Value).Work[X]).toBeNil()
		Expect(Part(Value).Sealed).toBe(true)
	end)

	Test("a hold stands until the clock passes its end by HOLD_SLACK, and expires in the first write after", function()
		local Value = Send(nil, { Kind = "Open", Share = 2, At = NOW })
		Value = Send(Value, { Kind = "Hold", Id = "h", Count = 1, End = NOW + 10 })
		local Inside = Send(Value, { Kind = "Release", Id = "other" }, NOW + 10 + Parts.HOLD_SLACK)
		Expect(#Part(Inside).Holds).toBe(1)
		Expect(Part(Inside).Free).toBe(1)
		local Past = Send(Value, { Kind = "Release", Id = "other" }, NOW + 10 + Parts.HOLD_SLACK + 1)
		Expect(#Part(Past).Holds).toBe(0)
		Expect(Part(Past).Free).toBe(2)
	end)

	local function Start(): (Machine.Call<Walk.Context, Walk.Result>, { Machine.Asked }, Walk.Context)
		local Context = Walk.Context(SWORDS, { Kind = "Take", Count = 1, Print = PRINT }, {}, 9, 0)
		Context.Stamp = Heard.NOW
		Context.Names = { "d1", "d2", "d3" }
		local Call, Asked = Machine.Start(Walk.Machine, Context, Heard.NOW)
		return Call, Asked, Context
	end

	Test("a walk's leg on a part must find the part, so only open makes one (HotCtlOpenOnly)", function()
		local _, Asked = Start()
		local Ask = Asked[1].Ask
		local Running = (if Ask.Kind == "Run" then Ask.Context else error("the walk did not run a transaction")) :: Tx.Context
		local Leg = Running.Legs[#Running.Legs]
		Expect(Leg.Ref.Key).toBe(Parts.Key("Swords", 2, 0))
		Expect(Leg.MustExist).toBe(true)
		local Value, Note = Land(nil, Requests.Commit({ Name = "d1", Stamp = NOW, Attempt = 1, Legs = {}, Leg = Leg.Change }, Leg.MustExist), NOW, Using)
		Expect(Value).toBeNil()
		Expect(Note.Why).toBe("Missing")
	end)

	Test("a try that gives no answer stops the walk with Unresolved, and no other part is tried (HotCtlWalkStop)", function()
		local Call, Asked = Start()
		local Next = Machine.Step(Call, Asked[1].Id, Heard.Done(nil))
		Expect(#Next).toBe(0)
		Expect((Machine.AnswerOf(Call) :: Walk.Result).Reply).toBe(Answer.Unresolved)
		Expect((Machine.AnswerOf(Call) :: Walk.Result).Part).toBeNil()
	end)
end)

return nil
