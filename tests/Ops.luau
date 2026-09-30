--!strict

--[=[

	Ops: The cases for Store/Ops.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Limits = require("../src/Core/Constants/Limits")
local Ops = require("../src/Store/Ops")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local EPOCH = Limits.EPOCH
local ONCE = `Ledger: Once has to be a string of 1 to {Limits.NAME_BYTES} bytes`

Describe("Ops", function()
	Test("an op with no Once is minted, with Once and OnceAt timed, and with Once alone untimed", function()
		local Minted = Ops.Durable("Add", { Add = 1 }, false) :: any
		Expect(Minted.Form).toBe("Minted")
		Expect(Minted.Name).toBeNil()
		local Timed = Ops.Durable("Add", { Add = 1, Once = "r1", OnceAt = EPOCH + 100 }, true) :: any
		Expect(Timed.Form).toBe("Timed")
		Expect(Timed.Stamp).toBe(100)
		Expect(Timed.Kind).toBe(Ops.Kind("Add"))
		Expect(Timed.MustExist).toBe(true)
		Expect(Timed.Body.Once).toBeNil()
		local Untimed = Ops.Durable("Add", { Add = 1, Once = "r1" }, false) :: any
		Expect(Untimed.Form).toBe("Untimed")
		Expect(Untimed.Stamp).toBeNil()
		Expect(Untimed.Print).toBe(Timed.Print)
		Expect((Ops.Durable("Add", { Add = 2, Once = "r1" }, false) :: any).Print).never.toBe(Timed.Print)
		Expect(Ops.Durable("Add", { Add = 1, Tag = print }, false)).toBeNil()
	end)

	Test("a bad Once or OnceAt throws at the call", function()
		Expect(function()
			Ops.Durable("Add", { Once = "" }, false)
		end).toThrow(ONCE)
		Expect(function()
			Ops.Durable("Add", { Once = string.rep("x", Limits.NAME_BYTES + 1) }, false)
		end).toThrow(ONCE)
		Expect(function()
			Ops.Durable("Add", { Once = "r1", OnceAt = EPOCH - 1 }, false)
		end).toThrow("Ledger: OnceAt has to be the whole unix time the name was first sent")
		Expect(function()
			Ops.Durable("Add", { OnceAt = EPOCH }, false)
		end).toThrow("Ledger: OnceAt needs a Once")
		Expect(function()
			Ops.Name(5)
		end).toThrow(ONCE)
		Expect(Ops.Stamp(EPOCH + 7)).toBe(7)
	end)
end)

return nil
