--!strict
--!optimize 2

--[=[
	Requests: Logic. What a server asks one key to do in one UpdateAsync, and every request a
	machine builds.

	Spec: record 3.2 and 4; transaction 3.2 to 3.5; cuts 3.1 and 3.4.

	A request carries the ops of one writer, or the writer NONE and no ops. A request of NONE carries
	ends, a transaction step, a cut, a probe, a fresh read, a seal stamp or a tidy. An op, a Tent and
	a Commit carry Id, the incarnation they were judged for, nil for any, or Create, the id of a key
	they may make. An end path write carries only ends, drops and orphans. No floor, overdue item or
	full room on its key holds it back, so ending old work never waits on other work (record 4).

	Return type: The Requests module with the Form and Outcome sets, and the request types.
	Example usage:
		Machine.Ask(Call, Asks.Send(Ref, Requests.Ends({ End })))
--]=]

local Book = require("./Book")

local Form = {
	Minted = "Minted" :: "Minted",
	Hopeful = "Hopeful" :: "Hopeful",
	Timed = "Timed" :: "Timed",
	Untimed = "Untimed" :: "Untimed",
}

local Outcome = {
	Commit = "Commit" :: "Commit",
	Abort = "Abort" :: "Abort",
	Orphan = "Orphan" :: "Orphan",
}

export type Form = keyof<typeof(Form)>
export type Outcome = keyof<typeof(Outcome)>

export type Op = {
	read Form: Form,
	read Seq: number,
	read Stamp: number,
	read Kind: number,
	read Name: string?,
	read Print: number?,
	read View: number?,
	read Id: string?,
	read Create: string?,
	read Body: unknown,
}

export type Probe = {
	read Name: string,
	read Stamp: number,
}

export type Leg = {
	read Field: number?,
	read Amount: number?,
	read Body: unknown?,
	read Slot: { string }?,
}

export type Tent = {
	read Name: string,
	read Stamp: number,
	read Attempt: number,
	read Print: number?,
	read Decider: Book.Ref,
	read Leg: Leg,
	read Id: string?,
	read Create: string?,
}

export type Commit = {
	read Name: string,
	read Stamp: number,
	read Attempt: number,
	read Print: number?,
	read Legs: { Book.Ref },
	read Leg: Leg,
	read Id: string?,
	read Create: string?,
}

export type Fence = {
	read Name: string,
	read Stamp: number,
	read Attempt: number,
	read Print: number?,
	read Final: boolean,
}

export type Cut = {
	read Name: string,
	read Stamp: number,
	read Kind: number,
	read Print: number?,
	read Helper: boolean,
	read Server: number,
	read Id: string?,
	read State: { [string]: any }?,
}

export type Stamp = {
	read Server: number,
	read Rt: number?,
}

export type Orphan = {
	read Name: string,
	read Ref: Book.Ref,
}

export type End = {
	read Name: string,
	read Stamp: number,
	read Attempt: number,
	read Print: number?,
	read Outcome: Outcome,
	read Value: number?,
}

export type Request = {
	read Writer: number,
	read Ack: number,
	read MustExist: boolean,
	read Ops: { Op },
	read Fresh: boolean?,
	read Probe: Probe?,
	read Ends: { End }?,
	read Drops: { string }?,
	read Orphans: { Orphan }?,
	read Tent: Tent?,
	read Commit: Commit?,
	read Fence: Fence?,
	read Cut: Cut?,
	read Stamp: Stamp?,
	read Tidy: boolean?,
}

local NONE = 0

local Requests = {
	Form = Form,
	Outcome = Outcome,
	NONE = NONE,
}

function Requests.Batch(Writer: number, Ack: number, MustExist: boolean, Ops: { Op }, Ends: { End }?): Request
	return { Writer = Writer, Ack = Ack, MustExist = MustExist, Ops = Ops, Ends = Ends }
end

function Requests.Ends(Ends: { End }?, Drops: { string }?, Orphans: { Orphan }?): Request
	return { Writer = NONE, Ack = 0, MustExist = true, Ops = {}, Ends = Ends, Drops = Drops, Orphans = Orphans }
end

function Requests.Tent(Step: Tent, MustExist: boolean, Ends: { End }?): Request
	return { Writer = NONE, Ack = 0, MustExist = MustExist, Ops = {}, Ends = Ends, Tent = Step }
end

function Requests.Commit(Step: Commit, MustExist: boolean, Ends: { End }?, Drops: { string }?): Request
	return { Writer = NONE, Ack = 0, MustExist = MustExist, Ops = {}, Ends = Ends, Drops = Drops, Commit = Step }
end

function Requests.Fence(Step: Fence, Ends: { End }?): Request
	return { Writer = NONE, Ack = 0, MustExist = true, Ops = {}, Ends = Ends, Fence = Step }
end

function Requests.Cut(Step: Cut, Ends: { End }?): Request
	return { Writer = NONE, Ack = 0, MustExist = true, Ops = {}, Ends = Ends, Cut = Step }
end

function Requests.Fresh(Ends: { End }?): Request
	return { Writer = NONE, Ack = 0, MustExist = true, Ops = {}, Fresh = true, Ends = Ends }
end

function Requests.Probe(Step: Probe): Request
	return { Writer = NONE, Ack = 0, MustExist = true, Ops = {}, Probe = Step }
end

function Requests.Stamp(Step: Stamp): Request
	return { Writer = NONE, Ack = 0, MustExist = true, Ops = {}, Stamp = Step }
end

function Requests.Tidy(): Request
	return { Writer = NONE, Ack = 0, MustExist = true, Ops = {}, Tidy = true }
end

function Requests.IsEndPath(Request: Request): boolean
	return Request.Ops[1] == nil and not (Request.Tent or Request.Commit or Request.Fresh or Request.Probe or Request.Cut or Request.Stamp)
end

return Requests
