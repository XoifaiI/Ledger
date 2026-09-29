--!strict

--[=[

	Testing: Zune's test functions under plain types, and the globals Roblox has and Zune does not.

	Zune types expect as an overloaded function joined with a table, which the new solver refuses to
	call. This gives the same functions one signature each. Similar matches a table by what it holds.
	Zune keeps Roblox's task library under zune.task and has no warn, so this puts task where source
	looks for it and a warn that records what it is given. Heard gives back what was warned since it
	was last called. The game it puts in place has only EncodingService, which hashes with Zune's
	Blake3, and Enum has only HashAlgorithm.Blake3.

	Return type: A table with Describe, Test, Expect, Similar and Heard.
	Example usage:
		local Testing = require("./Testing")
		local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect
		Expect(1 + 1).toBe(2)
--]=]

export type Matchers = {
	toBe: (Expected: any) -> (),
	toBeNil: () -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toBeGreaterThan: (Expected: number) -> (),
	toBeLessThan: (Expected: number) -> (),
	toHaveLength: (Expected: number) -> (),
	toThrow: (Message: string?) -> (),
	never: Matchers,
}

local Zune = zune.testing :: any
local Said: { string } = {}

local function Warn(...: any)
	local Parts = table.pack(...)
	for Index = 1, Parts.n do
		Parts[Index] = tostring(Parts[Index])
	end
	table.insert(Said, table.concat(Parts, " ", 1, Parts.n))
end

local function Heard(): { string }
	local Copy = table.clone(Said)
	table.clear(Said)
	return Copy
end

local EncodingService = table.freeze({
	ComputeStringHash = function(_: any, Text: string, _Algorithm: any): string
		local Held = zune.crypto.createHash("blake3")
		Held:update(Text)
		return buffer.tostring(Held:digest("binary"))
	end,
})

local Game = table.freeze({
	GetService = function(_: any, Name: string): any
		return assert(if Name == "EncodingService" then EncodingService else nil, `Testing: no service {Name}`)
	end,
})

local Globals = _G :: any
Globals.task = zune.task
Globals.warn = Warn
Globals.game = Game
Globals.Enum = table.freeze({ HashAlgorithm = table.freeze({ Blake3 = "Blake3" }) })

return table.freeze({
	Describe = Zune.describe :: (Name: string, Body: () -> ()) -> (),
	Test = Zune.test :: (Name: string, Body: () -> ()) -> (),
	Expect = Zune.expect :: (Value: any) -> Matchers,
	Similar = Zune.expect.similar :: (Expected: any) -> any,
	Heard = Heard,
})
