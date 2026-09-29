--!strict
--!optimize 2
--!native

--[=[

	Machine: A state machine that sends requests and takes their replies.

	Send gives each request an id, and Step hands the reply for that id to the current state. Enter
	runs on entering a state. On takes a reply and names the next state, or nil to stay. A state moves
	only when none of its requests are out. A state with no On is final.

	Id N sits at slot N % Size + 1 of a ring: N while out, -N once cancelled, 0 when free. Ids are sent
	in order and the ring doubles at the first clash, so every id out is less than Size behind the
	newest and one doubling always frees its slot.

	Return type: A table with Define, Start, Step, Send, Cancel, Answer, IsFinal and StateOf.
	Example usage:
		local Machine = require("./Machine")
		local Call, Effects, First = Machine.Start(Fetch, Context)
		Effects, First = Machine.Step(Call, First, Reply)
--]=]

export type State<Context, Reply, Effect, Answer> = {
	read To: { string }?,
	read Enter: ((Call: Call<Context, Reply, Effect, Answer>) -> ())?,
	read On: ((Call: Call<Context, Reply, Effect, Answer>, Reply: Reply) -> string?)?,
}

export type Spec<Context, Reply, Effect, Answer> = {
	read Name: string,
	read Initial: string,
	read States: { [string]: State<Context, Reply, Effect, Answer> },
}

export type Node<Context, Reply, Effect, Answer> = {
	read Name: string,
	read Enter: ((Call: Call<Context, Reply, Effect, Answer>) -> ())?,
	read On: ((Call: Call<Context, Reply, Effect, Answer>, Reply: Reply) -> string?)?,
	read Moves: { [string]: Node<Context, Reply, Effect, Answer> },
}

export type Machine<Context, Reply, Effect, Answer> = {
	read Name: string,
	read Initial: Node<Context, Reply, Effect, Answer>,
}

export type Call<Context, Reply, Effect, Answer> = {
	read Machine: Machine<Context, Reply, Effect, Answer>,
	read Context: Context,
	State: Node<Context, Reply, Effect, Answer>,
	Answer: Answer?,
	Effects: { Effect },
	First: number,
	Next: number,
	Ring: { number },
	Size: number,
	Waiting: number,
	Stepping: boolean,
}

local function Grow(Old: { number }, Size: number): { number }
	local Ring = table.create(Size, 0)
	for _, Held in Old do
		if Held ~= 0 then
			Ring[math.abs(Held) % Size + 1] = Held
		end
	end
	return Ring
end

local function Define<Context, Reply, Effect, Answer>(Spec: Spec<Context, Reply, Effect, Answer>): Machine<Context, Reply, Effect, Answer>
	local Nodes: { [string]: Node<Context, Reply, Effect, Answer> } = {}
	local Moves: { [string]: { [string]: Node<Context, Reply, Effect, Answer> } } = {}
	for Name, State in Spec.States do
		Moves[Name] = {}
		Nodes[Name] = { Name = Name, Enter = State.Enter, On = State.On, Moves = Moves[Name] }
	end
	for Name, State in Spec.States do
		for _, Target in State.To or {} do
			Moves[Name][Target] = assert(Nodes[Target], `Machine {Spec.Name}: {Target} is not a state`)
		end
		table.freeze(Moves[Name])
		table.freeze(Nodes[Name])
	end

	return table.freeze({
		Name = Spec.Name,
		Initial = assert(Nodes[Spec.Initial], `Machine {Spec.Name}: {Spec.Initial} is not a state`),
	})
end

local function Start<Context, Reply, Effect, Answer>(Machine: Machine<Context, Reply, Effect, Answer>, Context: Context): (Call<Context, Reply, Effect, Answer>, { Effect }, number)
	local Call: Call<Context, Reply, Effect, Answer> = {
		Machine = Machine,
		Context = Context,
		State = Machine.Initial,
		Answer = nil,
		Effects = {},
		First = 1,
		Next = 1,
		Ring = { 0, 0, 0, 0, 0, 0, 0, 0 },
		Size = 8,
		Waiting = 0,
		Stepping = true,
	}
	local Enter = Machine.Initial.Enter
	if Enter then
		Enter(Call)
	end
	Call.Stepping = false
	return Call, Call.Effects, 1
