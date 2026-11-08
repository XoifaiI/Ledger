--!strict
--!optimize 2

--[=[
	Messages: the texts that two or more files use. A text only one file uses sits at the top of that file.
	A text that names a limit is built from the constant, so it cannot say a number the code does not hold.

	Return type: A frozen table of texts, and functions that build a text from the values they name.
	Example usage:
		local Messages = require("./Constants/Messages")
		local Record = require("./Constants/Record")
		error(Messages.NotWholeBelow("Format", "a varint", Record.VarintLimit, Value))
--]=]

local Record = require("./Record")

local VarintLimitText = string.format("%.0f", Record.VarintLimit)

local EndsEarly = "the bytes end before the value does"
local OutsideAlphabet = "a character is not one of the alphabet's 64"
local LeadingZeroDigit = "a varint starts with a zero digit, which the writer never writes"
local PlainVarintTooLarge = `a plain varint is {VarintLimitText} or more`

local KeepInRange = "The caller must keep it in range"

local KickMessageDefault = "Your data could not be loaded. Please rejoin."

local function OpsUnheard(Count: number): string
	return `Ledger: CloseAll ended with {Count} ops and transactions not heard. `
		.. "The calls of the durable ones and of the transactions that sent a request are answered Unresolved, "
		.. "those that sent nothing Closed, and the fates of the hopeful ones are unknown"
end

local function NotWholeBelow(Where: string, What: string, Limit: number, Got: number): string
	return `{Where}: {What} is a whole number from 0 below {string.format("%.0f", Limit)}, got {Got}. {KeepInRange}`
end

return table.freeze({
	EndsEarly = EndsEarly,
	OutsideAlphabet = OutsideAlphabet,
	LeadingZeroDigit = LeadingZeroDigit,
	PlainVarintTooLarge = PlainVarintTooLarge,
	KeepInRange = KeepInRange,
	KickMessageDefault = KickMessageDefault,
	NotWholeBelow = NotWholeBelow,
	OpsUnheard = OpsUnheard,
})
