--!strict

--[=[

	Types: Logic. The shapes Step, the writer and the rules share.

	An op carries Id, the incarnation it was judged for, nil for any. Or it carries Create, the id
	for a key it makes. A Tent and a Commit carry the same. A build is Erasable when its keys carry
	an incarnation. A note says by op index what fate an op has, or why it has none, and holds the
	value to write. A build's Level is its migration count, and its Floor the index of the last
	breaking one. A request may carry ends, applied first: resolves of transaction marks and drops
	of pinned records. It may carry one transaction step: a Tent on a leg key, a Commit on the
	decider, or a Fence there. It may carry one cut, a Reset or an Erase as its cutter or as a
	helper finishing its gate, or a seal stamp. Its report goes in the note, with the items a
	blocked or crowded step read. The note also holds the gate it met, the seal it met or made, and
	the clock a cut must wait for.

	Return type: A table with Form, Why, Outcome and Report. The types are Form, Op, Probe, Leg, Tent,
	Commit, Fence, End, Outcome, Request, Why, Report, Stored, Note and Build.
	Example usage:
		if Op.Form == Types.Form.Untimed then return Types.Why.NoRoom end
--]=]

local Book = require("./Book")
local Diff = require("./Diff")

export type Form = "Minted" | "Hopeful" | "Timed" | "Untimed"

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

export type Outcome = "Commit" | "Abort" | "Orphan"

export type End = {
	read Name: string,
	read Stamp: number,
	read Attempt: number,
	read Print: number?,
	read Outcome: Outcome,
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

export type Why = "Spent" | "Forgotten" | "Behind" | "Ahead" | "NoRoom" | "Missing" | "Undecided" | "Corrupt" | "Worn" | "Blocked" | "Overdue"

export type Report =
	"Mine"
	| "Superseded"
	| "Decided"
	| "Other"
	| "Forgotten"
	| "Behind"
	| "Ahead"
	| "Refused"
	| "Blocked"
	| "NoRoom"
	| "Large"
	| "Committed"
	| "Fenced"
	| "Owed"
	| "Gated"
	| "Took"
	| "Spent"
	| "Marks"
	| "GatedBy"
	| "Gone"
	| "Wait"
	| "Sealed"
	| "Stamped"

export type Stored = {
	s: { [string]: any }?,
	b: string?,
	p: { Diff.Change }?,
	r: { [string]: any }?,
	z: string?,
}

export type Note = {
	Fates: { [number]: number },
	Whys: { [number]: Why },
	Decided: { number },
	Writes: number,
	Cuts: number,
	Horizon: number,
	CutHorizon: number,
	Id: string?,
	State: unknown,
	Stored: Stored?,
	Held: number?,
	Why: Why?,
	Report: Report?,
	Attempt: number?,
	Fate: number?,
	Final: boolean?,
	Items: { [string]: Book.Work }?,
	Gate: Book.Gate?,
	Seal: Book.Seal?,
	Wait: number?,
	Left: boolean?,
	Late: boolean?,
}

export type Build = {
	read Reducer: (State: any, Op: any) -> unknown,
	read Migrations: { (State: any) -> unknown },
	read Default: { [string]: any },
	read Level: number,
	read Floor: number,
	read Money: { string },
	read Fields: { [string]: true },
	read Erasable: boolean,
	read Window: { [number]: number },
	read Minted: number,
	read CutWindow: number,
	read TimedRoom: number,
	read UntimedRoom: number,
	read WorkRoom: number,
	read CutNames: number,
	read LossRoom: number,
	read KeepNamed: number,
	read LegLimit: number,
	read StateCap: number,
	read Ahead: number,
	read Hold: number,
	read Paced: number?,
}

local Form: {
	read Minted: "Minted",
	read Hopeful: "Hopeful",
	read Timed: "Timed",
	read Untimed: "Untimed",
} = {
	Minted = "Minted",
	Hopeful = "Hopeful",
	Timed = "Timed",
	Untimed = "Untimed",
}

local Why: {
	read Spent: "Spent",
	read Forgotten: "Forgotten",
	read Behind: "Behind",
	read Ahead: "Ahead",
	read NoRoom: "NoRoom",
	read Missing: "Missing",
	read Undecided: "Undecided",
	read Corrupt: "Corrupt",
	read Worn: "Worn",
	read Blocked: "Blocked",
	read Overdue: "Overdue",
} =
	{
		Spent = "Spent",
		Forgotten = "Forgotten",
		Behind = "Behind",
		Ahead = "Ahead",
		NoRoom = "NoRoom",
		Missing = "Missing",
		Undecided = "Undecided",
		Corrupt = "Corrupt",
		Worn = "Worn",
		Blocked = "Blocked",
		Overdue = "Overdue",
	}

local Outcome: {
	read Commit: "Commit",
	read Abort: "Abort",
	read Orphan: "Orphan",
} = {
	Commit = "Commit",
	Abort = "Abort",
	Orphan = "Orphan",
}

local Report: {
	read Mine: "Mine",
	read Superseded: "Superseded",
	read Decided: "Decided",
	read Other: "Other",
	read Forgotten: "Forgotten",
	read Behind: "Behind",
	read Ahead: "Ahead",
	read Refused: "Refused",
	read Blocked: "Blocked",
	read NoRoom: "NoRoom",
	read Large: "Large",
	read Committed: "Committed",
	read Fenced: "Fenced",
	read Owed: "Owed",
	read Gated: "Gated",
	read Took: "Took",
	read Spent: "Spent",
	read Marks: "Marks",
	read GatedBy: "GatedBy",
	read Gone: "Gone",
	read Wait: "Wait",
	read Sealed: "Sealed",
	read Stamped: "Stamped",
} =
	{
		Mine = "Mine",
		Superseded = "Superseded",
		Decided = "Decided",
		Other = "Other",
		Forgotten = "Forgotten",
		Behind = "Behind",
		Ahead = "Ahead",
		Refused = "Refused",
		Blocked = "Blocked",
		NoRoom = "NoRoom",
		Large = "Large",
		Committed = "Committed",
		Fenced = "Fenced",
		Owed = "Owed",
		Gated = "Gated",
		Took = "Took",
		Spent = "Spent",
		Marks = "Marks",
		GatedBy = "GatedBy",
		Gone = "Gone",
		Wait = "Wait",
		Sealed = "Sealed",
		Stamped = "Stamped",
	}

return {
	Form = Form,
	Why = Why,
	Outcome = Outcome,
	Report = Report,
}
