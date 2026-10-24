--!strict
--!optimize 2

--[=[
	Verdicts: the frozen verdicts of J.9 that carry no data, one value each, shared by Decide and the part's rules.

	Return type: A frozen table of the verdicts.
	Example usage:
		return Verdicts.Refused
--]=]

local JudgingShapes = require("./Shapes")

type Verdict = JudgingShapes.Verdict

local NoState: Verdict = table.freeze({ Kind = "NoState" :: "NoState" })
local Unstorable: Verdict = table.freeze({ Kind = "Unstorable" :: "Unstorable" })
local Refused: Verdict = table.freeze({ Kind = "Refused" :: "Refused" })
local Full: Verdict = table.freeze({ Kind = "Full" :: "Full" })
local Unreadable: Verdict = table.freeze({ Kind = "Unreadable" :: "Unreadable" })
local Invalid: Verdict = table.freeze({ Kind = "Invalid" :: "Invalid" })
local InvalidBalance: Verdict = table.freeze({ Kind = "InvalidBalance" :: "InvalidBalance" })

return table.freeze({
	NoState = NoState,
	Unstorable = Unstorable,
	Refused = Refused,
	Full = Full,
	Unreadable = Unreadable,
	Invalid = Invalid,
	InvalidBalance = InvalidBalance,
})
