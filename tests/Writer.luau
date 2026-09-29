--!strict

--[=[

	Writer: The cases for Server/Writer, against the real Step.

	Land sends the writer's request, runs its transform on a key as the datastore would, and hears the
	answer. Aged is a key that forgot every stamp at or below NOW, since another writer landed 200
	seconds later.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Answer = require("../src/Core/Answer")
local Book = require("../src/Record/Book")
local Game = require("./Gold")
local Sizes = require("../src/Core/Constants/Sizes")
local Writer = require("../src/Server/Writer")

local Describe, Test, Expect, Similar = Testing.Describe, Testing.Test, Testing.Expect, Testing.Similar

type Heard = Writer.Heard
type Queue = Writer.Writer

local NOW = Game.NOW
local Fate = Book.Fate

local function Asked(Add: number, Change: { [string]: any }?): Writer.Asked
	local Made: { [string]: any } = { Form = "Minted", Kind = 0, MustExist = false, Body = { Add = Add } }
	for Field, Value in Change or {} do
		Made[Field] = Value
	end
	return Made :: any
end

local function New(Id: number): Queue
	return Writer.New(Id, Sizes.TIMED_ROOM)
end

local function Run(Sent: Writer.Sent, Key: unknown, Clock: number): unknown
	local Value = Writer.Transform(Sent, Game.DEFAULT, function()
		return Clock
	end)(Key)
	return if Value ~= nil then Value else Key
end

local function Land(Queue: Queue, Key: unknown, Clock: number?, Create: string?): (unknown, { Heard })
	local At = Clock or NOW
	local After = Run(assert(Writer.Send(Queue, At, nil, Create)), Key, At)
	return After, Writer.Heard(Queue, At)
end

local function Replies(Said: { Heard }): { any }
	local Found = {}
	for _, Each in Said do
		table.insert(Found, Each.Reply)
	end
	return Found
end

local function Made(Create: string?): unknown
	local Maker = New(2)
	Writer.Push(Maker, Asked(1), NOW)
	return (Land(Maker, nil, NOW, Create))
end

local function Aged(): unknown
	local First = New(2)
	Writer.Push(First, Asked(1), NOW)
	local Key = Land(First, nil)
	local Later = New(3)
	Writer.Push(Later, Asked(1), NOW + 200)
	return (Land(Later, Key, NOW + 200))
end

Describe("Writer", function()
	Test("a request carries every unheard op in order, one request is out at a time, and each op is answered once", function()
		local Queue = New(1)
		Writer.Push(Queue, Asked(5), NOW)
		Writer.Push(Queue, Asked(-9), NOW)
		Writer.Push(Queue, Asked(2), NOW)
		local Sent = assert(Writer.Send(Queue, NOW))
		Expect(#Sent.Request.Ops).toBe(3)
		Expect(Sent.Request.Ops[3].Seq).toBe(3)
		Expect(Writer.Send(Queue, NOW)).toBeNil()
		local Key = Run(Sent, nil, NOW)
		Expect(Replies(Writer.Heard(Queue, NOW))).toBe(Similar({ true, Answer.Refused, true }))
		Expect(Game.Gold(Key)).toBe(7)
		Expect(Writer.Ack(Queue)).toBe(3)
	end)

	Test("a clean minted op the key forgot gets a stamp past the horizon and takes when sent again", function()
		local Queue = New(1)
		local Item = assert(Writer.Push(Queue, Asked(1), NOW))
		local Key, Said = Land(Queue, Aged())
		Expect(#Said).toBe(0)
		Expect(Item.Stamp).toBe(NOW + 1)
		local _, Again = Land(Queue, Key)
		Expect(Replies(Again)).toBe(Similar({ true }))
	end)

	Test("an op a run decided is never answered no by a later run that found it forgotten", function()
		local Queue = New(1)
		Writer.Push(Queue, Asked(1), NOW)
		local Sent = assert(Writer.Send(Queue, NOW))
		Run(Sent, nil, NOW)
		Run(Sent, Aged(), NOW)
		Expect(Sent.Landed).toBe(false)
		Expect(Replies(Writer.Heard(Queue, NOW))).toBe(Similar({ Answer.Unresolved }))
	end)

	Test("an op answers Unresolved once after three failed requests and is still sent", function()
		local Queue = New(1)
		Writer.Push(Queue, Asked(1), NOW)
		local Said: { Heard } = {}
		for _ = 1, 3 do
			Writer.Send(Queue, NOW)
			Said = Writer.Failed(Queue)
		end
		Expect(Replies(Said)).toBe(Similar({ Answer.Unresolved }))
		local _, Later = Land(Queue, nil)
		Expect(#Later).toBe(0)
		Expect(#Queue.Items).toBe(0)
	end)

	Test("a landed write turns away a queued hopeful op judged before the key's last cut", function()
		local Key = Made()
		local Kept = Game.Record(Key)
		Kept.Cuts = 1
		Key = { s = (Key :: any).s, b = Book.Encode(Kept, NOW) }

		local Session = New(1)
		Writer.Push(Session, Asked(1, { Form = "Hopeful", View = 1 }), NOW)
		local Sent = assert(Writer.Send(Session, NOW))
		Writer.Push(Session, Asked(1, { Form = "Hopeful", View = 0 }), NOW)
		Run(Sent, Key, NOW)
		local Said = Writer.Heard(Session, NOW)
		Expect(Replies(Said)).toBe(Similar({ true, Answer.Refused }))
		Expect(Said[2].Code).toBe(Fate.Turned)
	end)

	Test("a clean op judged for no key is sent again for the incarnation the key holds", function()
		local Key = Made("k9")
		local Queue = New(1)
		local Item = assert(Writer.Push(Queue, Asked(1), NOW))
		Key = Land(Queue, Key, NOW, "zz")
		Expect(Item.Id).toBe("k9")
		local _, Said = Land(Queue, Key)
		Expect(Replies(Said)).toBe(Similar({ true }))
	end)

	Test("a durable op not sent in time is shed Busy, and one out too long answers Unresolved", function()
		local Queue = New(1)
		Writer.Push(Queue, Asked(1), NOW)
		Writer.Send(Queue, NOW)
		Writer.Push(Queue, Asked(2), NOW)
		Expect(Replies(Writer.Shed(Queue, NOW + 10))).toBe(Similar({ Answer.Busy }))
		Expect(#Queue.Items).toBe(1)
		Expect(Replies(Writer.Overdue(Queue, NOW + 30))).toBe(Similar({ Answer.Unresolved }))
		Expect(#Writer.Overdue(Queue, NOW + 60)).toBe(0)
	end)
end)

return nil
