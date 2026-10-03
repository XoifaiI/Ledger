--!strict
--!optimize 2

--[=[
	Marks: Logic. What the transaction marks on a key allow.

	A money field beside escrow marks has a least and a most value, whichever way each mark ends.
	Bounds gives nil for both when the field is not a number or this build does not know it. A game
	op may land beside escrow marks only when its verdict does not depend on how they end. Order runs
	the reducer on the state with each subset of the amounts laid on. Every run must give the same
	verdict, and results that differ only by those amounts. An exclusive mark blocks every game op.
	More than ORDER_MARKS escrow marks block it too, since the runs double with each mark.

	Return type: The Marks module.
	Example usage:
		local Blockers = Marks.Order(Work, Build, Reducer, State, Body)
--]=]

local Book = require("./Book")
local Reduce = require("../Core/Reduce")
local Types = require("./Types")

type Build = Types.Build
type State = { [string]: any }
type Items = { [string]: Book.Work }

local WorkForm = Book.WorkForm

local ORDER_MARKS = 3

local Marks = {}

local function Equal(Left: unknown, Right: unknown): boolean
	if Left == Right then
		return true
	elseif type(Left) == "buffer" and type(Right) == "buffer" then
		return buffer.tostring(Left) == buffer.tostring(Right)
	elseif type(Left) ~= "table" or type(Right) ~= "table" then
		return false
	end
	local Other = Right :: { [any]: unknown }
	for Key, Value in Left :: { [any]: unknown } do
		if not Equal(Value, Other[Key]) then
			return false
		end
	end
	for Key in Other do
		if (Left :: { [any]: unknown })[Key] == nil then
			return false
		end
	end
	return true
end

local function Shift(Base: State, Build: Build, Escrows: { Book.Escrow }, Mask: number): State?
	local Shifted = Reduce.Copy(Base)
	for Index, Mark in Escrows do
		if not bit32.btest(Mask, bit32.lshift(1, Index - 1)) then
			continue
		end
		local Field = Build.Money[Mark.Field]
		local Amount = if Field then Shifted[Field] else nil
		if type(Amount) ~= "number" then
			return nil
		end
		Shifted[Field] = Amount + Mark.Amount
	end
	return Shifted
end

function Marks.Bounds(Work: Items, State: State, Build: Build, Field: number): (number?, number?)
	local Amount = if Build.Money[Field] then State[Build.Money[Field]] else nil
	if type(Amount) ~= "number" then
		return nil, nil
	end
	local Low, High = Amount, Amount
	for _, Item in Work do
		if Item.Form == WorkForm.Escrow and Item.Field == Field then
			if Item.Amount < 0 then
				Low += Item.Amount
			else
				High += Item.Amount
			end
		end
	end
	return Low, High
end

function Marks.Order(Work: Items, Build: Build, Reducer: Reduce.Reducer<any, any>, State: State, Body: unknown): Items?
	local Escrows: { Book.Escrow } = {}
	local Found = Book.Marks(Work)
	for _, Item in Found do
		if Item.Form == WorkForm.Exclusive then
			return Found
		elseif Item.Form == WorkForm.Escrow then
			table.insert(Escrows, Item)
		end
	end
	if #Escrows == 0 then
		return nil
	elseif #Escrows > ORDER_MARKS then
		return Found
	end
	local Base, _, Why = Reduce.Run(Reducer, Reduce.Copy(State), Body)
	for Mask = 1, bit32.lshift(1, #Escrows) - 1 do
		local Shifted = Shift(State, Build, Escrows, Mask)
		if Shifted == nil then
			return Found
		end
		local Next, _, Reason = Reduce.Run(Reducer, Shifted, Body)
		if (Next == nil) ~= (Base == nil) or Reason ~= Why then
			return Found
		elseif Next and Base and not Equal(Next, Shift(Base, Build, Escrows, Mask)) then
			return Found
		end
	end
	return nil
end

function Marks.Unclean(Work: Items, Except: string?)
	for Name, Item in Work do
		local Mark = Book.AsMark(Item)
		if Mark and Name ~= Except then
			Mark.Clean = false
		end
	end
end

return Marks
