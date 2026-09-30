--!strict
--!optimize 2

--[=[

	Driver: Runs a machine. It carries out each effect and steps the machine with the reply.

	The driver decides nothing. Its future settles once, with the machine's first answer, or nil at
	its final state.

	Return type: A table with Run.
	Example usage:
		local Number = Driver.Run(Numbers.Take, Numbers.Context(Store, game.JobId)):Wait()
--]=]

local DataStore = require("../Adapters/DataStore")
local Effect = require("./Effect")
local Future = require("../Util/Future")
local Machine = require("../Core/Machine")

type Effect = Effect.Effect

local Driver = {}

function Driver.Run<Context, Answer>(Of: Machine.Machine<Context, Effect, Answer, (boolean, unknown, DataStoreKeyInfo?, boolean?)>, Context: Context): Future.Future<Answer?>
	local Job, Settle = Future.Pending()
	local Call, Effects, First = Machine.Start(Of, Context)
	local Told = false
	local Drive: (Sent: { Effect }, From: number) -> ()

	local function Carry(Id: number, Sent: Effect)
		if Sent.Kind == Effect.Kind.Get then
			Drive(Machine.Step(Call, Id, DataStore.Get(Sent.Store, Sent.Key, Sent.Options)))
		elseif Sent.Kind == Effect.Kind.Update then
			Drive(Machine.Step(Call, Id, DataStore.Update(Sent.Store, Sent.Key, Sent.Transform, Sent.UserIds)))
		elseif Sent.Kind == Effect.Kind.Wait then
			task.wait(Sent.Seconds)
			Drive(Machine.Step(Call, Id, true))
		end
	end

	function Drive(Sent: { Effect }, From: number)
		if not Told and (Call.Answered or Machine.IsFinal(Call)) then
			Told = true
			Settle(Machine.AnswerOf(Call))
		end
		for Offset, Each in table.clone(Sent) do
			task.spawn(Carry, From + Offset - 1, Each)
		end
	end

	Drive(Effects, First)
	return Job
end

return Driver
