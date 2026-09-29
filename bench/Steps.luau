--!strict

--[=[

	Steps: Times each part of a call on its own under the Luau CLI.

	Effects and replies are made once, so the times are the machine's own.

	Return type: Nothing. It prints the time per operation for each part.
	Example usage:
		luau.exe -O2 --codegen bench/Steps.luau
--]=]

local Machine = require("../src/Core/Machine")

type Effect = { read Kind: string }
type Reply = { read Kind: string }
type Context = { Legs: number }
type Call = Machine.Call<Context, Reply, Effect, number>
type Spec = Machine.Spec<Context, Reply, Effect, number>

local COUNT = 1000000
local GET: Effect = { Kind = "Get" }
local YES: Reply = { Kind = "Yes" }
local CONTEXT: Context = { Legs = 2 }

local function Time(Label: string, Body: () -> ())
	Body()
	local Start = os.clock()
	Body()
	print(string.format("%-34s %7.1f ns", Label, (os.clock() - Start) / COUNT * 1e9))
end

local Idle: Spec = {
	Name = "Idle",
	Initial = "Idle",
	States = { Idle = {} },
}

local Retry: Spec = {
	Name = "Retry",
	Initial = "Asking",
	States = {
		Asking = {
			To = { "Asking" },
			Enter = function(Call: Call)
				Machine.Send(Call, GET)
			end,
			On = function(Call: Call, _: Reply): string?
				Machine.Send(Call, GET)
				return nil
			end,
		},
	},
}

local Loop: Spec = {
	Name = "Loop",
	Initial = "A",
	States = {
		A = {
			To = { "B" },
			Enter = function(Call: Call)
				Machine.Send(Call, GET)
			end,
			On = function(_: Call, _: Reply): string?
				return "B"
			end,
		},
		B = {
			To = { "A" },
			Enter = function(Call: Call)
				Machine.Send(Call, GET)
			end,
			On = function(_: Call, _: Reply): string?
				return "A"
			end,
		},
	},
}

local Fan: Spec = {
	Name = "Fan",
	Initial = "Sending",
	States = {
		Sending = {
			To = { "Sending" },
			Enter = function(Call: Call)
				for _ = 1, 8 do
					Machine.Send(Call, GET)
				end
			end,
			On = function(Call: Call, _: Reply): string?
				return if Call.Waiting == 0 then "Sending" else nil
			end,
		},
	},
}

local IdleMachine = Machine.Define(Idle)
Time("start, no send", function()
	for _ = 1, COUNT do
		Machine.Start(IdleMachine, CONTEXT)
	end
end)

local RetryMachine = Machine.Define(Retry)
Time("step that stays and sends once", function()
	local Call = Machine.Start(RetryMachine, CONTEXT)
	local Id = 1
	for _ = 1, COUNT do
		Machine.Step(Call, Id, YES)
		Id += 1
	end
end)

local LoopMachine = Machine.Define(Loop)
Time("step that moves and sends once", function()
	local Call = Machine.Start(LoopMachine, CONTEXT)
	local Id = 1
	for _ = 1, COUNT do
		Machine.Step(Call, Id, YES)
		Id += 1
	end
end)

local FanMachine = Machine.Define(Fan)
Time("reply to a fan out of 8, per reply", function()
	local Call = Machine.Start(FanMachine, CONTEXT)
	local Id = 1
	for _ = 1, COUNT do
		Machine.Step(Call, Id, YES)
		Id += 1
	end
end)
