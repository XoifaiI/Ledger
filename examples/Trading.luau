--!strict

--[=[
    Trading: two players swapping, which is what Tx is for.

    Both sides move or neither does. Each leg is an ordinary op kind your reducer already
    handles, and the transaction machinery only decides whether the set happens.

    Name the trade. Without an id every attempt makes a fresh one, so a retry is a second
    trade. With one, a retry of a trade that already committed answers true and moves nothing.

    these are illustrations, not modules. they assume both players exist and skip the offer
    and confirmation flow entirely.
--]=]

local Ledger = require("../src")

export type Profile = {
	Gold: number,
	Items: { [string]: boolean }
}

--[[ the reducer branch, written so one kind serves both sides of a trade ]]

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	if Op.Kind ~= "Trade" then
		return nil
	end

	local Delta = (Op.Gold :: number?) or 0
	local Give = Op.Give :: string?
	local Take = Op.Take :: string?

	local Gold = State.Gold + Delta
	if Gold < 0 then
		return nil
	end

	local Items = table.clone(State.Items)

	if Give ~= nil then
		if not Items[Give] then
			return nil
		end
		Items[Give] = nil
	end

	if Take ~= nil then
		if Items[Take] then
			return nil
		end
		Items[Take] = true
	end

	return { Gold = Gold, Items = Items }
end

--[[ the call site ]]

local function Swap(
	Store: Ledger.Store<Profile>,
	TradeId: string,
	Left: number,
	LeftItem: string,
	Right: number,
	RightItem: string
): (boolean, Ledger.Reason?)
	return Store:Tx(`trade:{TradeId}`, {
		{ UserId = Left, Kind = "Trade", Fields = { Give = LeftItem, Take = RightItem } },
		{ UserId = Right, Kind = "Trade", Fields = { Give = RightItem, Take = LeftItem } }
	}):Wait()
end

local function BuyFrom(
	Store: Ledger.Store<Profile>,
	TradeId: string,
	Buyer: number,
	Seller: number,
	Item: string,
	Price: number
): (boolean, Ledger.Reason?)
	return Store:Tx(`trade:{TradeId}`, {
		{ UserId = Buyer, Kind = "Trade", Fields = { Gold = -Price, Take = Item } },
		{ UserId = Seller, Kind = "Trade", Fields = { Gold = Price, Give = Item } }
	}):Wait()
end

--[[
    the id is the first argument because it is what makes the call safe to repeat. derive it
    from the trade, never from the clock, or every retry is a second trade.

    false always comes with a reason, and there are only four:

        Refused     a leg's reducer said no. the seller no longer had the item, or the buyer
                    could not afford it. permanent, so tell the player
        Busy        another transaction holds one of those keys. nothing was applied, so this
                    is safe to offer again in a moment
        Spent       this trade id cannot be used again. use a new one
        Unresolved  the datastore never answered. it may still commit, so do not report a
                    failure and do not retry under a new name, just re-read the profiles

    a lost acknowledgement, a stale marker and a torn verdict never reach here, Tx retries
    those itself.

    do not reach for Tx on one key. a swap within one player's own inventory is one op.
--]]

return table.freeze({
	Reducer = Reducer,
	Swap = Swap,
	BuyFrom = BuyFrom
})
