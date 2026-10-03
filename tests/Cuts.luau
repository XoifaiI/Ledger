--!strict

--[=[

	Cuts: The cases for Record/Cuts and the seal, inside the real Step.

	The game is tests/Gold, whose money field is Gold. Land runs one request and keeps what it wrote,
	as the datastore would. Cut builds the request of one cut, and Seed a key holding some gold.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Requests = require("../src/Record/Requests")
local Testing = require("./Testing")
local Answer = require("../src/Core/Answer")
local Book = require("../src/Record/Book")
local CutMachine = require("../src/Calls/Cut")
local Game = require("./Gold")
local Heard = require("./Heard")
local Key = require("../src/Record/Key")
local Machine = require("../src/Machine/Machine")
local Touch = require("../src/Calls/Touch")
local Unseal = require("../src/Calls/Unseal")
local Step = require("../src/Record/Step")
local Types = require("../src/Record/Types")
local Windows = require("../src/Core/Constants/Windows")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

type Note = Types.Note
type Request = Requests.Request

local NOW = Game.NOW
local DEFAULT = Game.DEFAULT
local Gold, Record = Game.Gold, Game.Record
local Cause = Book.Cause
local DECIDER: Book.Ref = { Store = "Gold", Key = "d" }

local function Land(Current: unknown, Asked: Request, Clock: number?, Using: Types.Build?): (unknown, Note, boolean)
	local Note = Step(Current, Asked, Clock or NOW, Using or DEFAULT)
	local Value = Note.Stored
	return if Value then Value else Current, Note, Value ~= nil
end

local function Seed(Amount: number): unknown
	local Op: Requests.Op = { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = Amount } }
	return (Land(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = { Op } }))
end

local function Cut(Name: string, Kind: number, Change: { [string]: any }?): Request
	local Made: { [string]: any } = { Name = Name, Stamp = NOW, Kind = Kind, Print = 7, Helper = false, Server = 16 }
	for Field, Value in Change or {} do
		Made[Field] = Value
	end
	return { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Cut = Made :: any }
end

local function Tent(Name: string, Amount: number): Request
	return {
		Writer = 0,
		Ack = 0,
		MustExist = true,
		Ops = {},
		Tent = { Name = Name, Stamp = NOW, Attempt = 1, Print = 3, Decider = DECIDER, Leg = { Field = 1, Amount = Amount } },
	}
end

local function Ends(Name: string, Outcome: Requests.Outcome): { Requests.End }
	return { { Name = Name, Stamp = NOW, Attempt = 1, Print = 3, Outcome = Outcome } }
end

