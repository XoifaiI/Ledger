--!strict
--!optimize 2

--[=[
	Refusals: the request errors Roblox documents as raised before the store, so the request sent nothing (data store
	reference 10): 403, Studio without API access; 101, 102 and 106, a bad key, scope or name; 103 to 105, a value too
	large or not storable. Hear says whether an error code is one, and warns the first time this server meets each code.

	Return type: A plain table with Hear.
	Example usage:
		local IsBeforeStore = Refusals.Hear(Result.Code)
--]=]

type Refusal = { read Meaning: string, read Change: string }

local KeyNameEmptyCode = 101
local KeyNameLimitCode = 102
local ValueNotAllowedCode = 103
local CantStoreValueCode = 104
local ValueTooLargeCode = 105
local RangeInvalidCode = 106
local StudioAccessCode = 403

local StudioAccess: Refusal = {
	Meaning = "StudioAccessToApisNotAllowed, Studio's API access is not enabled",
	Change = "Turn on Enable Studio Access to API Services in the experience's Security settings.",
}
local BadKey: Refusal = {
	Meaning = "a bad key, scope or name",
	Change = "Change the key, scope or name the game gives.",
}
local BadValue: Refusal = {
	Meaning = "a value too large or not storable",
	Change = "Change the value the game stores.",
}

local RefusalOfCode: { [number]: Refusal } = {
	[KeyNameEmptyCode] = BadKey,
	[KeyNameLimitCode] = BadKey,
	[ValueNotAllowedCode] = BadValue,
	[CantStoreValueCode] = BadValue,
	[ValueTooLargeCode] = BadValue,
	[RangeInvalidCode] = BadKey,
	[StudioAccessCode] = StudioAccess,
}

local Consequence = "Roblox refuses it before the store, so it sent nothing. "
	.. "Ledger answers the writes it carried Busy, and a read keeps its Unresolved."

local Warned: { [number]: true } = {}

local function WarningOf(Code: number, Found: Refusal): string
	return `Ledger: a DataStore request failed with error {Code}, {Found.Meaning}. {Consequence} {Found.Change} `
		.. "Ledger warns of this once per server and error."
end

local function Hear(Code: number?): boolean
	if Code == nil then
		return false
	end
	local Found = RefusalOfCode[Code]
	if Found == nil then
		return false
	end
	if Warned[Code] == nil then
		Warned[Code] = true
		warn(WarningOf(Code, Found))
	end
	return true
end

return {
	Hear = Hear,
}
