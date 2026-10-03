--!strict
--!optimize 2

--[=[
	Runs: Logic. The working state of one run of Step, and how a step reports what it found.

	Step makes a fresh run each time its transform runs, and encodes the key from it at the end. The
	ends write to it first, then the request's one step, then each op through Rules. State and
	Changed are the game state the run has made so far. Acted says a step wrote an item, so the run
	lands even when it decided no op. Placed is the mark this run placed, which keeps its clean flag.
	Folding, Stop, Fates, FatesHeld, Minted, Newest, Last, Written and UntimedBytes belong to the op
	rules. A step's report is four fields of the note that Report sets together.

	Return type: The Runs module, and the Run type.
	Example usage:
		Runs.Report(Run, Types.Report.Mine, Tent.Attempt)
--]=]

local Book = require("./Book")
local Diff = require("./Diff")
local Key = require("./Key")
local Limits = require("../Core/Constants/Limits")
local Reduce = require("../Core/Reduce")
local Requests = require("./Requests")
local Rooms = require("./Rooms")
local Types = require("./Types")

export type Run = {
	read Request: Requests.Request,
	read Build: Types.Build,
	read Record: Book.Book,
	read Entry: Book.Entry?,
	read Note: Types.Note,
	read Reducer: Reduce.Reducer<any, any>,
	read Clock: number,
	read Now: number?,
	read Epoch: number,
	State: { [string]: any },
	Folding: Reduce.Fold<any, any>?,
	Stop: Types.Why?,
	Fates: { [number]: number },
	FatesHeld: number,
	Minted: number,
	Newest: number?,
	Last: number,
	Written: { [string]: true },
	UntimedBytes: number,
	Post: { Diff.Change }?,
	Given: { [string]: any }?,
	Sealed: Book.Seal?,
	Changed: boolean,
	Acted: boolean,
	Placed: string?,
}

local Runs = {}

function Runs.New(Request: Requests.Request, Build: Types.Build, Found: Key.Found, Clock: number, Reducer: Reduce.Reducer<any, any>, Late: boolean): Run
	local Record, State = Found.Book, Found.State
	local Entry = Record.Writers[Request.Writer]
	local Fates: { [number]: number } = {}
	local FatesHeld = 0
	for Seq, Code in if Entry then Entry.Fates else {} do
		if Seq > Request.Ack then
			Fates[Seq] = Code
			FatesHeld += 1
		end
	end
	local Now = if Clock >= 0 and Clock <= Limits.STAMP_MAX then Clock else nil
	local Epoch = Now or math.max(Record.Horizon, 0)
	local Note = Types.BlankNote()
	Note.Writes = Record.Writes
	Note.Cuts = Record.Cuts
	Note.Horizon = Record.Horizon
	Note.CutHorizon = Record.CutHorizon
	Note.Id = Record.Id
	Note.State = State
	Note.Late = if Late then true else nil
	local Made: Run = {
		Request = Request,
		Build = Build,
		Record = Record,
		Entry = Entry,
		Note = Note,
		Reducer = Reducer,
		Clock = Clock,
		Now = Now,
		Epoch = Epoch,
		State = State,
		Folding = nil,
		Stop = nil,
		Fates = Fates,
		FatesHeld = FatesHeld,
		Minted = 0,
		Newest = if Entry then Entry.Stamp else nil,
		Last = if Entry then Entry.Lo else 0,
		Written = {},
		UntimedBytes = Rooms.Untimed(Record, Epoch),
		Post = Found.Post,
		Given = Found.Given,
		Changed = false,
		Acted = false,
	}
	return Made
end

function Runs.Report(Run: Run, Said: Types.Report, Attempt: number?, Code: number?, Final: boolean?)
	local Note = Run.Note
	Note.Report = Said
	Note.Attempt = Attempt
	Note.Fate = Code
	Note.Final = Final
end

function Runs.ReportItems(Run: Run, Said: Types.Report, Items: { [string]: Book.Work }?)
	Runs.Report(Run, Said)
	Run.Note.Items = Items
end

return Runs
