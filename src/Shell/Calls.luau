--!strict
--!optimize 2

--[=[
	Calls: the game's call ids, positive (the core's helpers take negative ones), and their futures. An answer before
	Open is kept for Take only for a CallNow call (Expect). A step's answers leave Pending at Claim and settle at
	Resume, after SettleOutcomes. A WithOutcome call answered Unresolved gets an Outcome. CloseAll settles every rest
	Unresolved, an Id Closed.

	Return type: A plain table with NewCallId, Open, OpenWithOutcome, Expect, Claim, SettleOutcomes, Resume, Take and
	CloseAll, and the Outcome type.
	Example usage:
		local Job = Calls.Open(Call.CallId, Call.Method)
		local Waiters = Calls.Claim(Answers)
		Calls.SettleOutcomes(Settled)
		Calls.Resume(Waiters)
--]=]

local Events = require("../Events")
local Future = require("../Util/Future")
local Reasons = require("../Constants/Reasons")
local Replies = require("../Replies")

type Answer = Events.Answer
type AnswerCommand = Events.AnswerCommand
type OutcomeEmission = Replies.OutcomeEmission
type Reason = Reasons.Reason
type Future<T...> = Future.Future<T...>

export type Outcome = Future<boolean, Reason?>

type Settle = (boolean, Reason?) -> ()

type Opened =
	{ read Kind: "Answer", read Method: string, read Done: (Answer) -> () }
	| { read Kind: "WithOutcome", read Method: string, read Done: (Answer, Outcome?) -> () }

type Waiter = { read CallId: number, read Opened: Opened, read Answer: Answer, read Outcome: Outcome? }

local LeftOver: Answer = { Kind = "Failed", Reason = Reasons.Unresolved, State = nil }
table.freeze(LeftOver)
local NeverRan: Answer = { Kind = "Failed", Reason = Reasons.Closed, State = nil }
table.freeze(NeverRan)

local IdMethod = "Id" :: "Id"

local LastCallId = 0
local Pending: { [number]: Opened } = {}
local Claimed: { [number]: Waiter } = {}
local Given: { [number]: Answer } = {}
local Expected: { [number]: true } = {}
local Outcomes: { [number]: Settle } = {}

local function NewCallId(): number
	LastCallId += 1
	return LastCallId
end

local function LeftOverOf(Method: string): Answer
	if Method == IdMethod then
		return NeverRan
	end
	return LeftOver
end

local function Open(CallId: number, Method: string): Future<Answer>
	local Job: Future<Answer>, Done: (Answer) -> () = Future.Pending()
	Pending[CallId] = { Kind = "Answer", Method = Method, Done = Done }
	return Job
end

local function OpenWithOutcome(CallId: number, Method: string): Future<Answer, Outcome?>
	local Job: Future<Answer, Outcome?>, Done: (Answer, Outcome?) -> () = Future.Pending()
	Pending[CallId] = { Kind = "WithOutcome", Method = Method, Done = Done }
	return Job
end

local function Expect(CallId: number)
	Expected[CallId] = true
end

local function OwesOutcome(Opened: Opened, Answered: Answer): boolean
	return Opened.Kind == "WithOutcome" and Replies.IsUnresolved(Answered)
end

local function OpenOutcome(CallId: number): Outcome
	local Job: Outcome, Done: Settle = Future.Pending()
	Outcomes[CallId] = Done
	return Job
end

local function SettledUnresolved(): Outcome
	return Future.Completed(false, Reasons.Unresolved :: Reason?)
end

local function Deliver(Opened: Opened, Answered: Answer, Outcome: Outcome?)
	if Opened.Kind == "Answer" then
		return Opened.Done(Answered)
	end
	Opened.Done(Answered, Outcome)
end

local function Claim(Commands: { AnswerCommand }): { Waiter }
	local Waiters: { Waiter } = {}
	for _, Command in Commands do
		local CallId = Command.CallId
		local Opened = Pending[CallId]
		if Opened == nil then
			if Expected[CallId] then
				Given[CallId] = Command.Answer
			end
			continue
		end
		Pending[CallId] = nil
		local Outcome = if OwesOutcome(Opened, Command.Answer) then OpenOutcome(CallId) else nil
		local Waiting: Waiter = { CallId = CallId, Opened = Opened, Answer = Command.Answer, Outcome = Outcome }
		Claimed[CallId] = Waiting
		table.insert(Waiters, Waiting)
	end
	return Waiters
end

local function SettleOutcome(Emission: OutcomeEmission)
	local Done = Outcomes[Emission.CallId]
	if Done == nil then
		return
	end
	Outcomes[Emission.CallId] = nil
	local Answered = Emission.Answer
	if Answered.Kind == "Succeeded" then
		return Done(true, nil)
	end
	Done(false, Answered.Reason)
end

local function SettleOutcomes(Settled: { OutcomeEmission })
	for _, Emission in Settled do
		SettleOutcome(Emission)
	end
end

local function Resume(Waiters: { Waiter })
	for _, Waiting in Waiters do
		if Claimed[Waiting.CallId] == Waiting then
			Claimed[Waiting.CallId] = nil
			Deliver(Waiting.Opened, Waiting.Answer, Waiting.Outcome)
		end
	end
end

local function Take(CallId: number): Answer?
	local Answer = Given[CallId]
	Given[CallId] = nil
	Expected[CallId] = nil
	return Answer
end

local function CloseAll()
	local Owed = Outcomes
	local Stranded = Claimed
	local Left = Pending
	Outcomes = {}
	Claimed = {}
	Pending = {}
	for _, Done in Owed do
		Done(false, Reasons.Unresolved)
	end
	for _, Waiting in Stranded do
		Deliver(Waiting.Opened, Waiting.Answer, Waiting.Outcome)
	end
	for _, Opened in Left do
		local Answered = LeftOverOf(Opened.Method)
		local Outcome = if OwesOutcome(Opened, Answered) then SettledUnresolved() else nil
		Deliver(Opened, Answered, Outcome)
	end
end

return {
	NewCallId = NewCallId,
	Open = Open,
	OpenWithOutcome = OpenWithOutcome,
	Expect = Expect,
	Claim = Claim,
	SettleOutcomes = SettleOutcomes,
	Resume = Resume,
	Take = Take,
	CloseAll = CloseAll,
}
