--!strict

--[=[

	Reduce: The cases for Core/Reduce.

	Mutating changes the state it is given and often refuses only after it has changed it. Cloning is
	the same rules written the way Ledger reducers are written today, and Plain folds with it in a
	loop that shares nothing with Reduce. A fold with Mutating has to end where Plain ends and take
	the same ops.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Canon = require("../src/Encode/Canon")
local Reduce = require("../src/Core/Reduce")

local Describe, Test, Expect, Similar, Heard = Testing.Describe, Testing.Test, Testing.Expect, Testing.Similar, Testing.Heard

type Item = { Count: number }
type State = { Gold: number, Items: { [string]: Item } }
type Op = { Kind: string, Amount: number?, Id: string?, Item: Item? }

local KINDS = { "Add", "Spend", "Put", "Bump", "Throw", "Yield", "Bad" }

local function Mutating(State: State, Op: Op): State?
	if Op.Kind == "Add" then
		State.Gold += Op.Amount :: number
		return State
	elseif Op.Kind == "Spend" then
		State.Gold -= Op.Amount :: number
		return if State.Gold >= 0 then State else nil
	elseif Op.Kind == "Put" then
		State.Items[Op.Id :: string] = Op.Item :: Item
		return State
	elseif Op.Kind == "Bump" then
		local Held = State.Items[Op.Id :: string]
		if Held == nil then
			return nil
		end
		Held.Count += 1
		return State
	elseif Op.Kind == "Throw" then
		State.Gold = -999
		error("refused by throwing", 0)
	elseif Op.Kind == "Yield" then
		State.Gold = -999
		coroutine.yield()
		return State
	elseif Op.Kind == "Bad" then
		State.Gold = -999
		return 5 :: any
	end
	return nil
end

local function Cloning(State: State, Op: Op): State?
	if Op.Kind == "Add" then
		local Next = table.clone(State)
		Next.Gold += Op.Amount :: number
		return Next
	elseif Op.Kind == "Spend" then
		if State.Gold < Op.Amount :: number then
			return nil
		end
		local Next = table.clone(State)
		Next.Gold -= Op.Amount :: number
		return Next
	elseif Op.Kind == "Put" then
		local Next = table.clone(State)
		Next.Items = table.clone(State.Items)
		Next.Items[Op.Id :: string] = Op.Item :: Item
		return Next
	elseif Op.Kind == "Bump" then
		local Held = State.Items[Op.Id :: string]
		if Held == nil then
			return nil
		end
		local Next = table.clone(State)
		Next.Items = table.clone(State.Items)
		Next.Items[Op.Id :: string] = { Count = Held.Count + 1 }
		return Next
	end
	return nil
end

local function Plain(Start: State, Ops: { Op }): (State, { boolean })
	local State, Took = Start, {}
	for Index, Op in Ops do
		local Next = Cloning(State, table.clone(Op))
		Took[Index] = Next ~= nil
		State = Next or State
	end
	return State, Took
end

local function Base(): State
	return { Gold = 10, Items = { a = { Count = 0 } } }
end

local function Batch(Size: number): { Op }
	local Ops: { Op } = {}
	for _ = 1, Size do
		local Kind = KINDS[math.random(1, #KINDS)]
		local Id = `i{math.random(1, 4)}`
		table.insert(Ops, { Kind = Kind, Amount = math.random(1, 15), Id = Id, Item = { Count = math.random(0, 3) } })
	end
	return Ops
end

Describe("Reduce", function()
	Test("a reducer that changes its state takes the same ops as one that clones", function()
		math.randomseed(11)
		local Wrong = 0
		for _ = 1, 300 do
			local Ops = Batch(math.random(1, 12))
			local Start = Base()
			local Before = Canon(Start)
			local Mutated, TookMutating = Reduce.Fold(Start, Ops, Mutating)
			local Cloned, TookCloning = Plain(Base(), Ops)
			if Canon(Mutated) ~= Canon(Cloned) or Canon(TookMutating) ~= Canon(TookCloning) or Canon(Start) ~= Before then
				Wrong += 1
			end
		end
		Expect(Wrong).toBe(0)
	end)

	Test("a refused op leaves nothing behind, however it refused", function()
		local Ops: { Op } = {
			{ Kind = "Add", Amount = 5 },
			{ Kind = "Spend", Amount = 100 },
			{ Kind = "Throw" },
			{ Kind = "Yield" },
			{ Kind = "Bad" },
			{ Kind = "Spend", Amount = 3 },
		}
		local State, Took = Reduce.Fold(Base(), Ops, Mutating)
		Expect(State.Gold).toBe(12)
		Expect(Took).toBe(Similar({ true, false, false, false, false, true }))
	end)

	Test("a state that kept part of an op cannot be changed through it before a rebuild", function()
		local Ops: { Op } = {
			{ Kind = "Put", Id = "b", Item = { Count = 0 } },
			{ Kind = "Bump", Id = "b" },
			{ Kind = "Spend", Amount = 100 },
		}
		local State = Reduce.Fold(Base(), Ops, Mutating)
		Expect(State.Items.b.Count).toBe(1)
	end)

	Test("a reducer that writes and refuses on a rebuild what it took before is called out", function()
		Heard()
		local Runs = 0
		local function Fickle(State: State, Op: Op): State?
			if Op.Kind == "Spend" then
				return nil
			end
			State.Gold += 1
			Runs += 1
			return if Runs <= 2 then State else nil
		end
		local Ops: { Op } = { { Kind = "Add" }, { Kind = "Spend" } }
		Reduce.Fold(Base(), Ops, Fickle)
		Expect(#Heard()).toBe(1)
	end)

	Test("a reducer that clones stays on the frozen path and one that writes moves off it", function()
		local Adds: { Op } = { { Kind = "Add", Amount = 1 } }
		local Cloned = Reduce.Fold(Base(), Adds, Cloning)
		Expect(table.isfrozen(Cloned)).toBe(true)
		local Mutated = Reduce.Fold(Base(), Adds, Mutating)
		Expect(table.isfrozen(Mutated)).toBe(false)
		Expect(Mutated.Gold).toBe(11)
	end)

	Test("a snapshot is a frozen copy all the way down", function()
		local State = Base()
		local Seen = Reduce.Snapshot(State)
		Expect(Canon(Seen)).toBe(Canon(State))
		Expect(table.isfrozen(Seen)).toBe(true)
		Expect(table.isfrozen(Seen.Items.a)).toBe(true)
		State.Items.a.Count = 9
		Expect(Seen.Items.a.Count).toBe(0)
	end)
end)

return nil
