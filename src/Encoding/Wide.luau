--!strict
--!optimize 2
--!native

--[=[
	Wide: wide varints, below 2^85 and held as High * 2^35 + Low, and the signed numbers built on them. A
	signed amount is the zigzag plus 1. AddWide does not refuse a sum of 2^85 or more; WriteWide does when
	it is written.

	Return type: A plain table of functions, and the Wide and SignedWide types.
	Example usage:
		local Out = Format.NewWriter(64)
		Wide.WriteWide(Out, 262144, 0)
		Format.ToString(Out) --> "ogggggggggA"
--]=]

local Alphabet = require("./Alphabet")
local Format = require("./Format")
local Messages = require("../Constants/Messages")
local Record = require("../Constants/Record")

type Writer = Format.Writer
type Reader = Format.Reader

export type Wide = {
	High: number,
	Low: number,
}

export type SignedWide = {
	IsNegative: boolean,
	High: number,
	Low: number,
}

local Chars = Alphabet.Chars
local Values = Alphabet.Values
local INVALID = Alphabet.INVALID

local Grow = Format.Grow
local Malformed = Format.Malformed
local VarintWidth = Format.VarintWidth
local RequireWholeBelow = Format.RequireWholeBelow
local WriteVarint = Format.WriteVarint

local DigitBase = Record.VarintDigitBase
local HasMoreDigits = Record.VarintDigitBase
local VarintLimit = Record.VarintLimit

local WideHighDigits = 10
local WideLowDigits = Record.WideLowDigits
local WideLimb = Record.WideLimb
local WideHighLimit = DigitBase ^ WideHighDigits
local WideDigitsMost = WideHighDigits + WideLowDigits
local HighBeforeOverflow = WideHighLimit / DigitBase

local ZigzagFactor = 2
local HalfLimb = WideLimb / ZigzagFactor
local SignedHighLimit = WideHighLimit / ZigzagFactor
local PlainSignedLeast = -VarintLimit / ZigzagFactor
local PlainSignedLimit = VarintLimit / ZigzagFactor

local ModuleName = "Wide"

local WideLimitText = string.format("%.0f", WideHighLimit * WideLimb)
local PlainSignedLeastText = string.format("%.0f", PlainSignedLeast)
local PlainSignedLimitText = string.format("%.0f", PlainSignedLimit)

local WideVarintTooLarge = `a wide varint is {WideLimitText} or more`
local PlainSignedOutOfRange = `{ModuleName}: a plain signed number is a whole number from {PlainSignedLeastText} `
	.. `below {PlainSignedLimitText}, so that its zigzag is below 2^53. The caller must keep it in range`
local NegativeZeroAmount =
	`{ModuleName}: a negative amount is not zero, since zero has one form. The caller must write zero as not negative`

local function WriteWide(Out: Writer, High: number, Low: number)
	RequireWholeBelow(ModuleName, "the High limb of a wide number", High, WideHighLimit)
	RequireWholeBelow(ModuleName, "the Low limb of a wide number", Low, WideLimb)
	if High == 0 then
		WriteVarint(Out, Low)
		return
	end
	local Cursor = Out.Cursor
	if Cursor + WideDigitsMost > Out.Size then
		Grow(Out, Cursor, WideDigitsMost)
	end
	local Buffer = Out.Buffer
	local LowAt = Cursor + VarintWidth(High)
	local Remaining = High
	for At = LowAt - 1, Cursor, -1 do
		buffer.writeu8(Buffer, At, buffer.readu8(Chars, HasMoreDigits + Remaining % DigitBase))
		Remaining //= DigitBase
	end
	local Last = LowAt + WideLowDigits - 1
	buffer.writeu8(Buffer, Last, buffer.readu8(Chars, Low % DigitBase))
	Remaining = Low // DigitBase
	for At = Last - 1, LowAt, -1 do
		buffer.writeu8(Buffer, At, buffer.readu8(Chars, HasMoreDigits + Remaining % DigitBase))
		Remaining //= DigitBase
	end
	Out.Cursor = Last + 1
end

local function ReadWide(In: Reader): Wide
	local Bytes = In.Bytes
	local Size = buffer.len(Bytes)
	local At = In.At
	if At >= Size then
		Malformed(Messages.EndsEarly)
	end
	local First = buffer.readu8(Values, buffer.readu8(Bytes, At))
	At += 1
	if First < HasMoreDigits then
		In.At = At
		return { High = 0, Low = First }
	end
	if First == INVALID then
		Malformed(Messages.OutsideAlphabet)
	end
	if First == HasMoreDigits then
		Malformed(Messages.LeadingZeroDigit)
	end

	local High = 0
	local Low = First - HasMoreDigits
	while At < Size do
		local Index = buffer.readu8(Values, buffer.readu8(Bytes, At))
		if Index == INVALID then
			Malformed(Messages.OutsideAlphabet)
		end
		if High >= HighBeforeOverflow then
			Malformed(WideVarintTooLarge)
		end
		At += 1
		Low = Low * DigitBase + Index % DigitBase
		High = High * DigitBase + Low // WideLimb
		Low %= WideLimb
		if Index < HasMoreDigits then
			In.At = At
			return { High = High, Low = Low }
		end
	end
	return Malformed(Messages.EndsEarly)
