--!strict
--!optimize 2

--[=[
	Reducers: The handful of games that the cases are written against.

	A case is about Ledger and not about the game on top of it, so the game should be the same one
	every time. Each one is pure and refuses by giving back nothing.

	Return type: A table with the reducers and the default states they read.
	Example usage:
		local Store = T:Store({ Default = Reducers.MONEY, Reducer = Reducers.Banker })
--]=]

local MONEY: any = { Gold = 0, Touches = 0 }
local WARES: any = { Gold = 0, Items = {} }
local COINS: any = { Coins = 0 }
local SHELF: any = { Stock = 10, Sold = 0, Gold = 0 }
local PLAIN: any = { Gold = 0 }
local STASH: any = { Gold = 0, Touches = 0, Blobs = {} }

local function Keep(State: any, _Op: any): any?
	return State
end

local function Banker(State: any, Op: any): any?
	if Op.Kind == "Fund" then
		if type(Op.Amount) ~= "number" then
			return nil
		end
		return { Gold = State.Gold + Op.Amount, Touches = State.Touches }
	elseif Op.Kind == "Touch" then
		return { Gold = State.Gold, Touches = State.Touches + 1 }
	elseif Op.Kind == "Stamp" then
		return { Gold = State.Gold, Touches = State.Touches }
	elseif Op.Kind == "Meddle" then
		return { Gold = State.Gold, Touches = State.Touches + 1, _Received = {}, _Held = {} }
	elseif Op.Kind == "Give" then
		local Gold = State.Gold + Op.Amount
		if Gold < 0 then
			return nil
		end
		return { Gold = Gold, Touches = State.Touches }
	end
	return nil
end

local function Stasher(State: any, Op: any): any?
	if Op.Kind == "Stash" then
		if type(Op.Blob) ~= "string" or type(Op.Slot) ~= "string" then
			return nil
		end
		local Blobs = table.clone(State.Blobs)
		Blobs[Op.Slot] = Op.Blob
		return { Gold = State.Gold, Touches = State.Touches, Blobs = Blobs }
	end

	local Next = Banker(State, Op)
	if Next == nil then
		return nil
	end
	Next.Blobs = State.Blobs
	return Next
end

local function Trader(State: any, Op: any): any?
	if Op.Kind ~= "Delta" then
		return nil
	end

	local Gold = State.Gold + (Op.Gold or 0)
	if Gold < 0 then
		return nil
	end

	local Items = table.clone(State.Items)
	if Op.Drop ~= nil then
		if not Items[Op.Drop] then
			return nil
		end
		Items[Op.Drop] = nil
	end
	if Op.Gain ~= nil then
		if Items[Op.Gain] then
			return nil
		end
		Items[Op.Gain] = true
	end

	return { Gold = Gold, Items = Items }
end

local function Vaulter(State: any, Op: any): any?
	if Op.Kind ~= "Vault" then
		return nil
	end

	local Coins = State.Coins + (Op.Coins or 0)
	if Coins < 0 then
		return nil
	end
	return { Coins = Coins }
end

local function Shopkeeper(State: any, Op: any): any?
	if Op.Kind ~= "Sell" then
		return nil
	end

	local Next = table.clone(State)
	Next.Sold += 1
	return Next
end

local function Adder(State: any, Op: any): any?
	if Op.Kind ~= "Add" or type(Op.Amount) ~= "number" then
		return nil
	end

	local Next = table.clone(State)
	Next.Gold = (Next.Gold or 0) + Op.Amount
	return Next
end

return table.freeze({
	Keep = Keep,
	Banker = Banker,
	Stasher = Stasher,
	Trader = Trader,
	Vaulter = Vaulter,
	Shopkeeper = Shopkeeper,
	Adder = Adder,

	MONEY = MONEY,
	WARES = WARES,
	COINS = COINS,
	SHELF = SHELF,
	PLAIN = PLAIN,
	STASH = STASH
})
