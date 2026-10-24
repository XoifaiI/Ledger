--!strict
--!optimize 2
--!native

--[=[
	Amounts: a balance amount (spec/protocols/record/Format.md 2) on buffers. A leading varint of 0 says a
	game arithmetic's Encode text follows, any other value is the default arithmetic's integer, held as two
	limbs. Zero has one form, so a negative zero throws.

	Return type: A plain table of the four amount functions, and the SignedAmount and UnsignedAmount types.
	Example usage:
		local Out = Format.NewWriter(64)
		Amounts.WriteSignedAmount(Out, { Kind = "Default", IsNegative = true, High = 0, Low = 50 })
		Format.ToString(Out) --> "jE"
--]=]

local Format = require("./Format")
local Names = require("./Names")
local Wide = require("./Wide")

type Writer = Format.Writer
type Reader = Format.Reader

export type SignedAmount =
	{ Kind: "Default", IsNegative: boolean, High: number, Low: number }
	| { Kind: "Encoded", Text: string }

export type UnsignedAmount = { Kind: "Default", High: number, Low: number } | { Kind: "Encoded", Text: string }

local WriteVarint = Format.WriteVarint
local WriteWide = Wide.WriteWide
local ReadWide = Wide.ReadWide
local WriteDoubled = Wide.WriteDoubled
local HalveEvenIsNegative = Wide.HalveEvenIsNegative
local AddOne = Wide.AddOne
local SubtractOne = Wide.SubtractOne
local RefuseNegativeZero = Wide.RefuseNegativeZero
local WriteStored = Names.WriteStored
local ReadStored = Names.ReadStored

local function IsZeroAmount(Amount: SignedAmount | UnsignedAmount): boolean
	return Amount.Kind == "Default" and Amount.High == 0 and Amount.Low == 0
end

local function WriteSignedAmount(Out: Writer, Amount: SignedAmount)
	if Amount.Kind == "Encoded" then
		WriteVarint(Out, 0)
		WriteStored(Out, Amount.Text)
		return
	end
	RefuseNegativeZero(Amount.High, Amount.Low, Amount.IsNegative)
	WriteDoubled(Out, Amount.High, Amount.Low, if Amount.IsNegative then 0 else 1)
end

local function ReadSignedAmount(In: Reader): SignedAmount
	local Doubled = ReadWide(In)
	if Doubled.High == 0 and Doubled.Low == 0 then
		return { Kind = "Encoded", Text = ReadStored(In) }
	end
	local Half = HalveEvenIsNegative(Doubled)
	return { Kind = "Default", IsNegative = Half.IsNegative, High = Half.High, Low = Half.Low }
end

local function WriteUnsignedAmount(Out: Writer, Amount: UnsignedAmount)
	if Amount.Kind == "Encoded" then
		WriteVarint(Out, 0)
		WriteStored(Out, Amount.Text)
		return
	end
	local Next = AddOne(Amount)
	WriteWide(Out, Next.High, Next.Low)
end

local function ReadUnsignedAmount(In: Reader): UnsignedAmount
	local Next = ReadWide(In)
	if Next.High == 0 and Next.Low == 0 then
		return { Kind = "Encoded", Text = ReadStored(In) }
	end
	local Less = SubtractOne(Next)
	return { Kind = "Default", High = Less.High, Low = Less.Low }
end

return {
	IsZeroAmount = IsZeroAmount,
	WriteSignedAmount = WriteSignedAmount,
	ReadSignedAmount = ReadSignedAmount,
	WriteUnsignedAmount = WriteUnsignedAmount,
	ReadUnsignedAmount = ReadUnsignedAmount,
}