end

local function RefuseNegativeZero(High: number, Low: number, IsNegative: boolean)
	if IsNegative and High == 0 and Low == 0 then
		error(NegativeZeroAmount)
	end
end

local function WriteDoubled(Out: Writer, High: number, Low: number, AddedAfterDoubling: number)
	local Doubled = Low * ZigzagFactor + AddedAfterDoubling
	WriteWide(Out, High * ZigzagFactor + Doubled // WideLimb, Doubled % WideLimb)
end

local function HalveEvenIsNegative(Value: Wide): SignedWide
	return {
		IsNegative = Value.Low % ZigzagFactor == 0,
		High = Value.High // ZigzagFactor,
		Low = Value.High % ZigzagFactor * HalfLimb + Value.Low // ZigzagFactor,
	}
end

local function AddOne(Value: Wide): Wide
	local Next = Value.Low + 1
	return { High = Value.High + Next // WideLimb, Low = Next % WideLimb }
end

local function SubtractOne(Value: Wide): Wide
	if Value.Low == 0 then
		return { High = Value.High - 1, Low = WideLimb - 1 }
	end
	return { High = Value.High, Low = Value.Low - 1 }
end

local function WriteZigzag(Out: Writer, High: number, Low: number, IsNegative: boolean)
	RefuseNegativeZero(High, Low, IsNegative)
	WriteDoubled(Out, High, Low, if IsNegative then -1 else 0)
end

local function ReadZigzag(In: Reader): SignedWide
	local Doubled = ReadWide(In)
	return HalveEvenIsNegative(AddOne(Doubled))
end

local function WriteSignedNumber(Out: Writer, Value: number)
	local Magnitude = math.abs(Value)
	RequireWholeBelow(ModuleName, "the size of a signed number", Magnitude, VarintLimit)
	WriteZigzag(Out, Magnitude // WideLimb, Magnitude % WideLimb, Value < 0)
end

local function IsPlainSigned(Value: number): boolean
	return Value % 1 == 0 and Value >= PlainSignedLeast and Value < PlainSignedLimit
end

local function WritePlainSignedNumber(Out: Writer, Value: number)
	if not IsPlainSigned(Value) then
		error(PlainSignedOutOfRange)
	end
	WriteSignedNumber(Out, Value)
end

local function ReadSignedNumber(In: Reader): number
	local Signed = ReadZigzag(In)
	local Magnitude = Signed.High * WideLimb + Signed.Low
	local Value = if Signed.IsNegative then -Magnitude else Magnitude
	if not IsPlainSigned(Value) then
		Malformed(Messages.PlainVarintTooLarge)
	end
	return Value
end

local function IsMagnitudeBelow(Left: Wide, Right: Wide): boolean
	if Left.High ~= Right.High then
		return Left.High < Right.High
	end
	return Left.Low < Right.Low
end

local function IsWithinSignedLimit(Value: Wide): boolean
	return Value.High < SignedHighLimit
end

local function AddWide(Left: SignedWide, Right: SignedWide): SignedWide
	if Left.IsNegative == Right.IsNegative then
		local Low = Left.Low + Right.Low
		local High = Left.High + Right.High + Low // WideLimb
		return { IsNegative = Left.IsNegative, High = High, Low = Low % WideLimb }
	end
	local Larger = Left
	local Smaller = Right
	if IsMagnitudeBelow(Left, Right) then
		Larger = Right
		Smaller = Left
	end
	local High = Larger.High - Smaller.High
	local Low = Larger.Low - Smaller.Low
	if Low < 0 then
		High -= 1
		Low += WideLimb
	end
	local IsZero = High == 0 and Low == 0
	return { IsNegative = Larger.IsNegative and not IsZero, High = High, Low = Low }
end

return {
	WriteWide = WriteWide,
	ReadWide = ReadWide,
	RefuseNegativeZero = RefuseNegativeZero,
	WriteDoubled = WriteDoubled,
	HalveEvenIsNegative = HalveEvenIsNegative,
	AddOne = AddOne,
	SubtractOne = SubtractOne,
	WriteZigzag = WriteZigzag,
	ReadZigzag = ReadZigzag,
	WriteSignedNumber = WriteSignedNumber,
	IsPlainSigned = IsPlainSigned,
	WritePlainSignedNumber = WritePlainSignedNumber,
	ReadSignedNumber = ReadSignedNumber,
	IsWithinSignedLimit = IsWithinSignedLimit,
	AddWide = AddWide,
}
