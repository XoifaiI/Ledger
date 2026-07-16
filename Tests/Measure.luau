--!strict

local HttpService = game:GetService("HttpService")

local Measure = require("../src/Measure")
local Testing = require("./Testing")

local Expect = Testing.Expect

local Suite = {}

function Suite.MeasureNumbers()
	Expect(Measure(5)).ToBe(1)
	Expect(Measure(0)).ToBe(1)
	Expect(Measure(-42)).ToBe(3)
	Expect(Measure(1234567890)).ToBe(10)
	Expect(Measure(1234567890123)).ToBe(13)
	Expect(Measure(0.5)).ToBeGreaterThanOrEqual(3)
end

function Suite.MeasureConservative()
	Expect(Measure("abc")).ToBe(5)
	Expect(Measure(string.rep('"', 100))).ToBe(202)
	Expect(Measure(string.rep("\1", 100))).ToBe(602)
	Expect(Measure(false)).ToBe(5)
	Expect(Measure({ a = "x" })).ToBeGreaterThanOrEqual(9)
end

function Suite.MeasureUpperBoundsJson()
	local Record = {
		Snapshot = { Gold = 5, Name = "abc", Flag = true, Nested = { List = { 1, 22, 333 } } },
		Ops = { { Id = "op:1", Kind = "Add", Amount = 250 } },
		Seen = { "a\nb", 'quo"te', "plain" },
	}

	Expect(Measure(Record)).ToBeGreaterThanOrEqual(#HttpService:JSONEncode(Record))
end

return table.freeze(Suite)
