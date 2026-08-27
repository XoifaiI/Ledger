--!strict

--[=[
    Typed: naming your ops, so a write is checked and a reducer needs no casts.

    Ledger.New takes any kind and any fields. That is the right thing when a store is young and the
    ops are still moving around, and it is what every other example here uses.

    Ledger.NewTyped takes a map of the kinds this store writes and what each one carries. A kind is
    then held against the kinds that exist, the fields against what that kind carries, and a reducer
    that tests Op.Kind reads the fields of that arm directly. Nothing changes when it runs. The two
    build the same store.

    these are illustrations, not modules.
--]=]

local Ledger = require("../src")

export type Profile = {
	Gold: number,
	Items: { [string]: boolean },
}

--[[ the ops this store writes, and what each one carries ]]

export type Ops = {
	Buy: { Item: string },
	Sell: { Item: string },
	AddGold: { Amount: number },
}

local Prices: { [string]: number } = {
	Sword = 100,
	Shield = 250,
}

--[[
    the reducer. every field is read off the arm its kind names, so there is no `Op.Item :: string`
    anywhere and a field belonging to another kind is an error rather than a nil at runtime
--]]

local function Reducer(State: Profile, Op: Ledger.Op<Ops>): Profile?
	if Op.Kind == "Buy" then
		local Cost = Prices[Op.Item]
		if Cost == nil or Cost > State.Gold or State.Items[Op.Item] then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold -= Cost
		Next.Items = table.clone(State.Items)
		Next.Items[Op.Item] = true
		return Next
	elseif Op.Kind == "Sell" then
		local Cost = Prices[Op.Item]
		if Cost == nil or not State.Items[Op.Item] then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold += Cost // 2
		Next.Items = table.clone(State.Items)
		Next.Items[Op.Item] = nil
		return Next
	elseif Op.Kind == "AddGold" then
		if Op.Amount <= 0 then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold += Op.Amount
		return Next
	end

	return nil
end

--[[ building it. the two type arguments are what the checker holds every write against ]]

local function Open(): Ledger.TypedStore<Profile, Ops>
	return Ledger.NewTyped<<Profile, Ops>>({
		Name = "Shop",
		Default = { Gold = 100, Items = {} },
		Reducer = Reducer,
	})
end

--[[ the call sites ]]

local function Buy(Session: Ledger.TypedSession<Profile, Ops>, Item: string): (boolean, Ledger.Reason?)
	return Session:Apply("Buy", { Item = Item })
end

local function Sell(Session: Ledger.TypedSession<Profile, Ops>, Item: string): (boolean, Ledger.Reason?)
	return Session:Apply("Sell", { Item = Item })
end

local function Gift(Store: Ledger.TypedStore<Profile, Ops>, UserId: number, Amount: number): (boolean, Ledger.Reason?)
	return Store:Edit(UserId, "AddGold", { Amount = Amount }):Wait()
end

--[[
    what the checker now turns away, each of which used to be a refusal you found while playing:

        Session:Apply("Byu", { Item = "Sword" })     no kind by that name
        Session:Apply("Buy", { Item = 42 })          Item is a string
        Session:Apply("Buy", { Itme = "Sword" })     no field by that name
        Session:Apply("Buy", { Amount = 5 })         those are AddGold's fields
        Store:Edit(1, "AddGold", { Amount = "5" })   Amount is a number

    and inside the reducer, under `if Op.Kind == "Buy"`:

        return Op.Amount                             AddGold's field, not Buy's

    a kind takes its fields whether or not it has any, so an op that carries nothing is written as
    `Ping: {}` in the map and called as `Session:Apply("Ping", {})`.

    everything else on the store is unchanged. Peek, Transfer, Reserve, Tx and the rest have the
    same signatures they have on an untyped store, and a typed store is built, saved and recovered
    by exactly the same code.
--]]

return table.freeze({
	Reducer = Reducer,
	Open = Open,
	Buy = Buy,
	Sell = Sell,
	Gift = Gift,
})
