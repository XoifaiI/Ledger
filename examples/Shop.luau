--!strict

--[=[
    Shop: the everyday Apply path, and the one rule that matters.

    A purchase is one op, never two. The reducer checks the cost and writes what was bought in
    the same step, so a refusal takes the whole thing with it and there is no state where the
    player paid and got nothing.

    these are illustrations, not modules. they assume the player is loaded and skip everything
    that is not Ledger.
--]=]

local Ledger = require("../src")

export type Profile = {
	Gold: number,
	Items: { [string]: boolean },
}

local Prices = {
	Sword = 100,
	Shield = 250,
}

--[[
    the reducer branches these examples need.

    an op is { Id, Kind, ...whatever you passed }, so its fields are unknown to the checker.
    read them into a typed local at the top of the branch. that is the annotation and the
    validation in one place, and everything below it is checked normally.
--]]

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	if Op.Kind == "Buy" then
		local Item = Op.Item :: string
		local Cost = Prices[Item]

		if Cost == nil or Cost > State.Gold or State.Items[Item] then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold -= Cost
		Next.Items = table.clone(State.Items)
		Next.Items[Item] = true
		return Next
	elseif Op.Kind == "Sell" then
		local Item = Op.Item :: string
		local Cost = Prices[Item]

		if Cost == nil or not State.Items[Item] then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold += Cost // 2
		Next.Items = table.clone(State.Items)
		Next.Items[Item] = nil
		return Next
	end

	return nil
end

--[[ the call site ]]

local function Buy(Session: Ledger.Session<Profile>, Item: string): (boolean, Ledger.Reason?)
	return Session:Apply("Buy", { Item = Item })
end

local function Sell(Session: Ledger.Session<Profile>, Item: string): (boolean, Ledger.Reason?)
	return Session:Apply("Sell", { Item = Item })
end

--[[
    what not to do. these are two ops, so the fold can refuse the payment at its position and
    accept the grant, and the player gets a free sword.

        Session:Apply("SpendGold", { Amount = 100 })
        Session:Apply("GrantItem", { Item = "Sword" })

    the price lives in the reducer, not the op. an op that carries its own price is a client
    controlled price, and an op that says "grant whatever the shop table says" means something
    different every time you rebalance.
--]]

return table.freeze({
	Reducer = Reducer,
	Buy = Buy,
	Sell = Sell,
})