Describe("Reset", function()
	Test("a reset with no marks is one write: the default state, its money named, its name kept, the count up", function()
		local Key, Note, Wrote = Land(Seed(70), Cut("season", Cause.Reset))
		Expect(Wrote).toBe(true)
		Expect(Note.Report).toBe("Took")
		Expect(Gold(Key)).toBe(0)
		local Kept = Record(Key)
		Expect(Kept.Cuts).toBe(1)
		Expect(Kept.Cut.season.Kind).toBe(Cause.Reset)
		Expect(Kept.Events[1].Amounts[1]).toBe(70)
		Expect(Kept.Events[1].Cause).toBe(Cause.Reset)
		local _, Again, Twice = Land(Key, Cut("season", Cause.Reset))
		Expect(Again.Report).toBe("Took")
		Expect(Twice).toBe(false)
		Expect((select(2, Land(Key, Cut("season", Cause.Reset, { Print = 8 }))) :: Note).Report).toBe("Spent")
	end)

	Test("a reset given a state cuts to it, and a reset of a key with no money names nothing", function()
		local Key = Land(Seed(5), Cut("to-state", Cause.Reset, { State = { Gold = 40 } }))
		Expect(Gold(Key)).toBe(40)
		local Empty = Land(Seed(0), Cut("empty", Cause.Reset))
		Expect(#Record(Empty).Events).toBe(0)
	end)

	Test("a reset beside marks places its gate and reports them, and lands once the ends resolve them", function()
		local Key = Land(Seed(100), Tent("x", -30))
		local Gated, Note, Wrote = Land(Key, Cut("wipe", Cause.Reset, { State = { Gold = 9 } }))
		Expect(Wrote).toBe(true)
		Expect(Note.Report).toBe("Marks")
		Expect(Note.Items and Note.Items.x ~= nil).toBe(true)
		Expect((Record(Gated).Gate :: Book.Gate).Name).toBe("wipe")
		Expect((Gated :: any).r.Gold).toBe(9)
		local _, Again, Rewrote = Land(Gated, Cut("wipe", Cause.Reset, { State = { Gold = 9 } }))
		Expect(Again.Report).toBe("Marks")
		Expect(Rewrote).toBe(false)
		local Helped = Cut("wipe", Cause.Reset, { Helper = true })
		local Done, Took = Land(Gated, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Ends = Ends("x", "Abort"), Cut = Helped.Cut })
		Expect(Took.Report).toBe("Took")
		Expect(Gold(Done)).toBe(9)
		Expect(Record(Done).Gate).toBeNil()
		Expect((Done :: any).r).toBeNil()
		Expect(Record(Done).Events[1].Amounts[1]).toBe(100)
	end)

	Test("a gate stops a Tent, a helper with no gate of its own is gone, and another cut is gated by it", function()
		local Gated = Land(Land(Seed(100), Tent("x", -30)), Cut("wipe", Cause.Reset))
		Expect((select(2, Land(Gated, Tent("y", -10))) :: Note).Report).toBe("Gated")
		Expect((select(2, Land(Gated, Cut("other", Cause.Reset, { Helper = true }))) :: Note).Report).toBe("Gone")
		local _, By = Land(Gated, Cut("other", Cause.Reset))
		Expect(By.Report).toBe("GatedBy")
		Expect((By.Gate :: Book.Gate).Name).toBe("wipe")
	end)

	Test("a reset's gate lets a commit land and an erase's does not, and a gate the cut window passed goes with its state", function()
		local Commit: Request = {
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Commit = { Name = "c", Stamp = NOW, Attempt = 1, Print = 3, Legs = { DECIDER }, Leg = { Field = 1, Amount = 5 } },
		}
		local Reset = Land(Land(Seed(100), Tent("x", -30)), Cut("wipe", Cause.Reset, { State = { Gold = 9 } }))
		Expect((Reset :: any).r.Gold).toBe(9)
		Expect((select(2, Land(Reset, Commit)) :: Note).Report).toBe("Committed")
		local Erase = Land(Land(Seed(100), Tent("x", -30)), Cut("gone", Cause.Erase))
		Expect((select(2, Land(Erase, Commit)) :: Note).Report).toBe("Gated")
		local Later = NOW + Windows.CUT
		local Edit: Requests.Op = { Form = "Minted", Seq = 2, Stamp = Later, Kind = 0, Body = { Add = 1 } }
		local Aged = Land(Reset, { Writer = 1, Ack = 1, MustExist = true, Ops = { Edit } }, Later)
		Expect(Record(Aged).Gate).toBeNil()
		Expect((Aged :: any).r).toBeNil()
		Expect(Record(Aged).CutHorizon >= NOW).toBe(true)
		Expect((select(2, Land(Aged, Cut("wipe", Cause.Reset), Later)) :: Note).Report).toBe("Forgotten")
	end)

	Test("a cut from a build that lacks the key's level is behind, even under its own gate", function()
		local Newer = Game.Build({ Level = 1, Migrations = {
			function(State: any): unknown
				return State
			end,
		} })
		local Key = Land(Seed(5), { Writer = 2, Ack = 0, MustExist = true, Ops = { { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = 1 } } } }, NOW, Newer)
		Expect((select(2, Land(Key, Cut("old", Cause.Reset))) :: Note).Report).toBe("Behind")
	end)

	Test("events past the loss room fold into exact sums per period, and the cut waits when none can", function()
		local Small = Game.Build({ LossRoom = 40 })
		local Key = Seed(7)
		for Index = 1, 4 do
			Key = Land(Key, Cut(`r{Index}`, Cause.Reset, { State = { Gold = Index * 1000 } }), NOW, Small)
		end
		local Kept = Record(Key)
		local Folded = 0
		for _, Slot in Kept.Slots do
			Folded += Slot.Count
		end
		local Total = 0
		for _, Event in Kept.Events do
			Total += Event.Amounts[1]
		end
		for _, Slot in Kept.Slots do
			local Sum = Slot.Sums[1]
			Total += Sum.High * 2 ^ 35 + Sum.Low
		end
		Expect(Folded > 0).toBe(true)
		Expect(Total).toBe(7 + 1000 + 2000 + 3000)
		local Ahead = Game.Build({ LossRoom = 20 })
		local Stuck = Land(Seed(3), Cut("early", Cause.Reset, { State = { Gold = 5 } }), NOW + 30, Ahead)
		local _, Waited = Land(Stuck, Cut("late", Cause.Reset), NOW, Ahead)
		Expect(Waited.Report).toBe("Wait")
		Expect(Waited.Wait).toBe(NOW + 30)
		local Marked = Land(Stuck, Tent("x", -1), NOW, Ahead)
		local Wrote, Riding, Landed = Land(Marked, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Ends = Ends("x", "Abort"), Cut = Cut("late", Cause.Reset).Cut }, NOW, Ahead)
		Expect(Riding.Report).toBe("Wait")
		Expect(Landed).toBe(true)
		local Named = 0
		for _, Event in Record(Wrote).Events do
			Named += Event.Amounts[1]
		end
		for _, Slot in Record(Wrote).Slots do
			Named += Slot.Sums[1].High * 2 ^ 35 + Slot.Sums[1].Low
		end
		Expect(Named).toBe(3)
	end)
