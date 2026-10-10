--!strict
--!optimize 2

--[=[
	Events: what goes into step and what comes out of it. An Event is the clock reading and what happened. A
	Command asks the shell for one DataStore request, a MemoryStore get, set, update or remove, a JSON decode, a counter
	add, a wake, a Ready, an answer, an observer value or a warning. The core decodes update values.

	Return type: An empty table. The types are Event, Happening, Call, GivenName, ReadMethod, ReadAnswered,
	ReadOutcome, MemoryFetched, Outcome, MemoryOutcome, DecodeOutcome, Answer, Command and each of its variants
	(UpdateCommand to WarnCommand), TxCall, PendingCall and ResettleCall.
	Example usage:
		local Events = require("./Events")
		type Event = Events.Event
--]=]

local Book = require("./Stored/Book")
local CutShapes = require("./Cuts/Shapes")
local ExtrasShapes = require("./Extras/Shapes")
local Fates = require("./Stored/Items/Fates")
local HotShapes = require("./Hot/Shapes")
local JudgingShapes = require("./Judging/Shapes")
local Names = require("./Encoding/Names")
local Reasons = require("./Constants/Reasons")
local Shapes = require("./Shapes")
local TxShapes = require("./Tx/Shapes")

type Identity = Book.Identity
type PartReason = Fates.PartReason
type StoreKey = Names.StoreKey
type Reason = Reasons.Reason
type AskedName = Shapes.AskedName
type Request = Shapes.Request
type Note = JudgingShapes.Note

export type ReadAnswered = { read Kind: "Found", read Value: unknown } | { read Kind: "Absent" }

export type ReadOutcome = ReadAnswered | { read Kind: "Failed", read IsThrottled: boolean }

export type MemoryFetched = ReadAnswered | { read Kind: "Failed" }

export type Outcome =
	{ read Kind: "Ok", read Value: unknown, read Note: Note }
	| { read Kind: "Nil", read Note: Note }
	| { read Kind: "Err", read IsBeforeStore: boolean? }

export type MemoryOutcome = { read Kind: "Ok" } | { read Kind: "Nil" } | { read Kind: "Err" }

export type DecodeOutcome = { read Kind: "Found", read Value: unknown } | { read Kind: "Failed" }

export type GivenName = Names.GivenName

export type TxCall = {
	read Kind: "Call",
	read Method: "Tx",
	read CallId: number,
	read Legs: { TxShapes.TxLeg },
	read Hot: number?,
	read Name: GivenName?,
}

export type PendingCall = { read Kind: "Call", read Method: "Pending", read CallId: number, read Key: StoreKey }

export type ResettleCall = {
	read Kind: "Call",
	read Method: "Resettle",
	read CallId: number,
	read Key: StoreKey,
}

export type ReadMethod = "Peek" | "Inspect" | "PeekFresh" | "Losses"

export type Call =
	{ read Kind: "Call", read Method: "Id", read CallId: number }
	| { read Kind: "Call", read Method: "CloseAll", read CallId: number, read BeganAt: number? }
	| { read Kind: "Call", read Method: "Load", read CallId: number, read Key: StoreKey, read MustExist: boolean }
	| {
		read Kind: "Call",
		read Method: "Apply",
		read CallId: number,
		read Key: StoreKey,
		read OpKind: string,
		read Terms: unknown,
	}
	| {
		read Kind: "Call",
		read Method: "Edit",
		read CallId: number,
		read Key: StoreKey,
		read OpKind: string,
		read Terms: unknown,
		read MustExist: boolean,
		read Name: GivenName?,
	}
	| {
		read Kind: "Call",
		read Method: "Commit",
		read CallId: number,
		read Key: StoreKey,
		read OpKind: string,
		read Terms: unknown,
		read Name: GivenName?,
	}
	| { read Kind: "Call", read Method: "Flush", read CallId: number, read Key: StoreKey }
	| { read Kind: "Call", read Method: "Refresh", read CallId: number, read Key: StoreKey }
	| { read Kind: "Call", read Method: "Release", read CallId: number, read Key: StoreKey }
	| { read Kind: "Call", read Method: ReadMethod, read CallId: number, read Key: StoreKey }
	| { read Kind: "Call", read Method: "DidApply", read CallId: number, read Key: StoreKey, read Name: AskedName }
	| {
		read Kind: "Call",
		read Method: "DidApplyWithProbe",
		read CallId: number,
		read Key: StoreKey,
		read Name: AskedName,
	}
	| TxCall
	| PendingCall
	| ResettleCall
	| CutShapes.EraseCall
	| CutShapes.ResetCall
	| ExtrasShapes.BumpCall
	| ExtrasShapes.TotalCall
	| ExtrasShapes.FollowCall
	| ExtrasShapes.UnfollowCall
	| ExtrasShapes.StaleCall
	| ExtrasShapes.PeekWithinCall
	| HotShapes.TakeCall
	| HotShapes.GatherCall
	| HotShapes.HoldCall
	| HotShapes.OpenCall
	| HotShapes.CloseCall
	| HotShapes.ConfirmCall
	| HotShapes.ReleaseCall
	| HotShapes.DepositCall
	| HotShapes.WithdrawCall

