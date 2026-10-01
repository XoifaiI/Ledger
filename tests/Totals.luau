--!strict

--[=[

	Totals: The cases for Record/Totals, with shards run through the real Step.

	Shard builds the build of a total's shard from tests/Gold's defaults. Bump lands one minted bump on
	a shard as the datastore would. The machines are stepped directly, with the replies they hear.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Asks = require("../src/Machine/Asks")
local Game = require("./Gold")
local Heard = require("./Heard")
local Key = require("../src/Record/Key")
local Machine = require("../src/Machine/Machine")
local Queue = require("../src/Record/Queue")
local Save = require("../src/Calls/Save")
local Step = require("../src/Record/Step")
local Total = require("../src/Record/Totals")
local TotalCall = require("../src/Calls/Total")
local Types = require("../src/Record/Types")
local Windows = require("../src/Core/Constants/Windows")
local Writer = require("../src/Encode/Writer")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local NOW = Heard.NOW

local function Shard(Shards: number): Types.Build
	return Total.Build(Shards, Game.DEFAULT)
end

local function Bump(Current: unknown, Seq: number, Add: number, Using: Types.Build, At: number?): (unknown, Types.Note)
	local Clock = At or NOW
	local Op: Types.Op = { Form = "Minted", Seq = Seq, Stamp = Clock, Kind = 0, Body = { Kind = "Bump", Add = Add } }
	local Note = Step(Current, { Writer = 1, Ack = Seq - 1, MustExist = false, Ops = { Op } }, Clock, Using)
	return Note.Stored or Current, Note
end

local function Newer(): unknown
	local Book = Writer.New()
	Writer.Var(Book, Total.FORMAT + 1)
	return { b = Writer.Finish(Book) }
end

local TIDY: Types.Request = { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Tidy = true }

local function Kinds(Asked: { Machine.Asked }): string
	local Found: { string } = {}
	for _, Each in Asked do
		table.insert(Found, Each.Ask.Kind)
	end
	return table.concat(Found, " ")
end

local function Holding(Shards: number): Total.Held
	return Total.New("Gold", "coins", Shards)
end

local function Start(Held: Total.Held, MaxAge: number?, At: number?)
	return Machine.Start(TotalCall.Machine, TotalCall.Context(Held, MaxAge or 60, 9, 0), At or NOW)
end

Describe("Totals", function()
	Test("a shard adds each bump to its sum, and refuses one that would take it past its share of 2^53", function()
		local Using = Shard(4)
		local Key = Bump(nil, 1, 5, Using)
		local After, Note = Bump(Key, 2, -2, Using)
		Expect((After :: any).s.Sum).toBe(3)
		Expect(Note.Fates[1]).toBe(0)
		local _, Refused = Bump(After, 3, Total.Max(4), Using)
		Expect(Refused.Fates[1]).toBe(1)
		Expect(Total.Max(4) * 4 <= 2 ^ 53 - 1).toBe(true)
	end)

	Test("a shard no bump made reads as 0 at write count 0, and a note carries the pair its run landed", function()
		local Empty = assert(Total.Pair(nil))
		Expect(Empty.Writes).toBe(0)
		Expect(Empty.Sum).toBe(0)
		local Using = Shard(2)
		local Key, Note = Bump(nil, 1, 7, Using)
		local Landed = assert(Total.Noted(Note))
		Expect(Landed.Writes).toBe(1)
		Expect(Landed.Sum).toBe(7)
		local Read = assert(Total.Pair(Key))
		Expect(Read.Writes).toBe(1)
		Expect(Read.Sum).toBe(7)
	end)

	Test("pairs merge by write count alone, and a total answers only once every shard has one", function()
		local Old: Total.Pair = { Writes = 3, Sum = 30 }
		local New: Total.Pair = { Writes = 4, Sum = 10 }
		Expect((Total.Merge(Old, New) :: Total.Pair).Sum).toBe(10)
		Expect((Total.Merge(New, Old) :: Total.Pair).Sum).toBe(10)
		Expect((Total.Merge(nil, Old) :: Total.Pair).Sum).toBe(30)
		Expect(Total.Sum({ [0] = Old }, 2)).toBeNil()
		Expect(Total.Sum({ [0] = Old, [1] = New }, 2)).toBe(40)
	end)

	Test("a game's name goes to one shard from every server, and a server's own bumps to its home shard", function()
		Expect(Total.Named("order-9", 16)).toBe(Total.Named("order-9", 16))
		local Home = Total.Home("coins", 5, 16)
		Expect(Home >= 0 and Home < 16).toBe(true)
		Expect(Total.Key("coins", 16, 3)).toBe("$T:coins:16:3")
	end)

	Test("the summary merges by write count, names its holder, and is not taken while another holder is ahead", function()
		local First = Total.Summary(nil, { [0] = { Writes = 2, Sum = 5 } }, 2, 7, NOW, NOW + 90)
		Expect((Total.Read(First, 2) :: Total.Pairs)[0].Sum).toBe(5)
		Expect(Total.Summary(First, { [1] = { Writes = 1, Sum = 9 } }, 2, 8, NOW + 10, NOW + 100)).toBeNil()
		local Mine = Total.Summary(First, { [0] = { Writes = 1, Sum = 99 }, [1] = { Writes = 1, Sum = -9 } }, 2, 7, NOW + 10, NOW + 100)
		local Held = Total.Read(Mine, 2) :: Total.Pairs
		Expect(Held[0].Sum).toBe(5)
		Expect(Held[1].Sum).toBe(-9)
		local Taken = Total.Summary(Mine, {}, 2, 8, NOW + 101, NOW + 191)
		Expect(Total.Summary(Taken, {}, 2, 7, NOW + 150, NOW + 240)).toBeNil()
		local Pairs = Total.Read(Taken, 2) :: Total.Pairs
		Expect(Total.Sum(Pairs, 2)).toBe(-4)
		Expect(Total.Read(Newer(), 2)).toBe("Behind")
		Expect(Total.Summary(Newer(), {}, 2, 7, NOW, NOW)).toBeNil()
		Expect(Total.Read({ b = "!" }, 2)).toBeNil()
		Expect(Total.Lapsed(Taken, NOW + 191, 0)).toBe(false)
		Expect(Total.Lapsed(Taken, NOW + 192, 0)).toBe(true)
		Expect(Total.Lapsed(nil, NOW, 0)).toBe(true)
	end)

	Test("a tidy drops what has aged off a shard and lands, cancels when nothing aged, and never makes a shard", function()
		local Using = Shard(2)
		local Key0 = Bump(nil, 1, 5, Using, NOW - Windows.PRUNE_AGE)
		Expect(Total.Untidy(Key0, NOW)).toBe(true)
		Expect(Total.Untidy(Key0, NOW - Windows.PRUNE_AGE + 10)).toBe(false)
		Expect(Step(Key0, TIDY, NOW - Windows.PRUNE_AGE + 10, Using).Stored).toBeNil()
		local Tidied = Step(Key0, TIDY, NOW, Using)
		local Found = Key.Read(Tidied.Stored) :: Key.Found
		Expect((next(Found.Book.Writers))).toBeNil()
		Expect((Found.State :: any).Sum).toBe(5)
		Expect(Total.Untidy(Tidied.Stored, NOW)).toBe(false)
		local Made = Step(nil, TIDY, NOW, Using)
		Expect(Made.Stored).toBeNil()
		Expect(Made.Why).toBe("Missing")
	end)

	Test("a shard's writer waits its gap past its last send, and moves the gap by the rate over half the ceiling", function()
		local Kept = Queue.New({ Store = "x", Key = "k" }, Shard(2), 3, nil, NOW)
		Expect(Kept.Gap).toBe(Windows.GAP_MAX)
		Queue.Push(Kept, { Form = "Minted", Kind = 0, MustExist = false, Body = { Add = 1 } })
		Expect(Queue.Wait(Kept, NOW)).toBe(0)
		Queue.Build(Kept, NOW)
		Expect(Queue.Wait(Kept, NOW + 10)).toBe(Windows.GAP_MAX - 10)
		Queue.Paced(Kept, 1, 200, NOW + 10)
		Expect(Kept.Gap).toBe(Windows.GAP_MAX)
		Queue.Paced(Kept, 2, 200, NOW + 70)
		Expect(Kept.Gap).toBe(Windows.GAP_MAX / 2)
		Queue.Paced(Kept, 2 + 4096, 200, NOW + 130)
		Expect(Kept.Gap).toBe(Windows.GAP_MAX)
		Queue.Paced(Kept, 4098, 200, NOW + 130)
		Expect(Kept.Landing and Kept.Landing.At).toBe(NOW + 130)
		Queue.Failed(Kept)
		Expect(Queue.Wait(Kept, NOW + 130)).toBe(0)
		local Plain = Queue.New({ Store = "x", Key = "k" }, Game.DEFAULT, 3, nil, NOW)
		Plain.Sent = NOW
		Expect(Queue.Wait(Plain, NOW)).toBe(0)
	end)

	Test("Save waits out a paced queue's gap, and after a failed request waits the retry gap and no more", function()
		local Kept = Queue.New({ Store = "x", Key = "k" }, Shard(2), 3, nil, NOW)
		Kept.Sent = NOW
		Queue.Push(Kept, { Form = "Minted", Kind = 0, MustExist = false, Body = { Add = 1 } })
		local Call, Asked = Machine.Start(Save.Machine, Save.Context(Kept), NOW)
		local Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Wait" then Ask.Seconds else -1).toBe(Windows.GAP_MAX)
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Done(NOW + Windows.GAP_MAX))
		Expect(Kinds(Asked)).toBe("Send")
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Failed(NOW + Windows.GAP_MAX, true))
		Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Wait" then Ask.Seconds else -1).toBe(Windows.RETRY_GAP)
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Done(NOW + Windows.GAP_MAX + 2))
		Expect(Kinds(Asked)).toBe("Send")
	end)

	Test("a total whose pairs are whole and young answers with no request", function()
		local Held = Holding(2)
		Held.Pairs[0], Held.Pairs[1], Held.Seen = { Writes = 1, Sum = 4 }, { Writes = 1, Sum = 6 }, NOW - 30
		local Call, Asked = Start(Held)
		Expect(#Asked).toBe(0)
		Expect(Machine.AnswerOf(Call)).toBe(10)
		Expect(Held.Called).toBe(NOW)
	end)

	Test("a whole summary item answers its sum, and a held lease takes nothing more", function()
		local Held = Holding(2)
		Held.Pairs[0] = { Writes = 5, Sum = 50 }
		local Item = Total.Summary(nil, { [0] = { Writes = 4, Sum = 40 }, [1] = { Writes = 2, Sum = 7 } }, 2, 3, NOW, NOW + Windows.LEASE)
		local Call, Asked = Start(Held, 0)
		Expect(Kinds(Asked)).toBe("Item")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item))
		Expect(#Asked).toBe(0)
		Expect(Machine.AnswerOf(Call)).toBe(57)
		Expect(Machine.IsFinal(Call)).toBe(true)
		Expect(Held.Seen).toBe(NOW)
		Expect(Held.Holding).toBe(false)
	end)

	Test("a lapsed holder makes the reader a taker that reads every shard and names itself, until it stops reading", function()
		local Using = Shard(2)
		local Shard0 = Bump(nil, 1, 5, Using)
		local Shard1 = Bump(nil, 1, 6, Using)
		local Held = Holding(2)
		local Item = Total.Summary(nil, { [0] = { Writes = 1, Sum = 5 }, [1] = { Writes = 1, Sum = 6 } }, 2, 3, NOW - 200, NOW - 110)
		local Call, Asked = Start(Held)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item))
		Expect(Machine.AnswerOf(Call)).toBe(11)
		Expect(Held.Holding).toBe(true)
		Expect(Kinds(Asked)).toBe("Read Read")
		Machine.Step(Call, Asked[1].Id, Heard.Read(Shard0))
		Asked = Machine.Step(Call, Asked[2].Id, Heard.Read(Shard1))
		local Ask = Asked[1].Ask
		local Wrote = if Ask.Kind == "Change" then Ask.Transform(Item) else error("not a change")
		Expect(Total.Lapsed(Wrote, NOW + Windows.LEASE, 0)).toBe(false)
		Expect(Total.Lapsed(Wrote, NOW + Windows.LEASE + 1, 0)).toBe(true)
		Expect(Total.Summary(Wrote, {}, 2, 3, NOW + 1, NOW + 91)).toBeNil()
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Wrote))
		Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Wait" then Ask.Seconds else -1).toBe(Windows.REFRESH)
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Done(NOW + Windows.REFRESH))
		Expect(Kinds(Asked)).toBe("Read Read")
		Machine.Step(Call, Asked[1].Id, Heard.Read(Shard0))
		Asked = Machine.Step(Call, Asked[2].Id, Heard.Read(Shard1))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Wrote))
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Done(NOW + Windows.HOLDING + 1))
		Expect(#Asked).toBe(0)
		Expect(Machine.IsFinal(Call)).toBe(true)
		Expect(Held.Holding).toBe(false)
	end)

	Test("a second reader on a server that holds the total takes nothing, and a lost refresh lets the lease go", function()
		local Held = Holding(1)
		Held.Holding = true
		local Item = Total.Summary(nil, { [0] = { Writes = 1, Sum = 5 } }, 1, 3, NOW - 200, NOW - 110)
		local Call, Asked = Start(Held)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item))
		Expect(Machine.AnswerOf(Call)).toBe(5)
		Expect(#Asked).toBe(0)
		Expect(Held.Holding).toBe(true)
		local Other = Holding(1)
		Call, Asked = Start(Other)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Expect(Machine.AnswerOf(Call)).toBe(0)
		Expect(Kinds(Asked)).toBe("Change")
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Expect(#Asked).toBe(0)
		Expect(Other.Holding).toBe(false)
	end)

	Test("with the map down a server answers from shards it read lately, else reads every shard, and a shard it never read is Unresolved", function()
		local Held = Holding(2)
		Held.Pairs[0], Held.Pairs[1] = { Writes = 1, Sum = 4 }, { Writes = 1, Sum = 6 }
		Held.Read[0], Held.Read[1] = NOW - 10, NOW - 10
		local Call, Asked = Start(Held, 0)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Failed())
		Expect(#Asked).toBe(0)
		Expect(Machine.AnswerOf(Call)).toBe(10)
		Held.Read[1] = NOW - Windows.DOWN - 1
		Call, Asked = Start(Held, 0)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Failed())
		Expect(Kinds(Asked)).toBe("Read Read")
		Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Machine.Step(Call, Asked[2].Id, Heard.Failed())
		Expect(Machine.AnswerOf(Call)).toBe(10)
		local Fresh = Holding(2)
		Call, Asked = Start(Fresh, 0)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Failed())
		Machine.Step(Call, Asked[1].Id, Heard.Read(nil))
		Machine.Step(Call, Asked[2].Id, Heard.Failed())
		Expect(Machine.AnswerOf(Call)).toBe("Unresolved")
	end)

	Test("an item that lacks a shard reads only that shard, and a newer item answers Behind", function()
		local Held = Holding(2)
		local Item = Total.Summary(nil, { [1] = { Writes = 3, Sum = 9 } }, 2, 3, NOW, NOW + Windows.LEASE)
		local Call, Asked = Start(Held)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item))
		Expect(Kinds(Asked)).toBe("Read")
		local Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Read" then Ask.Ref.Key else "").toBe("$T:coins:2:0")
		Machine.Step(Call, Asked[1].Id, Heard.Read(Bump(nil, 1, 2, Shard(2))))
		Expect(Machine.AnswerOf(Call)).toBe(11)
		Call, Asked = Start(Holding(2))
		Machine.Step(Call, Asked[1].Id, Heard.Read(Newer()))
		Expect(Machine.AnswerOf(Call)).toBe("Behind")
	end)

	Test("a shard read with an entry a day old gets one tidy after the answer, and not again within the day", function()
		local Old = Bump(nil, 1, 5, Shard(1), NOW - Windows.PRUNE_AGE)
		local Held = Holding(1)
		local Item = Total.Summary(nil, {}, 1, 3, NOW, NOW + Windows.LEASE)
		local Call, Asked = Start(Held, 0)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Old))
		Expect(Machine.AnswerOf(Call)).toBe(5)
		local Ask = Asked[1].Ask
		Expect(if Ask.Kind == "Send" then Ask.Request.Tidy else false).toBe(true)
		Machine.Step(Call, Asked[1].Id, Heard.Sent({}))
		Expect(Machine.IsFinal(Call)).toBe(true)
		Held.Pairs[0] = nil
		Call, Asked = Start(Held, 0)
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Item))
		Asked = Machine.Step(Call, Asked[1].Id, Heard.Read(Old))
		Expect(#Asked).toBe(0)
	end)
end)

return nil