end)

Describe("Erase", function()
	Test("an erase with nothing standing seals the key with its namings, and its retry finds its own seal", function()
		local Sealed, Note, Wrote = Land(Seed(25), Cut("forget", Cause.Erase))
		Expect(Wrote).toBe(true)
		Expect(Note.Report).toBe("Sealed")
		local Seal = assert(Key.Seal(Sealed))
		Expect(Seal.Server).toBe(16)
		Expect(Seal.Rt).toBe(NOW)
		Expect(Seal.Events[1].Amounts[1]).toBe(25)
		local _, Again, Twice = Land(Sealed, Cut("forget", Cause.Erase))
		Expect(Again.Report).toBe("Sealed")
		Expect((Again.Seal :: Book.Seal).Events[1].Amounts[1]).toBe(25)
		Expect(Twice).toBe(false)
	end)

	Test("an erase counts pinned records as standing, and its gate holds them until they drop", function()
		local Commit: Request = {
			Writer = 0,
			Ack = 0,
			MustExist = true,
			Ops = {},
			Commit = { Name = "p", Stamp = NOW, Attempt = 1, Print = 3, Legs = { { Store = "Gold", Key = "a" } }, Leg = { Field = 1, Amount = 5 } },
		}
		local Pinned = Land(Seed(1), Commit)
		local Gated, Note = Land(Pinned, Cut("forget", Cause.Erase))
		Expect(Note.Report).toBe("Marks")
		Expect(Note.Items and Note.Items.p ~= nil).toBe(true)
		local Done = Land(Gated, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Drops = { "p" }, Cut = Cut("forget", Cause.Erase).Cut })
		Expect(Key.Seal(Done) ~= nil).toBe(true)
	end)

	Test("a seal turns away every other request until it is left over, and then a create replaces it", function()
		local Sealed = Land(Seed(25), Cut("forget", Cause.Erase))
		local Op: Requests.Op = { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = 4 } }
		local Create: Request = { Writer = 3, Ack = 0, MustExist = false, Ops = { Op } }
		local _, Early = Land(Sealed, Create)
		Expect(Early.Whys[1]).toBe("Missing")
		Expect(Early.Left).toBe(false)
		local Left = NOW + Windows.SEAL_AGE
		local _, Edge = Land(Sealed, Create, Left - 1)
		Expect(Edge.Whys[1]).toBe("Missing")
		local Made, Fresh = Land(Sealed, Create, Left)
		Expect(Fresh.Fates[1]).toBe(Book.Fate.Took)
		Expect(Gold(Made)).toBe(4)
		local Must: Request = { Writer = 3, Ack = 0, MustExist = true, Ops = { Op } }
		local _, Told = Land(Sealed, Must, Left)
		Expect(Told.Left).toBe(true)
	end)

	Test("a stamp lands on a left over seal, or at once from the server that stamped rt, and drops old namings", function()
		local Sealed = Land(Seed(25), Cut("forget", Cause.Erase))
		local Other: Request = { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Stamp = { Server = 99 } }
		Expect((select(2, Land(Sealed, Other, NOW + 1)) :: Note).Why).toBe("Missing")
		local Own: Request = { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Stamp = { Server = 16, Rt = NOW } }
		local Again, Stamped = Land(Sealed, Own, NOW + 1)
		Expect(Stamped.Report).toBe("Stamped")
		Expect((assert(Key.Seal(Again))).Rt).toBe(NOW + 1)
		Expect(#(assert(Key.Seal(Again))).Events).toBe(1)
		local Late = NOW + Windows.SEAL_AGE
		local Restamped = Land(Sealed, Other, Late)
		local Seal = assert(Key.Seal(Restamped))
		Expect(Seal.Server).toBe(99)
		Expect(Seal.Rt).toBe(Late)
		Expect(#Seal.Events).toBe(0)
	end)

	Test("ProveGone seals a key with no value or a left over seal, and writes nothing on a value or a fresh seal", function()
		local Asked = Requests.ProveGone()
		local Made, Proved, Wrote = Land(nil, Asked)
		Expect(Wrote).toBe(true)
		Expect(Proved.Report).toBe("Stamped")
		local Seal = assert(Key.Seal(Made))
		Expect(Seal.Name).toBe(Book.Drawn(0, 0))
		Expect(Seal.Server).toBe(0)
		Expect(Seal.Rt).toBe(NOW)
		local _, OnValue, WroteValue = Land(Seed(25), Asked)
		Expect(WroteValue).toBe(false)
		Expect(OnValue.Report).toBeNil()
		local Sealed = Land(Seed(25), Cut("forget", Cause.Erase))
		local _, OnFresh, WroteFresh = Land(Sealed, Asked, NOW + 1)
		Expect(WroteFresh).toBe(false)
		Expect(OnFresh.Why).toBe("Missing")
		local Restamped, OnLeft = Land(Sealed, Asked, NOW + Windows.SEAL_AGE)
		Expect(OnLeft.Report).toBe("Stamped")
		local Kept = assert(Key.Seal(Restamped))
		Expect(Kept.Name).toBe("forget")
		Expect(Kept.Server).toBe(0)
	end)
end)

Describe("Cut machine", function()
	local LATER = Heard.NOW
	local REF: Book.Ref = { Store = "Gold", Key = "k" }

	local function Start(Kind: number, Erasable: boolean?, Helper: boolean?): (Machine.Call<CutMachine.Context, CutMachine.Result>, { Machine.Asked })
		local Asked: Requests.Cut = { Name = "wipe", Stamp = LATER, Kind = Kind, Print = 7, Helper = Helper == true, Server = 16 }
		return Machine.Start(CutMachine.Machine, CutMachine.Context(REF, Asked, Erasable == true), LATER)
	end

	local function Sent(Asked: { Machine.Asked }): Request
		local Ask = Asked[1].Ask
		return if Ask.Kind == "Send" then Ask.Request else error("not a send")
	end

	local function Reply(Call: Machine.Call<CutMachine.Context, CutMachine.Result>): unknown
		local Result = Machine.AnswerOf(Call)
		return if Result then Result.Reply else nil
	end

	local Mark: Book.Escrow = { Form = "Escrow", Stamp = LATER, Attempt = 1, Print = 3, Clean = true, Decider = DECIDER, Field = 1, Amount = -5 }

	Test("a cut that took answers true, a name under other terms Spent, and a forgotten one Expired or Unresolved", function()
		local Call, Asked = Start(Cause.Reset)
		Expect(Sent(Asked).Cut ~= nil).toBe(true)
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Took" }, true))
		Expect(Reply(Call)).toBe(true)
		Call, Asked = Start(Cause.Reset)
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Spent" }))
		Expect(Reply(Call)).toBe(Answer.Spent)
		Call, Asked = Start(Cause.Reset)
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Forgotten" }))
		Expect(Reply(Call)).toBe(Answer.Expired)
		Call, Asked = Start(Cause.Reset)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Marks", Items = { x = Mark } }, true))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Committed", Attempt = 1 }))
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Forgotten" }))
		Expect(Reply(Call)).toBe(Answer.Unresolved)
	end)

	Test("an erasable key is read first, and a read that fails answers Unresolved and cuts nothing", function()
		local Call, Asked = Start(Cause.Reset, true)
		Expect(Asked[1].Ask.Kind).toBe("Read")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Failed())
		Expect(#Asked).toBe(0)
		Expect(Reply(Call)).toBe(Answer.Unresolved)
		Call, Asked = Start(Cause.Reset, true)
		local Op: Requests.Op = { Form = "Minted", Seq = 1, Stamp = NOW, Kind = 0, Body = { Add = 1 }, Create = "i3" }
		local Held = Step(nil, { Writer = 1, Ack = 0, MustExist = false, Ops = { Op } }, NOW, DEFAULT).Stored
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Held))
		Expect((Sent(Asked).Cut :: Requests.Cut).Id).toBe("i3")
	end)

	Test("marks are fenced, not finally, at their deciders, and what the fences report rides on the next send", function()
		local Call, Asked = Start(Cause.Reset)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Marks", Items = { x = Mark } }, true))
		local Ask = Asked[1].Ask
		Expect(Ask.Kind == "Send" and Ask.Ref.Key == "d").toBe(true)
		local Fence = assert(Sent(Asked).Fence)
		Expect(Fence.Final).toBe(false)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Committed", Attempt = 1 }))
		local Ends = assert(Sent(Asked).Ends)
		Expect(Ends[1].Name).toBe("x")
		Expect(Ends[1].Outcome).toBe("Commit")
		local Pinned: Book.Pinned = { Form = "Pinned", Stamp = LATER, Attempt = 1, Print = 3, Legs = { REF } }
		Call, Asked = Start(Cause.Erase)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Marks", Items = { p = Pinned } }, true))
		Ask = Asked[1].Ask
		Expect(Ask.Kind == "Run" and Ask.Machine == Touch.Pinned).toBe(true)
	end)

	Test("a mark ORPHAN old whose fence reports missing has its decider read, and a gone decider rides its orphan end", function()
		local Orphaned: Book.Escrow = { Form = "Escrow", Stamp = LATER - Windows.ORPHAN, Attempt = 1, Print = 3, Clean = true, Decider = DECIDER, Field = 1, Amount = -5 }
		local Call, Asked = Start(Cause.Erase)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Marks", Items = { x = Orphaned } }, true))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Why = "Missing" }))
		local Ask = Asked[1].Ask
		Expect(Ask.Kind == "Read" and Ask.Ref.Key == "d").toBe(true)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		local Ends = assert(Sent(Asked).Ends)
		Expect(Ends[1].Name).toBe("x")
		Expect(Ends[1].Outcome).toBe("Orphan")
		Call, Asked = Start(Cause.Erase)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Marks", Items = { x = Orphaned } }, true))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Why = "Missing" }))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Seed(1)))
		Expect(Sent(Asked).Ends).toBeNil()
		Call, Asked = Start(Cause.Erase)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Marks", Items = { x = Mark } }, true))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Why = "Missing" }))
		Ask = Asked[1].Ask
		Expect(Ask.Kind == "Send" and Ask.Request.Cut ~= nil and Ask.Request.Ends == nil).toBe(true)
	end)

	Test("another cut's gate is finished by a helper first, and a wait waits for the clock it names", function()
		local Gate: Book.Gate = { Name = "older", Stamp = LATER - 5, Kind = Cause.Reset, Print = 1, At = LATER - 5 }
		local Call, Asked = Start(Cause.Reset)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "GatedBy", Gate = Gate }))
		local Ask = Asked[1].Ask
		local Helping = (if Ask.Kind == "Run" then Ask.Context else nil) :: CutMachine.Context?
		Expect(Helping and Helping.Cut.Name).toBe("older")
		Expect(Helping and Helping.Cut.Helper).toBe(true)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Expect(Sent(Asked).Cut ~= nil).toBe(true)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Wait", Wait = LATER + 7 }))
		Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Wait" then Ask.Seconds else -1).toBe(7)
	end)

	Test("Missing answers Missing while clean, true for an erase that may have written, and Unresolved for a reset", function()
		local Call, Asked = Start(Cause.Erase)
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Why = "Missing" }))
		Expect(Reply(Call)).toBe(Answer.Missing)
		for _, Case in { { Cause.Erase, true }, { Cause.Reset, Answer.Unresolved } } :: { { any } } do
			Call, Asked = Start(Case[1])
			Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Marks", Items = { x = Mark } }, true))
			Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Fenced", Attempt = 1 }))
			Machine.Step(Call, Asked[1].Id, Heard.Sent({ Why = "Missing" }))
			Expect(Reply(Call)).toBe(Case[2])
		end
	end)

	Test("another erase's seal answers Busy, and a left over one is taken off before the cut goes again", function()
		local Seal: Book.Seal = { Name = "other", Stamp = LATER, Server = 9, Rt = LATER, Events = {}, Slots = {} }
		local Call, Asked = Start(Cause.Reset)
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Why = "Missing", Seal = Seal, Left = false }))
		Expect(Reply(Call)).toBe(Answer.Busy)
		Call, Asked = Start(Cause.Reset)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Why = "Missing", Seal = Seal, Left = true }))
		local Ask = Asked[1].Ask
		Expect(Ask.Kind == "Run" and Ask.Machine == Unseal.Machine).toBe(true)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done(true))
		Expect(Sent(Asked).Cut ~= nil).toBe(true)
	end)

	Test("an erase whose own write sealed the key answers its namings, removes the key once, and checks at SEAL_AGE", function()
		local Seal: Book.Seal = {
			Name = "wipe",
			Stamp = LATER,
			Print = 7,
			Server = 16,
			Rt = LATER,
			Events = { { Cause = Cause.Erase, Name = "wipe", Stamp = LATER, Amounts = { [1] = 12 } } },
			Slots = {},
		}
		local Call, Asked = Start(Cause.Erase)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Sealed", Seal = Seal, Stored = Key.Sealed(Seal) }, true))
		local Result = assert(Machine.AnswerOf(Call))
		Expect(Result.Reply).toBe(true)
		Expect((Result.Seal :: Book.Seal).Events[1].Amounts[1]).toBe(12)
		Expect(Asked[1].Ask.Kind).toBe("Remove")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		local Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Wait" then Ask.Seconds else -1).toBe(Windows.SEAL_AGE)
		Call, Asked = Start(Cause.Erase)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Sealed", Seal = Seal }))
		Expect((assert(Machine.AnswerOf(Call))).Reply).toBe(true)
		Expect(Asked[1].Ask.Kind).toBe("Wait")
	end)

	Test("a helper that sealed the key waits the cut window before it stamps the seal and removes it", function()
		local Seal: Book.Seal = { Name = "wipe", Stamp = LATER, Print = 7, Server = 16, Rt = LATER, Events = {}, Slots = {} }
		local Call, Asked = Start(Cause.Erase, false, true)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Sealed", Seal = Seal, Stored = Key.Sealed(Seal) }, true))
		local Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Wait" then Ask.Seconds else -1).toBe(Windows.CUT)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		local Stamp = assert(Sent(Asked).Stamp)
		Expect(Stamp.Rt).toBe(LATER)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Stamped", Seal = Seal }, true))
		Expect(Asked[1].Ask.Kind).toBe("Remove")
	end)
