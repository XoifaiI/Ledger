--!strict
--!optimize 2

--[=[

	Runner: Plumbing. Runs a machine, and carries out every ask it makes.

	A Send runs Step inside one UpdateAsync on the key's store. Each run keeps its note, notes
	whether it returned a write, and adds the op numbers it decided. A Read is one GetAsync. A call
	that fails waits as Backoff says and is made again with a fresh transform, and after
	Limits.TRIES failures the reply says Failed. A Send that failed may have written, so its reply
	says so. A Count adds 1 to its counter key, and hears the count only when its own write made it.
	A Run runs the other machine to its end and hears its answer. The runner decides nothing. Places
	gives the store and build of each store name a ref names. Run's future settles once, with the
	machine's first answer, or nil at its final state.

	Return type: A table with Run.
	Example usage:
		local End = Runner.Run(Unblock.Machine, Unblock.Context(Found, Stamp, ""), Places):Wait()
--]=]

local Asks = require("./Asks")
local Backoff = require("../Machine/Backoff")
local Clock = require("../Machine/Clock")
local DataStore = require("../Adapters/DataStore")
local Future = require("../Util/Future")
local Limits = require("../Core/Constants/Limits")
local Machine = require("./Machine")
local Names = require("../Core/Constants/Names")
local Step = require("../Record/Step")

type Ask = Asks.Ask
type Heard = Asks.Heard
type Places = { [string]: Asks.Place }

local Runner = {}

local function Send(Place: Asks.Place, Key: string, Request: any, UserIds: { number }?): Heard
	local Wrote = false
	local Ran: { [number]: true } = {}
	for Try = 1, Limits.TRIES do
		local Note = nil
		local function Transform(Current: unknown, _: DataStoreKeyInfo?): unknown
			Note = Step(Current, Request, Clock.Now(), Place.Build)
			for _, Seq in Note.Decided do
				Ran[Seq] = true
			end
			Wrote = Wrote or Note.Stored ~= nil
			return Note.Stored
		end
		local Ok = DataStore.Update(Place.Store, Key, Transform, UserIds)
		if Ok and Note then
			return Asks.Noted(Note, Clock.Now(), Wrote, Ran)
		end
		Wrote = true
		if Try < Limits.TRIES then
			task.wait(Backoff(Try))
		end
	end
	return Asks.Failed(Clock.Now(), Wrote)
end

local function Read(Place: Asks.Place, Key: string): Heard
	for Try = 1, Limits.TRIES do
		local Ok, Value = DataStore.Get(Place.Store, Key)
		if Ok then
			return Asks.Got(Value, Clock.Now())
		elseif Try < Limits.TRIES then
			task.wait(Backoff(Try))
		end
	end
	return Asks.Failed(Clock.Now(), false)
end

local function Bump(Current: unknown, _: DataStoreKeyInfo?): unknown
	if Current == nil then
		return 1
	elseif type(Current) == "number" and Current % 1 == 0 and Current >= 0 then
		return Current + 1
	end
	return nil
end

local function Count(Index: number): Heard
	local Counters = DataStore.Open(Names.NUMBERS)
	for Try = 1, Limits.TRIES do
		local Ok, Value, _, Wrote = DataStore.Update(Counters, `n{Index}`, Bump)
		if Ok and Wrote and type(Value) == "number" then
			return Asks.Got(Value, Clock.Now())
		elseif Try < Limits.TRIES then
			task.wait(Backoff(Try))
		end
	end
	return Asks.Failed(Clock.Now(), true)
end

local function Carry(Asking: Ask, Places: Places): Heard
	if Asking.Kind == "Wait" then
		task.wait(Asking.Seconds)
		return Asks.Done(Clock.Now())
	elseif Asking.Kind == "Run" then
		return Asks.Done(Clock.Now(), Runner.Run(Asking.Machine, Asking.Context, Places):Wait())
	elseif Asking.Kind == "Count" then
		return Count(Asking.Index)
	end
	local Place = Places[Asking.Ref.Store]
	if Place == nil then
		return Asks.Failed(Clock.Now(), false)
	elseif Asking.Kind == "Send" then
		return Send(Place, Asking.Ref.Key, Asking.Request, Asking.UserIds)
	end
	return Read(Place, Asking.Ref.Key)
end

function Runner.Run<Context, Answer>(Of: Machine.Machine<Context, Answer>, Context: Context, Places: Places): Future.Future<Answer?>
	local Job, Settle = Future.Pending()
	local Call, Asked = Machine.Start(Of, Context, Clock.Now())
	local Told = false
	local Drive: (Asked: { Machine.Asked }) -> ()

	local function Answer(Each: Machine.Asked)
		Drive(Machine.Step(Call, Each.Id, Carry(Each.Ask, Places)))
	end

	function Drive(Made: { Machine.Asked })
		if not Told and (Call.Answered or Machine.IsFinal(Call)) then
			Told = true
			Settle(Machine.AnswerOf(Call))
		end
		for _, Each in Made do
			task.spawn(Answer, Each)
		end
	end

	Drive(Asked)
	return Job
end

return Runner
