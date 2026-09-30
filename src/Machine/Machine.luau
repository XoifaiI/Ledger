--!strict
--!optimize 2

--[=[

	Machine: Plumbing. A state machine that asks for work and decides what to do with each reply.

	A state's Enter makes its asks with Ask. Once every ask of the state is heard, Hear turns the
	replies into one word. With no Hear the word is the first reply's own. The first row of On whose
	Said is that word, and whose When passes, says where to go. Else takes every other word. Where to
	go is a state, or an action that gives back one. A state with no Else is final, and a state that
	asks nothing goes on at once. Reply gives the state's first reply. Answer gives the call its
	answer, once. Define refuses a spec whose rows or Else name no state.

	Return type: A table with Define, Start, Step, Ask, Reply, Answer, AnswerOf, IsFinal and StateOf.
	The types are Machine, Spec, State, Row, Call and Asked.
	Example usage:
		local Call, Asked = Machine.Start(Unblock.Machine, Context, Now)
		Asked = Machine.Step(Call, Asked[1].Id, Asks.Got(Value, Now))
--]=]

local Asks = require("./Asks")

type Ask = Asks.Ask
type Heard = Asks.Heard

export type Go<Context, Answer> = string | (Call: Call<Context, Answer>) -> string

export type Row<Context, Answer> = {
	read Said: string,
	read When: ((Call: Call<Context, Answer>) -> boolean)?,
	read Go: Go<Context, Answer>,
}

export type State<Context, Answer> = {
	read Enter: ((Call: Call<Context, Answer>) -> ())?,
	read Hear: ((Call: Call<Context, Answer>) -> string)?,
	read On: { Row<Context, Answer> }?,
	read Else: Go<Context, Answer>?,
}

export type Spec<Context, Answer> = {
	read Name: string,
	read Initial: string,
	read States: { [string]: State<Context, Answer> },
}

export type Machine<Context, Answer> = {
	read Name: string,
	read Initial: string,
	read States: { [string]: State<Context, Answer> },
}

export type Asked = {
	read Id: number,
	read Ask: Ask,
}

export type Call<Context, Answer> = {
	read Machine: Machine<Context, Answer>,
	read Context: Context,
	State: string,
	Now: number,
	Answered: { read Value: Answer }?,
	Next: number,
	Out: { [number]: number },
	Heard: { Heard },
	Made: number,
	Asked: { Asked },
	Stepping: boolean,
}

local STEPS_MAX = 64

local function Check<Context, Answer>(Spec: Spec<Context, Answer>, Go: Go<Context, Answer>?, From: string)
	if type(Go) == "string" and Spec.States[Go] == nil then
		error(`Machine {Spec.Name}: {From} goes to {Go}, which is not a state`, 3)
	end
end

local function Define<Context, Answer>(Spec: Spec<Context, Answer>): Machine<Context, Answer>
	if Spec.States[Spec.Initial] == nil then
		error(`Machine {Spec.Name}: {Spec.Initial} is not a state`, 2)
	end
	for Name, State in Spec.States do
		if State.On and State.Else == nil then
			error(`Machine {Spec.Name}: {Name} has rows and no Else`, 2)
		end
		for _, Row in State.On or {} do
			Check(Spec, Row.Go, Name)
		end
		Check(Spec, State.Else, Name)
	end
	return table.freeze({ Name = Spec.Name, Initial = Spec.Initial, States = Spec.States })
end

local function IsFinal<Context, Answer>(Call: Call<Context, Answer>): boolean
	return Call.Machine.States[Call.State].Else == nil
end

local function Word<Context, Answer>(Call: Call<Context, Answer>, State: State<Context, Answer>): string
	if State.Hear then
		return State.Hear(Call)
	end
	local First = Call.Heard[1]
	return if First then First.Said else Asks.SAID.Done
end