export type Happening =
	Call
	| { read Kind: "Result", read RequestId: number, read Outcome: Outcome }
	| { read Kind: "Read", read RequestId: number, read Fetched: ReadOutcome, read Fraction: number }
	| { read Kind: "MemoryRead", read RequestId: number, read Fetched: MemoryFetched, read Fraction: number }
	| { read Kind: "MemoryResult", read RequestId: number, read Outcome: MemoryOutcome }
	| { read Kind: "Decoded", read RequestId: number, read Outcome: DecodeOutcome }
	| { read Kind: "Removed", read RequestId: number, read IsOk: boolean }
	| { read Kind: "Send", read Key: StoreKey }
	| { read Kind: "Clock" }
	| { read Kind: "Counted", read RequestId: number, read Written: string? }
	| { read Kind: "CounterUnusable", read RequestId: number }

export type Event = {
	read Clock: number,
	read Happening: Happening,
}

export type Answer =
	{ read Kind: "Succeeded", read Value: unknown }
	| {
		read Kind: "Failed",
		read Reason: Reason,
		read State: unknown,
		read Identity: Identity?,
		read Name: GivenName?,
		read ShortReason: PartReason?,
		read Key: StoreKey?,
	}

export type UpdateCommand =
	{ read Kind: "Update", read RequestId: number, read Target: StoreKey, read Request: Request }

export type GetCommand = { read Kind: "Get", read RequestId: number, read Target: StoreKey }

export type CountCommand = {
	read Kind: "Count",
	read RequestId: number,
	read Target: StoreKey,
	read Add: (Stored: unknown) -> string?,
}

export type RemoveCommand = { read Kind: "Remove", read RequestId: number, read Target: StoreKey }

export type MemoryUpdateCommand = {
	read Kind: "MemoryUpdate",
	read RequestId: number,
	read Map: string,
	read Key: string,
	read Item: (Current: unknown, Clock: number) -> unknown?,
	read Expiry: number,
}

export type MemoryGetCommand = { read Kind: "MemoryGet", read RequestId: number, read Map: string, read Key: string }

export type MemorySetCommand = {
	read Kind: "MemorySet",
	read RequestId: number,
	read Map: string,
	read Key: string,
	read Item: unknown,
	read Expiry: number,
}

export type MemoryRemoveCommand = {
	read Kind: "MemoryRemove",
	read RequestId: number,
	read Map: string,
	read Key: string,
}

export type DecodeCommand = { read Kind: "Decode", read RequestId: number, read Text: string }

export type WakeCommand = { read Kind: "Wake", read At: number }

export type AnswerCommand = { read Kind: "Answer", read CallId: number, read Answer: Answer }

export type EmitCommand = { read Kind: "Emit", read Stream: string, read Key: StoreKey, read Value: unknown }

export type ReadyCommand = { read Kind: "Ready", read Key: StoreKey }

export type WarnCommand = { read Kind: "Warn", read Key: StoreKey?, read Text: string }

export type Command =
	UpdateCommand
	| GetCommand
	| CountCommand
	| RemoveCommand
	| MemoryUpdateCommand
	| MemoryGetCommand
	| MemorySetCommand
	| MemoryRemoveCommand
	| DecodeCommand
	| WakeCommand
	| AnswerCommand
	| EmitCommand
	| ReadyCommand
	| WarnCommand

return {}
