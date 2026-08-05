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
    The Id is the first argument, because the Id makes the call safe to repeat. Get the Id
    from the trade. Do not get the Id from the clock. A different Id makes a second trade.

    A false result always has a reason. There are five reasons:

        Refused     A reducer refused a leg. The seller no longer has the item, or the buyer
                    cannot pay. This result is permanent. Tell the player.
        Busy        A different transaction holds one of these keys. Nothing changed. Offer
                    the trade again in a moment.
        Spent       A different trade already used this Id. Use a new Id.
        Invalid     A leg carries a field that Ledger cannot store. This result is a fault in
                    the caller. Ledger writes a warning that gives the number of the leg.
        Unresolved  The datastore did not answer. The trade can still commit. Do not tell the
                    player that the trade failed. Do not send the trade again with a new Id.
                    Read both profiles again.

    Tx sends a transaction again after a lost acknowledgement, a stale marker or a torn
    verdict. These three conditions do not reach the caller.

    Do not use Tx for one key. A swap inside the inventory of one player is one op.
--]]

return table.freeze({
	Reducer = Reducer,
	Swap = Swap,
	BuyFrom = BuyFrom
})
