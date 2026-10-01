--!strict

--[=[

	Copies: The cases for Record/Copies and Calls/Copy, stepped directly with the replies they hear.

	Item makes a header the way a holder writes it, through Copies.Merge. Part makes a part item for
	a write count, and Newer an item of a newer format. A view is built by hand, as the Peek a
	refresh runs would answer it. Held makes what one server holds for the key 7 of Gold. Start runs
	a follower of it, and Once runs a Peek with a MaxAge.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Copies = require("../src/Record/Copies")
local Copy = require("../src/Calls/Copy")
local Game = require("./Gold")
local Heard = require("./Heard")
local Limits = require("../src/Core/Constants/Limits")
local Machine = require("../src/Machine/Machine")
local Shown = require("../src/Record/Shown")
local View = require("../src/Record/View")
local Windows = require("../src/Core/Constants/Windows")
local Writer = require("../src/Encode/Writer")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

type State = { [string]: any }

local NOW = Heard.NOW
local REF = { Store = "Gold", Key = "7" }

type Made = {
	Parts: number?,
	State: State?,
	Level: number?,
	Floor: number?,
	Holder: number?,
	Until: number?,
}

local function Item(Writes: number, Asked: Made): unknown
	local Fresh: Copies.Fresh = { Writes = Writes, Level = Asked.Level or 0, Floor = Asked.Floor or 0, Parts = Asked.Parts or 0, State = Asked.State }
	return Copies.Merge(nil, Fresh, Asked.Holder or 3, NOW, Asked.Until or NOW + Windows.LEASE)
end

local function Part(Writes: number, Fields: State): unknown
	local Book = Writer.New()
	Writer.Var(Book, Writes)
	return { s = Fields, b = Writer.Finish(Book) }
end

local function Newer(): unknown
	local Book = Writer.New()
	Writer.Var(Book, Copies.FORMAT + 1)
	return { b = Writer.Finish(Book) }
end

local function Held(): Copies.Held
	return Copies.New(REF)
end

local function Seen(Gold: number, Writes: number): View.View
	return { State = { Gold = Gold }, Writes = Writes, Cuts = 0, Horizon = 0, Level = 0, Floor = 0, Work = {} }
end

local function Large(Writes: number): View.View
	local Found = Seen(1, Writes)
	for Index = 1, 3 do
		Found.State[`Tag{Index}`] = string.rep("a", 20000)
	end
	return Found
end

local function Kinds(Asked: { Machine.Asked }): string
	local Found: { string } = {}
	for _, Each in Asked do
		table.insert(Found, Each.Ask.Kind)
	end
	return table.concat(Found, " ")
end

local function Waits(Asked: { Machine.Asked }): number
	local Ask = Asked[1].Ask
	return if Ask.Kind == "Wait" then Ask.Seconds else -1
end

local function Start(Kept: Copies.Held, Table: Shown.Shown?, Followed: boolean?, Shows: { any }?)
	local Context = Copy.Context(Kept, Game.DEFAULT, Table or Shown.New(), 9, 0)
	Context.Followed = function(): boolean
		return Followed ~= false
	end
	Context.Show = function(State: State)
		table.insert(Shows or {}, State)
	end
	return Machine.Start(Copy.Follow, Context, NOW)
end

local function Once(Kept: Copies.Held, MaxAge: number)
	local Context = Copy.Context(Kept, Game.DEFAULT, Shown.New(), 9, 0)
	Context.Once, Context.MaxAge = true, MaxAge
	return Machine.Start(Copy.Follow, Context, NOW)
end

local function Fixing(Kept: Copies.Held)
	return Machine.Start(Copy.Refresh, { Held = Kept, Build = Game.DEFAULT, Shown = Shown.New(), Server = 9, Pieces = {}, Until = 0 }, NOW)
end

Describe("Copies", function()
	Test("a state that fits rides in the header, a larger one in parts by field, and one past the parts is big", function()
		local Small, None = Copies.Content(3, 1, 0, { Gold = 5 })
		Expect(Small.Parts).toBe(0)
		Expect(#None).toBe(0)
		local Fresh, Pieces = Copies.Content(4, 0, 0, Large(4).State)
		Expect(Fresh.Parts).toBe(3)
		Expect(#Pieces).toBe(3)
		local Header = Copies.Read(Copies.Merge(nil, Fresh, 3, NOW, NOW + 90)) :: Copies.Header
		local Joined = Copies.Join(Header, Pieces) :: State
		Expect(Joined.Gold).toBe(1)
		Expect(#Joined.Tag3).toBe(20000)
		local Huge: State = {}
		for Index = 1, Limits.PARTS_MAX + 1 do
			Huge[`Tag{Index}`] = string.rep("a", 20000)
		end
		Expect(Copies.Content(5, 0, 0, Huge).Parts).toBe(Copies.BIG)
		Expect(Copies.Content(5, 0, 0, { Tag = string.rep("a", Limits.ITEM_ROOM) }).Parts).toBe(Copies.BIG)
	end)

	Test("parts show only when every one carries the header's write count", function()
		local Header = Copies.Read(Item(6, { Parts = 2 })) :: Copies.Header
		Expect((Copies.Join(Header, { Part(6, { A = 1 }), Part(6, { B = 2 }) }) :: State).B).toBe(2)
		Expect(Copies.Join(Header, { Part(6, { A = 1 }), Part(4, { B = 2 }) })).toBeNil()
		Expect(Copies.Join(Header, { Part(6, { A = 1 }) })).toBeNil()
		Expect(Copies.Join(Header, { Part(6, { A = 1 }), { s = { B = 2 }, b = "!" } })).toBeNil()
	end)

	Test("the header keeps the larger write count, renews only the holder on a smaller one, and is not taken while another holds it", function()
		local Old = Item(5, { State = { Gold = 1 }, Holder = 3, Until = NOW + 90 })
		Expect(Copies.Merge(Old, { Writes = 6, Level = 0, Floor = 0, Parts = 0, State = { Gold = 2 } }, 4, NOW + 10, NOW + 100)).toBeNil()
		local Mine = Copies.Read(Copies.Merge(Old, { Writes = 4, Level = 0, Floor = 0, Parts = 0, State = { Gold = 0 } }, 3, NOW + 10, NOW + 100)) :: Copies.Header
		Expect((Mine.State :: State).Gold).toBe(1)
		Expect(Mine.Until).toBe(NOW + 100)
		local Taken = Copies.Merge(Old, { Writes = 6, Level = 0, Floor = 0, Parts = 0, State = { Gold = 2 } }, 4, NOW + 91, NOW + 181)
		local Header = Copies.Read(Taken) :: Copies.Header
		Expect((Header.State :: State).Gold).toBe(2)
		Expect(Header.Holder).toBe(4)
		local Renewed = Copies.Read(Copies.Merge(Taken, nil, 4, NOW + 120, NOW + 210)) :: Copies.Header
		Expect(Renewed.Writes).toBe(6)
		Expect(Renewed.At).toBe(NOW + 120)
		Expect(Copies.Merge(nil, nil, 4, NOW, NOW)).toBeNil()
		Expect(Copies.Merge(Newer(), { Writes = 1, Level = 0, Floor = 0, Parts = 0, State = {} }, 4, NOW, NOW)).toBeNil()
		Expect(Copies.Read(Newer())).toBe("Behind")
		Expect(Copies.Read({ b = "!" })).toBeNil()
	end)

	Test("a copied state is shown through the reader's build", function()
		local Newest = Game.Build({ Level = 1, Floor = 1, Migrations = {
			function(State: any): unknown
				return { Gold = State.Gold * 2 }
			end,
		} })
		local Header = Copies.Read(Item(1, { State = { Gold = 4 } })) :: Copies.Header
		Expect((Copies.Show(Header, { Gold = 4 }, Newest) :: State).Gold).toBe(8)
		local Ahead = Copies.Read(Item(1, { State = { Gold = 4 }, Level = 1, Floor = 1 })) :: Copies.Header
		Expect(Copies.Show(Ahead, { Gold = 4 }, Game.DEFAULT)).toBe("Behind")
	end)

	Test("a follower shows a newer header's state once, rests a tick, and rests twice as long while the write count stands", function()
		local Kept = Held()
		local Shows: { any } = {}
		local Call, Asked = Start(Kept, nil, true, Shows)
		Expect(Kinds(Asked)).toBe("Item")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item(3, { State = { Gold = 5 } })))
		Expect(#Shows).toBe(1)
		Expect(Shows[1].Gold).toBe(5)
		Expect(Kept.Writes).toBe(3)
		Expect(Waits(Asked)).toBe(Windows.TICK)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item(3, { State = { Gold = 5 } })))
		Expect(Waits(Asked)).toBe(2 * Windows.TICK)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item(2, { State = { Gold = 1 } })))
		Expect(#Shows).toBe(1)
		Expect(Kept.Writes).toBe(3)
	end)

	Test("a follower never shows a state older than one this server showed by any read", function()
		local Kept = Held()
		local Table = Shown.New()
		Table:Show(Kept.Mark, 5)
		local Shows: { any } = {}
		local Call, Asked = Start(Kept, Table, true, Shows)
		Machine.Step(Call, Asked[1].Id, Heard.Read(Item(4, { State = { Gold = 5 } })))
		Expect(#Shows).toBe(0)
	end)

	Test("parts of another write count are a miss, and two misses in a row make the follower a taker", function()
		local Kept = Held()
		local Call, Asked = Start(Kept)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item(6, { Parts = 2 })))
		Expect(Kinds(Asked)).toBe("Item Item")
		local Ask = Asked[2].Ask
		Expect(if Ask.Kind == "Item" then Ask.Key else "").toBe("c/Gold/7/0/1")
		Machine.Step(Call, Asked[1].Id, Heard.Read(Part(6, { A = 1 })))
		Asked = Machine.Step(Call, Asked[2].Id, Heard.Read(Part(4, { B = 2 })))
		Expect(Kinds(Asked)).toBe("Wait")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item(6, { Parts = 2 })))
		Machine.Step(Call, Asked[1].Id, Heard.Read(Part(6, { A = 1 })))
		Asked = Machine.Step(Call, Asked[2].Id, Heard.Failed())
		Expect(Kinds(Asked)).toBe("Run")
		Expect(Kept.Writes).toBe(0)
	end)

	Test("no header, or a lapsed holder, makes the follower a taker, and a refresh it wins makes it the holder", function()
		local Kept = Held()
		local Shows: { any } = {}
		local Call, Asked = Start(Kept, nil, true, Shows)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Expect(Kinds(Asked)).toBe("Run")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done({ Holder = true, View = Seen(8, 2), Gone = false }))
		Expect(Kept.Holder).toBe(true)
		Expect(Shows[1].Gold).toBe(8)
		Expect(Waits(Asked)).toBe(Windows.CHECK)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Expect(Kinds(Asked)).toBe("Run")
		Call, Asked = Start(Held())
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item(3, { State = { Gold = 5 }, Until = NOW - 1 })))
		Expect(Kinds(Asked)).toBe("Run")
	end)

	Test("with the map down a follower reads the key itself at most once every FOLLOW_EVERY, and a gone key takes the copy off", function()
		local Kept = Held()
		local Shows: { any } = {}
		local Call, Asked = Start(Kept, nil, true, Shows)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Failed())
		Expect(Kinds(Asked)).toBe("Run")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done(Seen(3, 4)))
		Expect(Shows[1].Gold).toBe(3)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Failed())
		Expect(Kinds(Asked)).toBe("Wait")
		Kept.Read = NOW - Windows.FOLLOW_EVERY
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item(9, { Parts = Copies.BIG })))
		Expect(Kinds(Asked)).toBe("Run")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done("Missing"))
		Expect(#Asked).toBe(1 + 2 * Limits.PARTS_MAX)
		Expect(Kept.State).toBeNil()
		Expect(Kept.Writes).toBe(0)
	end)

	Test("a follower stops once nothing follows the key", function()
		local Kept = Held()
		Kept.Running = true
		local Call, Asked = Start(Kept, nil, false)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item(3, { State = { Gold = 5 } })))
		Expect(#Asked).toBe(0)
		Expect(Machine.IsFinal(Call)).toBe(true)
		Expect(Kept.Running).toBe(false)
	end)

	Test("a Peek with a MaxAge answers a young state with no request, else ticks once, and a newer header answers Behind", function()
		local Kept = Held()
		Kept.Writes, Kept.State, Kept.At = 3, { Gold = 5 }, NOW - 10
		local Call, Asked = Once(Kept, 30)
		Expect(#Asked).toBe(0)
		Expect((Machine.AnswerOf(Call) :: State).Gold).toBe(5)
		Call, Asked = Once(Kept, 5)
		Expect(Kinds(Asked)).toBe("Item")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item(4, { State = { Gold = 6 } })))
		Expect(#Asked).toBe(0)
		Expect((Machine.AnswerOf(Call) :: State).Gold).toBe(6)
		Call, Asked = Once(Held(), 5)
		Machine.Step(Call, Asked[1].Id, Heard.Read(Newer()))
		Expect(Machine.AnswerOf(Call)).toBe("Behind")
		Call, Asked = Once(Held(), 5)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Failed())
		Expect(Kinds(Asked)).toBe("Run")
	end)

	Test("a refresh sends every part into its slot before the header, and the header names this holder", function()
		local Kept = Held()
		local Call, Asked = Fixing(Kept)
		Expect(Kinds(Asked)).toBe("Run")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done(Large(7)))
		Expect(Kinds(Asked)).toBe("Put Put Put")
		local Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Put" then Ask.Key else "").toBe("c/Gold/7/1/0")
		for Index = 1, 2 do
			Machine.Step(Call, Asked[Index].Id, Heard.Done())
		end
		Asked = Machine.Step(Call, Asked[3].Id, Heard.Done())
		Expect(Kinds(Asked)).toBe("Change")
		Ask = Asked[1].Ask
		local Wrote = if Ask.Kind == "Change" then Ask.Transform(nil) else error("not a change")
		local Header = Copies.Read(Wrote) :: Copies.Header
		Expect(Header.Writes).toBe(7)
		Expect(Header.Parts).toBe(3)
		Expect(Header.Holder).toBe(9)
		Machine.Step(Call, Asked[1].Id, Heard.Read(Wrote))
		Expect((Machine.AnswerOf(Call) :: Copy.Refreshed).Holder).toBe(true)
		Expect(Kept.Sent).toBe(7)
		Expect(Kept.Pushed).toBe(NOW)
	end)

	Test("a holder whose write count stands and whose lease is far writes nothing, and a lost header or part keeps it from holding", function()
		local Kept = Held()
		Kept.Holder, Kept.Sent, Kept.Pushed, Kept.Until = true, 7, NOW, NOW + Windows.LEASE
		local Call, Asked = Fixing(Kept)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done(Seen(1, 7)))
		Expect(#Asked).toBe(0)
		Expect((Machine.AnswerOf(Call) :: Copy.Refreshed).Holder).toBe(true)
		Kept.Until = NOW + 5
		Call, Asked = Fixing(Kept)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done(Seen(1, 7)))
		Expect(Kinds(Asked)).toBe("Change")
		local Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Change" then Ask.Transform(nil) else true).toBeNil()
		Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Expect((Machine.AnswerOf(Call) :: Copy.Refreshed).Holder).toBe(false)
		Call, Asked = Fixing(Kept)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done(Large(8)))
		Machine.Step(Call, Asked[1].Id, Heard.Failed(true))
		Machine.Step(Call, Asked[2].Id, Heard.Done())
		Asked = Machine.Step(Call, Asked[3].Id, Heard.Done())
		Expect(#Asked).toBe(0)
		Expect(Kept.Sent).toBe(7)
	end)

	Test("a refresh that finds the key gone, and an erase, take off the header and both slots of parts", function()
		local Call, Asked = Fixing(Held())
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Done("Missing"))
		Expect(#Asked).toBe(1 + 2 * Limits.PARTS_MAX)
		Expect(Kinds(Asked):match("^Drop")).toBe("Drop")
		for _, Each in Asked do
			Machine.Step(Call, Each.Id, Heard.Done())
		end
		Expect((Machine.AnswerOf(Call) :: Copy.Refreshed).Gone).toBe(true)
		local Wipe, Wiping = Machine.Start(Copy.Clear, Held(), NOW)
		Wiping = Machine.Step(Wipe, Wiping[1].Id, Heard.Read(Item(3, { State = {} })))
		Expect(#Wiping).toBe(1 + 2 * Limits.PARTS_MAX)
		Wipe, Wiping = Machine.Start(Copy.Clear, Held(), NOW)
		Wiping = Machine.Step(Wipe, Wiping[1].Id, Heard.Read(nil))
		Expect(#Wiping).toBe(0)
	end)
end)

return nil
