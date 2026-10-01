--!strict

--[=[

	Queue: The cases for Record/Queue, against the real Step.

	Land builds the queue's request, runs it on a key as the datastore would, and learns the note.
	Aged is a key that forgot every stamp at or below NOW. Another writer landed on it 200 seconds
	later.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Answer = require("../src/Core/Answer")
local Book = require("../src/Record/Book")
local Game = require("./Gold")
local Limits = require("../src/Core/Constants/Limits")
local Queue = require("../src/Record/Queue")
local Step = require("../src/Record/Step")
local Types = require("../src/Record/Types")

local Describe, Test, Expect, Similar = Testing.Describe, Testing.Test, Testing.Expect, Testing.Similar

type Held = Queue.Queue

local NOW = Game.NOW
local Fate = Book.Fate

local function Asked(Add: number, Change: { [string]: any }?): Queue.Asked
	local Made: { [string]: any } = { Form = "Minted", Kind = 0, MustExist = false, Body = { Add = Add } }
	for Field, Value in Change or {} do
		Made[Field] = Value
	end
	return Made :: any
end

local function New(Id: number): Held
	return Queue.New({ Store = "Gold", Key = "42" }, Game.DEFAULT, Id, nil, NOW)
end

local function Runs(Request: Types.Request, Clock: number, ...: unknown): (Types.Note, { [number]: true }, unknown)
	local Ran: { [number]: true } = {}
	local Note: Types.Note? = nil
	local After: unknown = nil
	for Index = 1, select("#", ...) do
		local Key = select(Index, ...)
		Note = Step(Key, Request, Clock, Game.DEFAULT)
		for _, Seq in (Note :: Types.Note).Decided do
			Ran[Seq] = true
		end
		After = if (Note :: Types.Note).Stored ~= nil then (Note :: Types.Note).Stored else Key
	end
	return Note :: Types.Note, Ran, After
end

local function Land(Kept: Held, Key: unknown, Clock: number?): (unknown, { Queue.Fate })
	local At = Clock or NOW
	local Request = assert(Queue.Build(Kept, At))
	local Note, Ran, After = Runs(Request, At, Key)
	return After, Queue.Learn(Kept, Request, Note, Ran, At)
end

local function Replies(Said: { Queue.Fate }): { any }
	local Found = {}
	for _, Each in Said do
		table.insert(Found, Each.Reply)
	end
	return Found
end

local function Made(Create: string?): unknown
	local Maker = New(2)
	local Item = assert(Queue.Push(Maker, Asked(1)))
	Item.Create = Create
	return (Land(Maker, nil, NOW))
end

local function Aged(): unknown
	local First = New(2)
	Queue.Push(First, Asked(1))
	local Key = Land(First, nil)
	local Later = New(3)
	Queue.Push(Later, Asked(1))
	return (Land(Later, Key, NOW + 200))
end

Describe("Queue", function()
	Test("a request carries every unheard op in order, one request is out at a time, and each op is answered once", function()
		local Kept = New(1)
		Queue.Push(Kept, Asked(5))
		Queue.Push(Kept, Asked(-9))
		Queue.Push(Kept, Asked(2))
		local Request = assert(Queue.Build(Kept, NOW))
		Expect(#Request.Ops).toBe(3)
		Expect(Request.Ops[3].Seq).toBe(3)
		Expect(Queue.Build(Kept, NOW)).toBeNil()
		local Note, Ran, Key = Runs(Request, NOW, nil)
		Expect(Replies(Queue.Learn(Kept, Request, Note, Ran, NOW))).toBe(Similar({ true, Answer.Refused, true }))
		Expect(Game.Gold(Key)).toBe(7)
		Expect(Queue.Ack(Kept)).toBe(3)
	end)

	Test("a clean minted op the key forgot gets a stamp past the horizon and takes when sent again", function()
		local Kept = New(1)
		local Item = assert(Queue.Push(Kept, Asked(1)))
		local Key, Said = Land(Kept, Aged())
		Expect(#Said).toBe(0)
		Expect(Item.Stamp).toBe(NOW + 1)
		local _, Again = Land(Kept, Key)
		Expect(Replies(Again)).toBe(Similar({ true }))
	end)

	Test("an op a run decided is never answered no by a later run that found it forgotten", function()
		local Kept = New(1)
		Queue.Push(Kept, Asked(1))
		local Request = assert(Queue.Build(Kept, NOW))
		local Note, Ran = Runs(Request, NOW, nil, Aged())
		Expect(Note.Stored).toBeNil()
		Expect(Replies(Queue.Learn(Kept, Request, Note, Ran, NOW))).toBe(Similar({ Answer.Unresolved }))
	end)

	Test("an op a failed reply carried answers Unresolved once and is still sent", function()
		local Kept = New(1)
		Queue.Push(Kept, Asked(1))
		Queue.Build(Kept, NOW)
		Expect(Replies(Queue.Failed(Kept))).toBe(Similar({ Answer.Unresolved }))
		local _, Later = Land(Kept, nil)
		Expect(#Later).toBe(0)
		Expect(#Kept.Items).toBe(0)
	end)

	Test("a landed write turns away a queued hopeful op judged before the key's last cut", function()
		local Key = Made()
		local Record = Game.Record(Key)
		Record.Cuts = 1
		Key = { s = (Key :: any).s, b = Record:Encode(NOW) }

		local Session = New(1)
		Queue.Push(Session, Asked(1, { Form = "Hopeful", View = 1 }))
		local Request = assert(Queue.Build(Session, NOW))
		Queue.Push(Session, Asked(1, { Form = "Hopeful", View = 0 }))
		local Note, Ran = Runs(Request, NOW, Key)
		local Said = Queue.Learn(Session, Request, Note, Ran, NOW)
		Expect(Replies(Said)).toBe(Similar({ true, Answer.Refused }))
		Expect(Said[2].Code).toBe(Fate.Turned)
	end)

	Test("a clean op judged for no key is sent again for the incarnation the key holds", function()
		local Key = Made("k9")
		local Kept = New(1)
		local Item = assert(Queue.Push(Kept, Asked(1)))
		Item.Create = "zz"
		Key = Land(Kept, Key, NOW)
		Expect(Item.Id).toBe("k9")
		local _, Said = Land(Kept, Key)
		Expect(Replies(Said)).toBe(Similar({ true }))
	end)

	Test("on an erasable store an op takes the key's id at its first send, or a create when the key read absent", function()
		local Kept = Queue.New({ Store = "Gold", Key = "42" }, Game.Build({ Erasable = true }), 5, nil, NOW)
		Expect(Queue.Unknown(Kept)).toBe(true)
		Queue.Know(Kept, nil)
		Expect(Queue.Unknown(Kept)).toBe(false)
		Queue.Push(Kept, Asked(1))
		local First = assert(Queue.Build(Kept, NOW))
		Expect(First.Ops[1].Create).toBe(Book.Incarnation(5, 1))
		Expect(First.Ops[1].Id).toBeNil()
		local Key = assert(Step(nil, First, NOW, Game.DEFAULT).Stored)
		Queue.Learn(Kept, First, Step(nil, First, NOW, Game.DEFAULT), {}, NOW)
		Expect(Kept.Seen).toBe(Book.Incarnation(5, 1))
		Queue.Push(Kept, Asked(2))
		local Second = assert(Queue.Build(Kept, NOW))
		Expect(Second.Ops[1].Id).toBe(Book.Incarnation(5, 1))
		Queue.Know(Kept, Key)
		Expect(Kept.Seen).toBe(Book.Incarnation(5, 1))
	end)

	Test("once a request that carried a create may have written, the op carries that id and makes no key", function()
		local Kept = Queue.New({ Store = "Gold", Key = "42" }, Game.Build({ Erasable = true }), 5, nil, NOW)
		Queue.Know(Kept, nil)
		local Item = assert(Queue.Push(Kept, Asked(1)))
		assert(Queue.Build(Kept, NOW))
		Queue.Failed(Kept)
		Expect(Item.Create).toBeNil()
		Expect(Item.Id).toBe(Book.Incarnation(5, 1))
		local Again = assert(Queue.Build(Kept, NOW))
		Expect(Again.Ops[1].Id).toBe(Book.Incarnation(5, 1))
		Expect(Step(nil, Again, NOW, Game.DEFAULT).Stored).toBeNil()
	end)

	Test("only an op that was never sent can be withdrawn", function()
		local Kept = New(1)
		local Sent = assert(Queue.Push(Kept, Asked(1)))
		Queue.Build(Kept, NOW)
		local Waiting = assert(Queue.Push(Kept, Asked(2)))
		Expect(Queue.Withdraw(Kept, Sent)).toBe(false)
		Expect(Queue.Withdraw(Kept, Waiting)).toBe(true)
		Expect(#Kept.Items).toBe(1)
	end)

	Test("an op a mark blocks waits, and takes in the request that carries the mark's end, which is then dropped", function()
		local Mark = { Name = Book.Drawn(9, 1), Stamp = NOW, Attempt = 1, Decider = { Store = "Gold", Key = "d" }, Leg = { Body = { Add = 1 } } }
		local Key = Step(nil, { Writer = 0, Ack = 0, MustExist = false, Ops = {}, Tent = Mark }, NOW, Game.DEFAULT).Stored
		local Kept = New(1)
		Queue.Push(Kept, Asked(5))
		local Held, Said = Land(Kept, Key)
		Expect(#Said).toBe(0)
		Expect(#Kept.Items).toBe(1)
		Queue.Ride(Kept, { Name = Mark.Name, Stamp = NOW, Attempt = 1, Outcome = "Abort" })
		local After, Later = Land(Kept, Held)
		Expect(Replies(Later)).toBe(Similar({ true }))
		Expect(Game.Gold(After)).toBe(5)
		Expect(Game.Record(After).Work[Mark.Name]).toBeNil()
		Expect(#Kept.Rides).toBe(0)
	end)

	Test("past SEQ_MAX an op waits unnumbered until every numbered op is heard, and a renewed queue counts from 1", function()
		local Kept = New(1)
		Kept.Next = Limits.SEQ_MAX
		Queue.Push(Kept, Asked(1))
		local Waiting = assert(Queue.Push(Kept, Asked(2)))
		local Request = assert(Queue.Build(Kept, NOW))
		Expect(#Request.Ops).toBe(1)
		Expect(Request.Ops[1].Seq).toBe(Limits.SEQ_MAX)
		Expect(Waiting.Seq).toBeNil()
		local Note, Ran, Key = Runs(Request, NOW, nil)
		Expect(Replies(Queue.Learn(Kept, Request, Note, Ran, NOW))).toBe(Similar({ true }))
		Expect(Queue.Spent(Kept)).toBe(true)
		Expect(Queue.Build(Kept, NOW)).toBeNil()
		Queue.Renew(Kept, 2)
		local After, Said = Land(Kept, Key)
		Expect(Replies(Said)).toBe(Similar({ true }))
		Expect(Waiting.Seq).toBe(1)
		Expect(Game.Gold(After)).toBe(3)
	end)
end)

return nil
