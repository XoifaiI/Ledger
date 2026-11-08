--!strict
--!optimize 2
--!native

--[=[
	Float: a JSON number that is not a whole number below 2^53, written as %g at the shortest precision that
	reads back, with a bare exponent (1e-5). A subnormal of either sign is 0, as JSONDecode reads it; every
	other double gives the bytes of the %.1g to %.17g loop.

	A value from 1e-4 to 2^36 with at most 4 decimals comes from one division check, any other from tostring's
	Schubfach digits in %g's form, except an exact power of two outside 1e-4 to 2^53, which keeps %.15g to %.17g,
	since there Schubfach's shortest is not always %g's. DecimalBase is kept local so it folds.

	Return type: A table with WriteFloat.
	Example usage:
		Float.WriteFloat(Out, 12.34) --> writes 12.34
--]=]

local Format = require("./Format")
local Record = require("../Constants/Record")

type Writer = Format.Writer

local Grow = Format.Grow

local MinusByte = Record.MinusByte
local PlusByte = string.byte("+")
local PointByte = string.byte(".")
local ZeroByte = Record.ZeroByte
local ExponentByte = string.byte("e")

local DecimalBase = 10
local PairBase = DecimalBase * DecimalBase
local PairShrink = 1 / PairBase
local PairBytes = 2
local PairDigits = buffer.create(PairBase * PairBytes)
local PairTrailing = buffer.create(PairBase)
for Pair = 0, PairBase - 1 do
	buffer.writeu8(PairDigits, Pair * PairBytes, ZeroByte + Pair // DecimalBase)
	buffer.writeu8(PairDigits, Pair * PairBytes + 1, ZeroByte + Pair % DecimalBase)
	buffer.writeu8(PairTrailing, Pair, if Pair == 0 then PairBytes elseif Pair % DecimalBase == 0 then 1 else 0)
end

local ExponentLeast = -1022
local SmallestNormal = 2 ^ ExponentLeast
local DoubleBytes = 8
local HighWordAt = 4
local MantissaHighBits = 20
local MantissaHighMask = 2 ^ MantissaHighBits - 1
local Bits = buffer.create(DoubleBytes)

local FixedLow = 1e-4
local FixedHigh = Record.VarintLimit

local ShortPlaces = 4
local ShortScale = DecimalBase ^ ShortPlaces
local ScaledBits = 50
local ShortHigh = 2 ^ math.floor(ScaledBits - math.log(ShortScale, 2))
local WholeDigitsMost = math.ceil(math.log10(ShortHigh))
local ShortTextMost = 1 + WholeDigitsMost + 1 + ShortPlaces

local ShortestPrecision = "%.15g"
local MiddlePrecision = "%.16g"
local LongestPrecision = "%.17g"

local NumberTextMost = 48
local SignificantDigitsMost = 17
local ExponentDigitsMost = 3
local FixedLowestLead = -4
local WideTextMost = 1 + SignificantDigitsMost + 1 + 1 + 1 + ExponentDigitsMost
local Parsed = buffer.create(NumberTextMost)

local function PutDigits(Buffer: buffer, End: number, Value: number, Count: number): ()
	local Remaining = Value
	local At = End
	for _ = 1, bit32.rshift(Count, 1) do
		local Higher = math.floor(Remaining * PairShrink)
		At -= PairBytes
		buffer.writeu16(Buffer, At, buffer.readu16(PairDigits, (Remaining - Higher * PairBase) * PairBytes))
		Remaining = Higher
	end
	if bit32.btest(Count, 1) then
		buffer.writeu8(Buffer, At - 1, ZeroByte + Remaining)
	end
end

local function WriteText(Out: Writer, Text: string): ()
	local Length = string.len(Text)
	local Cursor = Out.Cursor
	if Cursor + Length > Out.Size then
		Grow(Out, Cursor, Length)
	end
	buffer.writestring(Out.Buffer, Cursor, Text)
	Out.Cursor = Cursor + Length
end

local function ShortcutText(Value: number): string
	local Text = string.format(ShortestPrecision, Value)
	if tonumber(Text) == Value then
		return Text
	end
	Text = string.format(MiddlePrecision, Value)
	if tonumber(Text) == Value then
		return Text
	end
	return string.format(LongestPrecision, Value)
end

local function WriteWide(Out: Writer, Value: number, Magnitude: number): ()
	local Cursor = Out.Cursor
	if Cursor + WideTextMost > Out.Size then
		Grow(Out, Cursor, WideTextMost)
	end
	local Buffer = Out.Buffer
	if Magnitude < SmallestNormal then
		buffer.writeu8(Buffer, Cursor, ZeroByte)
		Out.Cursor = Cursor + 1
		return
	end
	buffer.writef64(Bits, 0, Magnitude)
	local PowerOfTwo = buffer.readu32(Bits, 0) == 0
		and bit32.band(buffer.readu32(Bits, HighWordAt), MantissaHighMask) == 0
	local Text = if PowerOfTwo then ShortcutText(Value) else tostring(Value)

	local Length = string.len(Text)
	local Count = 0
	local PointAt: number? = nil
	local Exponent = 0
	local At = 1
	if Value < 0 then
		buffer.writeu8(Buffer, Cursor, MinusByte)
		Cursor += 1
		At += 1
	end
	while At <= Length do
		local Byte = string.byte(Text, At)
		At += 1
		if Byte == PointByte then
			PointAt = Count
		elseif Byte == ExponentByte then
			local Negative = string.byte(Text, At) == MinusByte
			if Negative or string.byte(Text, At) == PlusByte then
				At += 1
			end
			while At <= Length do
				Exponent = Exponent * DecimalBase + string.byte(Text, At) - ZeroByte
				At += 1
			end
			if Negative then
				Exponent = -Exponent
			end
		else
			buffer.writeu8(Parsed, Count, Byte)
			Count += 1
		end
	end
	local WholeDigits = if PointAt ~= nil then PointAt else Count

	local First = 0
	local Lead = WholeDigits - 1 + Exponent
	while buffer.readu8(Parsed, First) == ZeroByte do
		First += 1
		Lead -= 1
	end
	local Last = Count - 1
	while buffer.readu8(Parsed, Last) == ZeroByte do
		Last -= 1
	end
	local Precision = Last - First + 1

	if Lead < FixedLowestLead or Lead >= Precision then
		buffer.writeu8(Buffer, Cursor, buffer.readu8(Parsed, First))
		Cursor += 1
		if Precision > 1 then
			buffer.writeu8(Buffer, Cursor, PointByte)
			buffer.copy(Buffer, Cursor + 1, Parsed, First + 1, Precision - 1)
			Cursor += Precision
		end
		buffer.writeu8(Buffer, Cursor, ExponentByte)
		Cursor += 1
		if Lead < 0 then
			buffer.writeu8(Buffer, Cursor, MinusByte)
			Cursor += 1
		end
		local Size = math.abs(Lead)
		local Width = 1
		local Place = DecimalBase
		while Size >= Place do
			Width += 1
			Place *= DecimalBase
		end
		Cursor += Width
		PutDigits(Buffer, Cursor, Size, Width)
	elseif Lead >= 0 then
		buffer.copy(Buffer, Cursor, Parsed, First, Lead + 1)
		Cursor += Lead + 1
		if Precision > Lead + 1 then
			buffer.writeu8(Buffer, Cursor, PointByte)
			buffer.copy(Buffer, Cursor + 1, Parsed, First + Lead + 1, Precision - Lead - 1)
			Cursor += Precision - Lead
		end
	else
		buffer.writeu8(Buffer, Cursor, ZeroByte)
		buffer.writeu8(Buffer, Cursor + 1, PointByte)
		Cursor += PairBytes
		for _ = 1, -Lead - 1 do
			buffer.writeu8(Buffer, Cursor, ZeroByte)
			Cursor += 1
		end
		buffer.copy(Buffer, Cursor, Parsed, First, Precision)
		Cursor += Precision
	end
	Out.Cursor = Cursor
end

local function WriteFloat(Out: Writer, Value: number): ()
	local Magnitude = math.abs(Value)
	if Magnitude >= FixedLow and Magnitude < FixedHigh then
		if Magnitude < ShortHigh then
			local Scaled = math.round(Magnitude * ShortScale)
			if Scaled / ShortScale == Magnitude then
				local Cursor = Out.Cursor
				if Cursor + ShortTextMost > Out.Size then
					Grow(Out, Cursor, ShortTextMost)
				end
				local Buffer = Out.Buffer
				if Value < 0 then
					buffer.writeu8(Buffer, Cursor, MinusByte)
					Cursor += 1
				end
				local Whole = math.floor(Magnitude)
				local Fraction = Scaled - Whole * ShortScale
				local High = math.floor(Fraction * PairShrink)
				local Low = Fraction - High * PairBase
				local Width = 1
				local Place = DecimalBase
				while Whole >= Place do
					Width += 1
					Place *= DecimalBase
				end
				local Point = Cursor + Width
				local At = Point
				local Remaining = Whole
				while Remaining >= PairBase do
					local Higher = math.floor(Remaining * PairShrink)
					At -= PairBytes
					buffer.writeu16(Buffer, At, buffer.readu16(PairDigits, (Remaining - Higher * PairBase) * PairBytes))
					Remaining = Higher
				end
				if Remaining >= DecimalBase then
					buffer.writeu16(Buffer, At - PairBytes, buffer.readu16(PairDigits, Remaining * PairBytes))
				else
					buffer.writeu8(Buffer, At - 1, ZeroByte + Remaining)
				end
				buffer.writeu8(Buffer, Point, PointByte)
				buffer.writeu16(Buffer, Point + 1, buffer.readu16(PairDigits, High * PairBytes))
				buffer.writeu16(Buffer, Point + 1 + PairBytes, buffer.readu16(PairDigits, Low * PairBytes))
				local Trailing = buffer.readu8(PairTrailing, Low)
				if Low == 0 then
					Trailing += buffer.readu8(PairTrailing, High)
				end
				Out.Cursor = Point + 1 + ShortPlaces - Trailing
				return
			end
		end
		WriteText(Out, tostring(Value))
		return
	end
	WriteWide(Out, Value, Magnitude)
end

return {
	WriteFloat = WriteFloat,
}