local function Target<Context, Answer>(Call: Call<Context, Answer>, State: State<Context, Answer>): string
	local Said = Word(Call, State)
	local Go: Go<Context, Answer>? = State.Else
	local Rows: { Row<Context, Answer> } = State.On or {}
	for _, Row in Rows do
		local When = Row.When
		if Row.Said == Said and (When == nil or When(Call)) then
			Go = Row.Go
			break
		end
	end
	local Next = ""
	if type(Go) == "string" then
		Next = Go
	elseif Go then
		Next = Go(Call)
	end
	if Call.Machine.States[Next] == nil then
		error(`Machine {Call.Machine.Name}: {Call.State} went to {Next}, which is not a state`, 0)
	end
	return Next
end

local function Enter<Context, Answer>(Call: Call<Context, Answer>)
	for _ = 1, STEPS_MAX do
		local State = Call.Machine.States[Call.State]
		table.clear(Call.Heard)
		Call.Made = 0
		if State.Enter then
			State.Enter(Call)
		end
		if Call.Made > 0 or State.Else == nil then
			return
		end
		Call.State = Target(Call, State)
	end
	error(`Machine {Call.Machine.Name}: {STEPS_MAX} states in a row asked nothing`, 0)
end

local function Start<Context, Answer>(Of: Machine<Context, Answer>, Context: Context, Now: number): (Call<Context, Answer>, { Asked })
	local Call: Call<Context, Answer> = {
		Machine = Of,
		Context = Context,
		State = Of.Initial,
		Now = Now,
		Next = 1,
		Out = {},
		Heard = {},
		Made = 0,
		Asked = {},
		Stepping = true,
	}
	Enter(Call)
	Call.Stepping = false
	return Call, Call.Asked
end

local function Ask<Context, Answer>(Call: Call<Context, Answer>, Asking: Ask): number
	if not Call.Stepping then
		error(`Machine {Call.Machine.Name}: Ask outside a step`, 2)
	elseif IsFinal(Call) then
		error(`Machine {Call.Machine.Name}: the final state {Call.State} asked`, 2)
	end
	local Id = Call.Next
	Call.Next += 1
	Call.Made += 1
	Call.Out[Id] = Call.Made
	table.insert(Call.Asked, { Id = Id, Ask = Asking })
	return Id
end

local function Step<Context, Answer>(Call: Call<Context, Answer>, Id: number, Heard: Heard): { Asked }
	local Index = Call.Out[Id]
	if Index == nil then
		error(`Machine {Call.Machine.Name}: ask {Id} is not out`, 2)
	elseif Call.Stepping then
		error(`Machine {Call.Machine.Name}: Step inside a step`, 2)
	end
	Call.Out[Id] = nil
	Call.Heard[Index] = Heard
	Call.Now = Heard.Now
	Call.Asked = {}
	if next(Call.Out) ~= nil then
		return Call.Asked
	end
	Call.Stepping = true
	Call.State = Target(Call, Call.Machine.States[Call.State])
	Enter(Call)
	Call.Stepping = false
	return Call.Asked
end

local function Reply<Context, Answer>(Call: Call<Context, Answer>): Heard
	return Call.Heard[1]
end

local function Answer<Context, Answer>(Call: Call<Context, Answer>, Value: Answer)
	if Call.Answered then
		error(`Machine {Call.Machine.Name}: the call answered already`, 2)
	end
	Call.Answered = { Value = Value }
end

local function AnswerOf<Context, Answer>(Call: Call<Context, Answer>): Answer?
	local Answered = Call.Answered
	return if Answered then Answered.Value else nil
end

local function StateOf<Context, Answer>(Call: Call<Context, Answer>): string
	return Call.State
end

return {
	Define = Define,
	Start = Start,
	Step = Step,
	Ask = Ask,
	Reply = Reply,
	Answer = Answer,
	AnswerOf = AnswerOf,
	IsFinal = IsFinal,
	StateOf = StateOf,
}