end)

Describe("Unseal", function()
	local REF: Book.Ref = { Store = "Gold", Key = "k" }

	Test("a stamp that lands sends the key's one removal, and one that does not, or is not this server's, sends none", function()
		local Call, Asked = Machine.Start(Unseal.Machine, Unseal.Context(REF, 16, nil), Heard.NOW)
		local Seal: Book.Seal = { Name = "e", Stamp = Heard.NOW, Server = 16, Rt = Heard.NOW, Events = {}, Slots = {} }
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Stamped", Seal = Seal }, true))
		Expect(Asked[1].Ask.Kind).toBe("Remove")
		Machine.Step(Call, Asked[1].Id, Heard.Done())
		Expect(Machine.AnswerOf(Call)).toBe(true)
		Call, Asked = Machine.Start(Unseal.Machine, Unseal.Context(REF, 16, nil), Heard.NOW)
		Machine.Step(Call, Asked[1].Id, Heard.Sent({ Why = "Missing" }))
		Expect(Machine.AnswerOf(Call)).toBe(false)
		local Theirs: Book.Seal = { Name = "e", Stamp = Heard.NOW, Server = 9, Rt = Heard.NOW, Events = {}, Slots = {} }
		local Stale: Book.Seal = { Name = "e", Stamp = Heard.NOW, Server = 16, Rt = Heard.NOW - Windows.REMOVE_SEND - 1, Events = {}, Slots = {} }
		for _, Other in { Theirs, Stale } do
			Call, Asked = Machine.Start(Unseal.Machine, Unseal.Context(REF, 16, nil), Heard.NOW)
			Asked = Machine.Step(Call, Asked[1].Id, Heard.Sent({ Report = "Stamped", Seal = Other }, true))
			Expect(#Asked).toBe(0)
			Expect(Machine.AnswerOf(Call)).toBe(false)
		end
	end)
end)

return nil
