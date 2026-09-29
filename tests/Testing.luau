--!strict

--[=[

	Testing: Zune's test functions under plain types.

	Zune types expect as an overloaded function joined with a table, which the new solver refuses to
	call. This gives the same functions one signature each. Similar matches a table by what it holds.

	Return type: A table with Describe, Test, Expect and Similar.
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

return table.freeze({
	Describe = Zune.describe :: (Name: string, Body: () -> ()) -> (),
	Test = Zune.test :: (Name: string, Body: () -> ()) -> (),
	Expect = Zune.expect :: (Value: any) -> Matchers,
	Similar = Zune.expect.similar :: (Expected: any) -> any,
})
