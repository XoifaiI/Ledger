--!strict

--[=[

	Bench: Times a whole book and a whole call under the Luau CLI.

	Return type: Nothing. It prints the time per operation for each workload.
	Example usage:
		luau.exe -O2 --codegen bench/Bench.luau
--]=]

local Machine = require("../src/Core/Machine")
local Reader = require("../src/Encode/Reader")
local Writer = require("../src/Encode/Writer")

type Effect = { read Kind: string, read Leg: number? }
type Reply = { read Kind: string }
type Context = { Legs: number, Yes: number }
type Call = Machine.Call<Context, Reply, Effect, number>
type Spec = Machine.Spec<Context, Reply, Effect, number>

local ITEMS = 300
local ROUNDS = 2000
local CALLS = 200000

local Names: { string } = {}
for Index = 1, ITEMS do
	Names[Index] = if Index % 4 == 0 then `player {Index}` else string.format("G%015d", Index)
end

local function Time(Label: string, Count: number, Body: () -> ())
	Body()
	local Start = os.clock()
	Body()
	local Elapsed = os.clock() - Start
	print(string.format("%-26s %8.1f ns/op  (%.3f s)", Label, Elapsed / Count * 1e9, Elapsed))
end

local Book = Writer.New()
local Text = ""

Time("write item of 4 fields", ROUNDS * ITEMS, function()
	for _ = 1, ROUNDS do
		Writer.Clear(Book)
		for Index = 1, ITEMS do
			Writer.Fixed(Book, Index % 64, 1)
			Writer.Name(Book, Names[Index])
			Writer.Var(Book, Index * 37 + 1000)
			Writer.Signed(Book, -Index * 1234567)
		end
		Text = Writer.Finish(Book)
	end
end)

Time("read item of 4 fields", ROUNDS * ITEMS, function()
	for _ = 1, ROUNDS do
		local Read = Reader.New(Text)
		for _ = 1, ITEMS do
			Reader.Fixed(Read, 1)
			Reader.Name(Read)
			Reader.Var(Read)
			Reader.Signed(Read)
		end
	end
end)

local Commit: Spec = {
	Name = "Commit",
	Initial = "Preparing",
	States = {
		Preparing = {
			To = { "Committing" },
			Enter = function(Call: Call)
				for Leg = 1, Call.Context.Legs do
					Machine.Send(Call, { Kind = "Prepare", Leg = Leg })
				end
			end,
			On = function(Call: Call, _: Reply): string?
				Call.Context.Yes += 1
				return if Call.Waiting == 0 then "Committing" else nil
			end,
		},
		Committing = {
			To = { "Done" },
			Enter = function(Call: Call)
				Machine.Answer(Call, Call.Context.Yes)
				for Leg = 1, Call.Context.Legs do
					Machine.Send(Call, { Kind = "Commit", Leg = Leg })
				end
			end,
			On = function(Call: Call, _: Reply): string?
				return if Call.Waiting == 0 then "Done" else nil
			end,
		},
		Done = {},
	},
}
local Defined = Machine.Define(Commit)
local YES: Reply = { Kind = "Yes" }

Time("call of 2 legs, 4 steps", CALLS, function()
	for _ = 1, CALLS do
		local Call = Machine.Start(Defined, { Legs = 2, Yes = 0 })
		Machine.Step(Call, 1, YES)
		Machine.Step(Call, 2, YES)
		Machine.Step(Call, 3, YES)
		Machine.Step(Call, 4, YES)
	end
end)
