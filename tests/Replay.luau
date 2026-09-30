--!strict

--[=[

	Replay: Runs a machine to its end by answering each ask as it is made, at the time given.

	A Send runs Step with the build given on the key held in Keys, and keeps what it wrote. A Read
	gets the key, a Wait gets done, a Count counts 1, and a Run runs the other machine the same way.
	Run gives back the machine's answer, how many sends landed and how many were made. A machine that
	makes more than STEPS_MAX asks fails its case, so a loop cannot hang the run.

	Return type: A table with Run and STEPS_MAX. The type is Keys.
	Example usage:
		local Reply, Updates = Replay.Drive(Transaction.Run, Context, Keys)
--]=]

local Asks = require("../src/Machine/Asks")
local Machine = require("../src/Machine/Machine")
local Step = require("../src/Record/Step")
local Types = require("../src/Record/Types")

export type Keys = { [string]: unknown }

local STEPS_MAX = 500

local function Run<Context, Answer>(Of: Machine.Machine<Context, Answer>, Context: Context, Keys: Keys, Build: Types.Build, Now: number): (Answer?, number, number)
	local Call, First = Machine.Start(Of, Context, Now)
	local Queue: { Machine.Asked } = table.clone(First)
	local Updates, Sends, Steps = 0, 0, 0
	while #Queue > 0 do
		Steps += 1
		assert(Steps <= STEPS_MAX, "the machine did not stop")
		local Next = table.remove(Queue, 1) :: Machine.Asked
		local Ask = Next.Ask
		local Heard: Asks.Heard
		if Ask.Kind == "Send" then
			Sends += 1
			local Note = Step(Keys[Ask.Ref.Key], Ask.Request, Now, Build)
			if Note.Stored ~= nil then
				Keys[Ask.Ref.Key] = Note.Stored
				Updates += 1
			end
			Heard = Asks.Noted(Note, Now, Note.Stored ~= nil)
		elseif Ask.Kind == "Read" then
			Heard = Asks.Got(Keys[Ask.Ref.Key], Now)
		elseif Ask.Kind == "Run" then
			Heard = Asks.Done(Now, (Run(Ask.Machine, Ask.Context, Keys, Build, Now)))
		elseif Ask.Kind == "Count" then
			Heard = Asks.Got(1, Now)
		else
			Heard = Asks.Done(Now)
		end
		for _, Each in Machine.Step(Call, Next.Id, Heard) do
			table.insert(Queue, Each)
		end
	end
	assert(Machine.IsFinal(Call), "the machine stopped short of a final state")
	return Machine.AnswerOf(Call), Updates, Sends
end

return {
	Run = Run,
	STEPS_MAX = STEPS_MAX,
}
