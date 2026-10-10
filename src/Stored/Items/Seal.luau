--!strict
--!optimize 2

--[=[
	Seal: the gate G (spec/protocols/record/Format.md 7.6) and the seal (9) that stands for an erased key.
	Both hold absolute stamps.

	A reader throws through Format.Malformed on a seal of another version or kind. DecodeSeal gives nil
	instead. Whether a gate or seal fits its key is the cuts' to say.

	Return type: A plain table of functions, and the Gate, Seal and Aged types.
	Example usage:
		local Drawn = { Kind = "Drawn", Server = 0, Counter = 0 }
		local Records = { Events = {}, Returns = {}, Slots = {} }
		local ProveGone = { Name = Drawn, Stamp = 0, Sealer = 0, RemovalStamp = 23889600, Records = Records }
		Seal.EncodeSeal(ProveGone) --> "AEAAAAA25h2AA"
--]=]

local Format = require("../../Encoding/Format")
local Losses = require("./Losses")
local Names = require("../../Encoding/Names")
local Record = require("../../Constants/Record")
local Timed = require("./Timed")

type Writer = Format.Writer
type Reader = Format.Reader
type Name = Names.Name
type CutKind = Timed.CutKind
type LossRecords = Losses.LossRecords

export type Gate = {
	Kind: CutKind,
	Name: Name,
	Stamp: number,
	PlacedAt: number,
	Fingerprint: number?,
}

export type Aged = { read RemovalStamp: number }

export type Seal = {
	Name: Name,
	Stamp: number,
	Sealer: number,
	RemovalStamp: number,
	Fingerprint: number?,
	Records: LossRecords,
}

local NewWriter = Format.NewWriter
local ReadWhole = Format.ReadWhole
local ToString = Format.ToString
local Malformed = Format.Malformed
local WriteVarint = Format.WriteVarint
local ReadVarint = Format.ReadVarint
local WriteCharacter = Format.WriteCharacter
local ReadCharacter = Format.ReadCharacter

local WriteName = Names.WriteName
local ReadName = Names.ReadName

local CutKindIndex = Timed.CutKindIndex
local ReadCutKind = Timed.ReadCutKind
local WriteNameFingerprint = Timed.WriteNameFingerprint
local ReadNameFingerprint = Timed.ReadNameFingerprint

local WriteSealRecords = Losses.WriteSealRecords
local ReadSealRecords = Losses.ReadSealRecords

local SealVersion = Record.SealVersion
local EncodeStartBytes = Record.EncodeStartBytes
local SealKindIndex = CutKindIndex.Erase

local UnknownSealVersion = "a seal starts with a version this format does not know"
local SealKindNotErase = "a seal holds a kind that is not erase"

local function WriteGate(Out: Writer, Gate: Gate)
	WriteCharacter(Out, CutKindIndex[Gate.Kind])
	WriteName(Out, Gate.Name)
	WriteVarint(Out, Gate.Stamp)
	WriteVarint(Out, Gate.PlacedAt)
	WriteNameFingerprint(Out, Gate.Name, Gate.Fingerprint)
end

local function ReadGate(In: Reader): Gate
	local Entry: Gate = {
		Kind = ReadCutKind(In),
		Name = ReadName(In),
		Stamp = ReadVarint(In),
		PlacedAt = ReadVarint(In),
	}
	Entry.Fingerprint = ReadNameFingerprint(In, Entry.Name)
	return Entry
end

local function IsLeftOver(Sealed: Aged, Clock: number, SealAge: number): boolean
	return Clock - Sealed.RemovalStamp > SealAge
end

local function EncodeSeal(Seal: Seal): string
	local Out = NewWriter(EncodeStartBytes)
	WriteCharacter(Out, SealVersion)
	WriteCharacter(Out, SealKindIndex)
	WriteName(Out, Seal.Name)
	WriteNameFingerprint(Out, Seal.Name, Seal.Fingerprint)
	WriteVarint(Out, Seal.Stamp)
	WriteVarint(Out, Seal.Sealer)
	WriteVarint(Out, Seal.RemovalStamp)
	WriteSealRecords(Out, Seal.Records)
	return ToString(Out)
end

local function ReadSeal(In: Reader): Seal
	if ReadCharacter(In) ~= SealVersion then
		Malformed(UnknownSealVersion)
	end
	if ReadCharacter(In) ~= SealKindIndex then
		Malformed(SealKindNotErase)
	end
	local Name = ReadName(In)
	return {
		Name = Name,
		Fingerprint = ReadNameFingerprint(In, Name),
		Stamp = ReadVarint(In),
		Sealer = ReadVarint(In),
		RemovalStamp = ReadVarint(In),
		Records = ReadSealRecords(In),
	}
end

local function ReadSealText(Text: string): Seal
	return ReadWhole(Text, ReadSeal)
end

local function DecodeSeal(Text: string): Seal?
	local Succeeded, Seal = pcall(ReadSealText, Text)
	if not Succeeded then
		return nil
	end
	return Seal
end

return {
	IsLeftOver = IsLeftOver,
	WriteGate = WriteGate,
	ReadGate = ReadGate,
	EncodeSeal = EncodeSeal,
	ReadSeal = ReadSeal,
	ReadSealText = ReadSealText,
	DecodeSeal = DecodeSeal,
}
