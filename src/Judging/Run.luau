--!strict
--!optimize 2

--[=[
	Run: a write's working state while one request is judged. Judge, Transform and the rules they call (a cut's, a
	leg's, a part's) share it, so none of them requires another for it.

	Return type: An empty table. The type is Run.
	Example usage:
		local JudgingRun = require("./Judging/Run")
		type Run = JudgingRun.Run
--]=]

local Book = require("../Stored/Book")
local JudgingShapes = require("./Shapes")
local Post = require("../Stored/Post")
local Seal = require("../Stored/Items/Seal")
local Shapes = require("../Shapes")
local Timed = require("../Stored/Items/Timed")
local Value = require("../Stored/Value")
local Work = require("../Stored/Items/Work")

type Book = Book.Book
type KeyKind = Shapes.KeyKind
type UpdateRequest = Shapes.UpdateRequest
type Setup = Shapes.Setup
type Closure = JudgingShapes.Closure
type Report = JudgingShapes.Report
type SentOp = Shapes.SentOp
type WriterFate = Timed.WriterFate
type TimedItem = Timed.TimedItem
type NoteWarning = JudgingShapes.NoteWarning
type DiffEntry = Post.DiffEntry
type Mark = Work.Mark
type Fields = Value.Fields
type Seal = Seal.Seal

export type Run = {
	Book: Book,
	State: { [unknown]: unknown },
	Epoch: number?,
	Kind: KeyKind,
	Request: UpdateRequest,
	Clock: number,
	Setup: Setup,
	Closure: Closure,
	Reports: { Report },
	Decided: { SentOp },
	NewFates: { WriterFate },
	Written: { [TimedItem]: boolean },
	Warnings: { NoteWarning },
	IsStopped: boolean,
	MigrationsTried: boolean,
	Post: { DiffEntry }?,
	Acted: boolean,
	Placed: Mark?,
	Given: Fields?,
	Sealed: Seal?,
}

return {}
