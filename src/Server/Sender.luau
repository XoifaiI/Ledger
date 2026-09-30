--!strict
--!optimize 2

--[=[

	Sender: The machine that sends one key's Writer until it is empty, one request at a time.

	Queue adds an op without sending, and Flush starts the machine on the next frame, so ops queued
	together go in one request. Push does both for an op whose caller waits on its reply. After an
	answer the machine sends again, rests as Backoff says when the answer settled nothing, and stops
	when the writer is empty. Wait gives an op's reply. An op still unsent after Windows.SHED seconds
	is withdrawn and answers Busy, and one without a fate after Windows.ANSWER answers Unresolved.
	Heard gets every fate, Landed the note of every write that landed, and Emptied a signal each time
	the writer runs empty.

	Return type: The Sender class, with New and the Sending machine, and the methods Queue, Flush,
	Push and Wait.
	Example usage:
		local Reply, Code = Key:Wait(Key:Push(Asked))
--]=]

local Answer = require("../Core/Answer")
local Backoff = require("./Backoff")
local Clock = require("./Clock")
local DataStore = require("../Adapters/DataStore")
local Driver = require("./Driver")
local Effect = require("./Effect")
local Future = require("../Util/Future")
local Machine = require("../Core/Machine")
local Observer = require("../Util/Observer")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")
local Writer = require("./Writer")

type Reply = Writer.Reply
type Item = Writer.Item
type Settle = (Reply, number?) -> ()

type SenderImpl = {
	__index: SenderImpl,
	New: (Store: DataStore.Store, Name: string, Build: Types.Build, Number: number, UserIds: { number }?) -> Sender,
	Sending: Machine.Machine<Sender, Effect.Effect, boolean, (boolean, unknown, DataStoreKeyInfo?, boolean?)>,
	Queue: (self: Sender, Asked: Writer.Asked) -> Item?,
	Flush: (self: Sender) -> (),
	Push: (self: Sender, Asked: Writer.Asked) -> Item?,
	Wait: (self: Sender, Item: Item?) -> (Reply, number?),
}

type Data = {
	read Store: DataStore.Store,
	read Name: string,
	read Build: Types.Build,
	read UserIds: { number }?,
	read Writer: Writer.Writer,
	read Settles: { [Item]: Settle },
	read Jobs: { [Item]: Future.Future<Reply, number?> },
	read Heard: Observer.Observer<Writer.Heard>,
	read Landed: Observer.Observer<Types.Note>,
	read Emptied: Observer.Observer<boolean>,
	Running: boolean,
	Idle: number,
}

export type Sender = setmetatable<Data, SenderImpl>

type Call = Effect.Call<Sender, boolean>

local STATE: {
	read Sending: "Sending",
	read Resting: "Resting",
	read Done: "Done",
} = {
	Sending = "Sending",
	Resting = "Resting",
	Done = "Done",
}

local Sender = {} :: SenderImpl
Sender.__index = Sender

local function Tell(Owner: Sender, Said: { Writer.Heard })
	for _, Each in Said do
		Owner.Heard:Push(Each)
		local Settle = Owner.Settles[Each.Item]
		if Settle then
			Owner.Settles[Each.Item] = nil
			task.defer(Settle, Each.Reply, Each.Code)
		end
	end
end

local function Stop(Owner: Sender): string?
	if Owner.Writer.Items[1] then
		return nil
	end
	Owner.Running = false
	Owner.Emptied:Push(true)
	return STATE.Done
end

local function Send(Call: Call)
	local Owner = Call.Context
	local Sent = assert(Owner.Writer:Send(Clock.Now()), "Sender: nothing to send")
	local Transform = Writer.Transform(Sent, Owner.Build, Clock.Now)
	Machine.Send(Call, Effect.Update(Owner.Store, Owner.Name, Transform, Owner.UserIds))
end

local function Answered(Call: Call, Ok: boolean): string?
	local Owner = Call.Context
	local Sent = Owner.Writer.Out :: Writer.Sent
	local Said = if Ok then Owner.Writer:Heard(Clock.Now()) else Owner.Writer:Failed()
	Tell(Owner, Said)
	local Note = Sent.Note
	if Ok and Sent.Landed and Note then
		Owner.Landed:Push(Note)
	end
	Owner.Idle = if Ok and (Sent.Landed or #Said > 0) then 0 else Owner.Idle + 1
	return Stop(Owner) or if Owner.Idle == 0 then STATE.Sending else STATE.Resting
end

local function Rest(Call: Call)
	Machine.Send(Call, Effect.Wait(Backoff(Call.Context.Idle)))
end

local function Rested(Call: Call): string?
	return Stop(Call.Context) or STATE.Sending
end

local SPEC: Effect.Spec<Sender, boolean> = {
	Name = "Sender",
	Initial = STATE.Sending,
	States = {
		[STATE.Sending] = { To = { STATE.Sending, STATE.Resting, STATE.Done }, Enter = Send, On = Answered },
		[STATE.Resting] = { To = { STATE.Sending, STATE.Done }, Enter = Rest, On = Rested },
		[STATE.Done] = {},
	},
}

Sender.Sending = Machine.Define(SPEC)

local function Start(Owner: Sender)
	Driver.Run(Sender.Sending, Owner)
end

function Sender.New(Store: DataStore.Store, Name: string, Build: Types.Build, Number: number, UserIds: { number }?): Sender
	local Fresh: Data = {
		Store = Store,
		Name = Name,
		Build = Build,
		UserIds = UserIds,
		Writer = Writer.New(Number, Build.TimedRoom),
		Settles = {},
		Jobs = {},
		Heard = Observer.New(),
		Landed = Observer.New(),
		Emptied = Observer.New(),
		Running = false,
		Idle = 0,
	}
	return setmetatable(Fresh, Sender)
end

function Sender.Queue(self: Sender, Asked: Writer.Asked): Item?
	return self.Writer:Push(Asked)
end

function Sender.Flush(self: Sender)
	if not self.Running and self.Writer.Items[1] then
		self.Running = true
		task.defer(Start, self)
	end
end

function Sender.Push(self: Sender, Asked: Writer.Asked): Item?
	local Item = self:Queue(Asked)
	if Item == nil then
		return nil
	end
	local Job, Settle = Future.Pending()
	self.Settles[Item], self.Jobs[Item] = Settle, Job
	self:Flush()
	return Item
end

function Sender.Wait(self: Sender, Item: Item?): (Reply, number?)
	local Job = if Item then self.Jobs[Item] else nil
	if Item == nil or Job == nil then
		return Answer.Busy, nil
	end
	self.Jobs[Item] = nil
	local Reply, Code = Job:Wait(Windows.SHED)
	if Reply ~= nil then
		return Reply, Code
	elseif self.Writer:Withdraw(Item) then
		self.Settles[Item] = nil
		return Answer.Busy, nil
	end
	Reply, Code = Job:Wait(Windows.ANSWER - Windows.SHED)
	return Reply or Answer.Unresolved, Code
end

return Sender
