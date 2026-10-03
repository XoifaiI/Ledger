--!strict

--[=[
	Types: Logic. The note a Step run gives back, and the build every write judges with.

	A note says, by the index of each op in its request, the fate the op has or why it has none. It
	holds the value to write, or nothing, and the report of the request's one step, with the items a
	blocked or crowded step read. A build's Level is its migration count and its Floor the index of
	the last breaking one. Its Upkeep runs on the state of every write before and after the request's
	steps, Output gives the decider value a commit's new state holds, and Accepts may refuse a field
	delta a transaction moves into or out of the key. Only Ledger's own key kinds set those three.

	Return type: A table with the Why and Report sets, BlankNote and RefusedNote, and the Why, Report, Stored, Note
	and Build types.
	Example usage:
		if Note.Why == Types.Why.NoRoom then return Answer.NoRoom end
--]=]

local Book = require("./Book")
local Diff = require("./Diff")
local Requests = require("./Requests")

local Why = {
	Spent = "Spent" :: "Spent",
	Forgotten = "Forgotten" :: "Forgotten",
	Behind = "Behind" :: "Behind",
	Ahead = "Ahead" :: "Ahead",
	NoRoom = "NoRoom" :: "NoRoom",
	Missing = "Missing" :: "Missing",
	Undecided = "Undecided" :: "Undecided",
	Corrupt = "Corrupt" :: "Corrupt",
	Worn = "Worn" :: "Worn",
	Blocked = "Blocked" :: "Blocked",
	Overdue = "Overdue" :: "Overdue",
}

local Report = {
	Mine = "Mine" :: "Mine",
	Superseded = "Superseded" :: "Superseded",
	Decided = "Decided" :: "Decided",
	Other = "Other" :: "Other",
	Forgotten = "Forgotten" :: "Forgotten",
	Behind = "Behind" :: "Behind",
	Ahead = "Ahead" :: "Ahead",
	Refused = "Refused" :: "Refused",
	Blocked = "Blocked" :: "Blocked",
	NoRoom = "NoRoom" :: "NoRoom",
	Large = "Large" :: "Large",
	Committed = "Committed" :: "Committed",
	Fenced = "Fenced" :: "Fenced",
	Owed = "Owed" :: "Owed",
	Gated = "Gated" :: "Gated",
	Took = "Took" :: "Took",
	Spent = "Spent" :: "Spent",
	Marks = "Marks" :: "Marks",
	GatedBy = "GatedBy" :: "GatedBy",
	Gone = "Gone" :: "Gone",
	Wait = "Wait" :: "Wait",
	Sealed = "Sealed" :: "Sealed",
	Stamped = "Stamped" :: "Stamped",
}

export type Why = keyof<typeof(Why)>
export type Report = keyof<typeof(Report)>

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
	Value: number?,
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
	read Upkeep: ((State: any, Clock: number, Marked: boolean) -> any)?,
	read Output: ((State: any) -> number?)?,
	read Accepts: ((State: any, Field: number, Amount: number) -> boolean)?,
}

local Types = {
	Why = Why,
	Report = Report,
}

function Types.BlankNote(): Note
	return { Fates = {}, Whys = {}, Decided = {}, Writes = 0, Cuts = 0, Horizon = 0, CutHorizon = 0 }
end

function Types.RefusedNote(Request: Requests.Request, Reason: Why, Items: { [string]: Book.Work }?): Note
	local Note = Types.BlankNote()
	Note.Why = Reason
	Note.Items = Items
	for Index in Request.Ops do
		Note.Whys[Index] = Reason
	end
	return Note
end

return Types
