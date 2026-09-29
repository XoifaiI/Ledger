--!strict
--!optimize 2

--[=[

	Driver: Runs a machine against the datastore, and settles a future with its answer.

	The driver makes the call each effect asks for on a thread of its own, and steps the machine with
	the reply. The future settles once, when the machine first answers or reaches a final state with
	no answer. The machine may go on after it answers, and the driver carries on until it is final.

	Return type: A table with Run.
	Example usage:
		local Driver = require("./Driver")
		local Number = Driver.Run(Numbers.Take, Numbers.Context(Store, game.JobId)):Wait()
--]=]

local DataStore = require("../Adapters/DataStore")
local Effect = require("./Effect")
local Future = require("../Util/Future")
local Machine = require("../Core/Machine")

type Effect = Effect.Effect

local function Run<Context, Answer>(Of: Machine.Machine<Context, Effect, Answer, (boolean, unknown, DataStoreKeyInfo?, boolean?)>, Context: Context): Future.Future<Answer?>
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
		if not Told and (Call.Answer ~= nil or Machine.IsFinal(Call)) then
			Told = true
			Settle(Call.Answer)
		end
		for Offset, Each in table.clone(Sent) do
			task.spawn(Carry, From + Offset - 1, Each)
		end
	end

	Drive(Effects, First)
	return Job
end

return table.freeze({
	Run = Run,
})