end

local function Send<Context, Reply, Effect, Answer>(Call: Call<Context, Reply, Effect, Answer>, Effect: Effect): number
	if not Call.Stepping or Call.State.On == nil then
		error(`Machine {Call.Machine.Name}: Send outside a step or from a final state`, 2)
	end
	local Id = Call.Next
	local Slot = Id % Call.Size + 1
	if Call.Ring[Slot] ~= 0 then
		Call.Size *= 2
		Call.Ring = Grow(Call.Ring, Call.Size)
		Slot = Id % Call.Size + 1
		assert(Call.Ring[Slot] == 0, "an id out is further back than the ring size")
	end
	Call.Ring[Slot] = Id
	Call.Next = Id + 1
	Call.Effects[Id - Call.First + 1] = Effect
	Call.Waiting += 1
	return Id
end

local function Cancel<Context, Reply, Effect, Answer>(Call: Call<Context, Reply, Effect, Answer>, Id: number)
	local Slot = Id % Call.Size + 1
	if Id < 1 or Call.Ring[Slot] ~= Id then
		return
	end
	Call.Ring[Slot] = -Id
	Call.Waiting -= 1
end

local function Answer<Context, Reply, Effect, Answer>(Call: Call<Context, Reply, Effect, Answer>, Value: Answer)
	if Call.Answer ~= nil then
		error(`Machine {Call.Machine.Name}: the call answered already`, 2)
	end
	Call.Answer = Value
end

local function Step<Context, Reply, Effect, Answer>(Call: Call<Context, Reply, Effect, Answer>, Id: number, Reply: Reply): ({ Effect }, number)
	if Call.Stepping then
		error(`Machine {Call.Machine.Name}: Step inside Step, or on a call whose transition raised`, 2)
	end
	local Ring = Call.Ring
	local Slot = Id % Call.Size + 1
	local Held = Ring[Slot]
	if Id < 1 or (Held ~= Id and Held ~= -Id) then
		error(`Machine {Call.Machine.Name}: request {Id} is not out`, 2)
	end

	Ring[Slot] = 0
	local Effects = Call.Effects
	local First = Call.Next
	for Sent = First - Call.First, 1, -1 do
		Effects[Sent] = nil
	end
	Call.First = First
	if Held < 0 then
		return Effects, First
	end

	Call.Waiting -= 1
	Call.Stepping = true
	local From = Call.State
	local On = From.On
	if On == nil then
		error(`Machine {Call.Machine.Name}: final state {From.Name} took a reply`, 2)
	end
	local Target = On(Call, Reply)
	if Target ~= nil then
		local To = From.Moves[Target]
		if To == nil then
			error(`Machine {Call.Machine.Name}: state {From.Name} may not move to {Target}`, 2)
		end
		if Call.Waiting > 0 then
			error(`Machine {Call.Machine.Name}: state {From.Name} moves to {Target} with {Call.Waiting} requests out`, 2)
		end
		Call.State = To
		local Enter = To.Enter
		if Enter then
			Enter(Call)
		end
	end
	Call.Stepping = false
	return Effects, First
end

local function IsFinal<Context, Reply, Effect, Answer>(Call: Call<Context, Reply, Effect, Answer>): boolean
	return Call.State.On == nil
end

local function StateOf<Context, Reply, Effect, Answer>(Call: Call<Context, Reply, Effect, Answer>): string
	return Call.State.Name
end

return table.freeze({
	Define = Define,
	Start = Start,
	Step = Step,
	Send = Send,
	Cancel = Cancel,
	Answer = Answer,
	IsFinal = IsFinal,
	StateOf = StateOf,
})
