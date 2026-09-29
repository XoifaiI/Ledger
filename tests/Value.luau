--!strict

--[=[

	Value: The cases for Encode/Value.

	Zune's json encoder is not Roblox's, so it checks the counts for what both write the same way:
	strings, whole numbers, booleans and nested tables.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Limits = require("../src/Core/Constants/Limits")
local Value = require("../src/Encode/Value")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local function Json(Item: any): number
	return #zune.serde.json.encode(Item)
end

local function Nested(Depth: number): { any }
	local Root: { any } = {}
	local Inner = Root
	for _ = 2, Depth do
		local Deeper: { any } = {}
		Inner[1] = Deeper
		Inner = Deeper
	end
	return Root
end

Describe("Value", function()
	Test("a value counts the bytes its json takes", function()
		local Values: { any } = {
			"",
			"plain",
			'a "quoted" \\ word',
			"tab\tnew\nline\rfeed\f\b",
			"\1\2\31",
			"é 日本 😀 / slash",
			`{string.rep("x", 1000)}"`,
			0,
			7,
			10,
			99,
			123456,
			-5,
			2 ^ 53 - 1,
			-(2 ^ 53 - 1),
			true,
			false,
			{},
			{ 1, 2, 3 },
			{ a = 1, b = "two", c = { true, false, { d = "" } } },
			{ ['key with "quotes"'] = { 1, { x = 2 } } },
		}
		local Wrong = 0
		for _, Item in Values do
			if Value.Check(Item) ~= Json(Item) then
				Wrong += 1
				print(`count differs for {zune.serde.json.encode(Item)}: {Value.Check(Item)}`)
			end
		end
		Expect(Wrong).toBe(0)
	end)

	Test("a count is never low for a number json may write longer", function()
		for _, Number in { 0.1, 1 / 3, 1.5e-7, -1.2345678901234567e-300, 5e-324, 1e20, 1e300, -2 ^ 60 } do
			Expect((Value.Check(Number) :: number) >= Json(Number)).toBe(true)
		end
		Expect((Value.Check(-0))).toBe(2)
	end)

	Test("a buffer is charged its raw bytes, or what compress gives back past the size worth it", function()
		local function Compress(_: buffer): number
			return 100
		end
		Expect((Value.Check(buffer.create(10)))).toBe(35 + 4 * 4)
		Expect((Value.Check(buffer.create(10), Compress))).toBe(35 + 4 * 4)
		Expect((Value.Check(buffer.create(5000)))).toBe(35 + 4 * 1667)
		Expect((Value.Check(buffer.create(5000), Compress))).toBe(35 + 4 * 34)
	end)

	Test("a value a datastore cannot hold is refused with where", function()
		local Cyclic: { [string]: any } = {}
		Cyclic.Self = Cyclic
		local Refused: { { any } } = {
			{ 0 / 0, "value is nan or inf" },
			{ -math.huge, "value is nan or inf" },
			{ "\255", "value is not valid utf8" },
			{ { a = print }, "value.a is a function" },
			{ { a = { { b = 0 / 0 } } }, "value.a[1].b is nan or inf" },
			{ { 1, a = 2 }, "value mixes array and string keys" },
			{ { [1] = 1, [3] = 3 }, "value is an array with a gap" },
			{ { [0] = 1 }, "value has the key 0, which is not a string or a whole number from 1" },
			{ { [1.5] = 1 }, "value has the key 1.5, which is not a string or a whole number from 1" },
			{ { [true] = 1 }, "value has the key true, which is not a string or a whole number from 1" },
			{ { ["\255"] = 1 }, "value has a key that is not valid utf8" },
			{ setmetatable({}, {}), "value has a metatable" },
		}
		for _, Case in Refused do
			local Bytes, Where = Value.Check(Case[1])
			Expect(Bytes).toBeNil()
			Expect(Where).toBe(Case[2])
		end
		local _, Where = Value.Check(Cyclic)
		Expect(string.sub(Where :: string, -37)).toBe("nests deeper than 64, or holds itself")
	end)

	Test("a value may nest as deep as the limit and no deeper", function()
		Expect((Value.Check(Nested(Limits.DEPTH_MAX)))).never.toBeNil()
		Expect((Value.Check(Nested(Limits.DEPTH_MAX + 1)))).toBeNil()
	end)
end)

return nil
