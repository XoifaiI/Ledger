--!strict
--!optimize 2

--[=[
	Fates: the fate of a named entry and its code (spec/protocols/record/Format.md 7.1).

	A code is one character in the head of the named entry, and a fate's extra bytes come after the stamp,
	so ReadFate runs once the stamp is read. A reader throws through Format.Malformed on a code no named
	entry holds. ShortReason: the part reasons a Short carries.

	Return type: A plain table of functions and the PartReason and ShortReason names, and the Fate, PartReason,
	ShortReason and WriterFateKind types.
	Example usage:
		Fates.FateCode({ Kind = "Fenced", Attempt = 2, IsFinal = true }) --> 10
--]=]

local Alphabet = require("../../Encoding/Alphabet")
local Format = require("../../Encoding/Format")
local Messages = require("../../Constants/Messages")
local Record = require("../../Constants/Record")
local Transaction = require("../../Constants/Transaction")

type Writer = Format.Writer
type Reader = Format.Reader

local PartReason = {
	Free = "Free" :: "Free",
	Held = "Held" :: "Held",
	Holds = "Holds" :: "Holds",
	Sealed = "Sealed" :: "Sealed",
	Closed = "Closed" :: "Closed",
	Gone = "Gone" :: "Gone",
}

export type PartReason = keyof<typeof(PartReason)>

local ShortReason = {
	Free = PartReason.Free,
	Held = PartReason.Held,
	Holds = PartReason.Holds,
	Gone = PartReason.Gone,
}

export type ShortReason = keyof<typeof(ShortReason)>

export type WriterFateKind = "Refused" | "Full" | "Cut"

export type Fate =
	{ Kind: "Took" }
	| { Kind: "Refused" }
	| { Kind: "Full" }
	| { Kind: "Aborted", Attempt: number }
	| { Kind: "Fenced", Attempt: number, IsFinal: boolean }
	| { Kind: "TookWith", Value: number }
	| { Kind: "RefusedFor", Reason: PartReason }

local Values = Alphabet.Values

local Malformed = Format.Malformed
local RequireWholeBelow = Format.RequireWholeBelow
local WriteVarint = Format.WriteVarint
local ReadVarint = Format.ReadVarint
local WriteCharacter = Format.WriteCharacter
local ReadCharacter = Format.ReadCharacter

local Codes = Record.FateCode
local MaxAttempts = Transaction.MaxAttempts

local PartReasonByte: { [PartReason]: number } = {
	Free = string.byte("f"),
	Held = string.byte("h"),
	Holds = string.byte("H"),
	Sealed = string.byte("s"),
	Closed = string.byte("c"),
	Gone = string.byte("g"),
}
local PartReasonIndex: { [PartReason]: number } = {}
local PartReasonOfIndex: { [number]: PartReason } = {}
for Reason, Byte in PartReasonByte do
	local Index = buffer.readu8(Values, Byte)
	PartReasonIndex[Reason] = Index
	PartReasonOfIndex[Index] = Reason
end

local WriterFateCode: { [WriterFateKind]: number } = {
	Refused = Codes.Refused,
	Full = Codes.Full,
	Cut = Codes.Cut,
}
local WriterFateKindOfCode: { [number]: WriterFateKind } = {}
for Kind, Code in WriterFateCode do
	WriterFateKindOfCode[Code] = Kind
end

local ModuleName = "Fates"

local UnknownFateCode = "a named entry holds a fate code that is none of the fates"
local UnknownWriterFate = "a writer entry holds a fate that is neither refused, full nor cut"
local UnknownPartReason = "a refusal on a part holds a reason that is none of the six"

local function RequireAttempt(Attempt: number)
	RequireWholeBelow(ModuleName, "an attempt", Attempt, MaxAttempts + 1)
	if Attempt < 1 then
		error(`{ModuleName}: an attempt is at least 1, got {Attempt}. {Messages.KeepInRange}`)
	end
end

local function FateCode(Fate: Fate): number
	if Fate.Kind == "Took" then
		return Codes.Took
	end
	if Fate.Kind == "Refused" then
		return Codes.Refused
	end
	if Fate.Kind == "Full" then
		return Codes.Full
	end
	if Fate.Kind == "Aborted" then
		RequireAttempt(Fate.Attempt)
		return Codes.AbortedFirst + Fate.Attempt - 1
	end
	if Fate.Kind == "Fenced" then
		RequireAttempt(Fate.Attempt)
		if Fate.IsFinal then
			return Codes.FencedFinalFirst + Fate.Attempt - 1
		end
		return Codes.FencedFirst + Fate.Attempt - 1
	end
	if Fate.Kind == "TookWith" then
		return Codes.TookWith
	end
	return Codes.RefusedFor
end

local function WriteFateExtra(Out: Writer, Fate: Fate)
	if Fate.Kind == "TookWith" then
		WriteVarint(Out, Fate.Value)
		return
	end
	if Fate.Kind == "RefusedFor" then
		WriteCharacter(Out, PartReasonIndex[Fate.Reason])
	end
end

local function ReadPartReason(In: Reader): PartReason
	local Reason = PartReasonOfIndex[ReadCharacter(In)]
	if Reason == nil then
		Malformed(UnknownPartReason)
	end
	return Reason
end

local function WriteWriterFateKind(Out: Writer, Kind: WriterFateKind)
	WriteCharacter(Out, WriterFateCode[Kind])
end

local function ReadWriterFateKind(In: Reader): WriterFateKind
	local Kind = WriterFateKindOfCode[ReadCharacter(In)]
	if Kind == nil then
		Malformed(UnknownWriterFate)
	end
	return Kind
end

local function ReadFate(In: Reader, Code: number): Fate
	if Code == Codes.Took then
		return { Kind = "Took" }
	end
	if Code == Codes.Refused then
		return { Kind = "Refused" }
	end
	if Code == Codes.Full then
		return { Kind = "Full" }
	end
	if Code < Codes.FencedFirst then
		return { Kind = "Aborted", Attempt = Code - Codes.AbortedFirst + 1 }
	end
	if Code < Codes.FencedFinalFirst then
		return { Kind = "Fenced", Attempt = Code - Codes.FencedFirst + 1, IsFinal = false }
	end
	if Code < Codes.TookWith then
		return { Kind = "Fenced", Attempt = Code - Codes.FencedFinalFirst + 1, IsFinal = true }
	end
	if Code == Codes.TookWith then
		return { Kind = "TookWith", Value = ReadVarint(In) }
	end
	if Code == Codes.RefusedFor then
		return { Kind = "RefusedFor", Reason = ReadPartReason(In) }
	end
	return Malformed(UnknownFateCode)
end

return {
	PartReason = table.freeze(PartReason),
	ShortReason = table.freeze(ShortReason),
	FateCode = FateCode,
	WriteFateExtra = WriteFateExtra,
	ReadFate = ReadFate,
	WriteWriterFateKind = WriteWriterFateKind,
	ReadWriterFateKind = ReadWriterFateKind,
}
