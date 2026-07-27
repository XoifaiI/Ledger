--!strict

--[=[
    Economy: moving one balance, and writing to players who are not here.

    Transfer moves the field named by Balance through an escrow, and unlike Tx it does not
    hold either key, so a popular receiver can absorb many at once. Name the transfer and a
    retry converges on one movement.

    Edit appends an op to any key at all. Offline, it folds on their next load. Online on
    another server, that session folds it on its next flush.

    these are illustrations, not modules.
--]=]

local Ledger = require("../src")

export type Profile = {
	Gold: number,
	Mail: { string }
}

--[[
    the store has to name the field Transfer moves

        Ledger.New({
            Name = "PlayerData",
            Default = { Gold = 100, Mail = {} },
            Balance = "Gold",
            Reducer = Reducer
        })
--]]

--[[ the reducer branches ]]

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	if Op.Kind == "AddGold" then
		local Amount = Op.Amount :: number
		if Amount <= 0 then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold += Amount
		return Next
	elseif Op.Kind == "Mail" then
		local Next = table.clone(State)
		Next.Mail = table.clone(State.Mail)
		table.insert(Next.Mail, Op.Text :: string)
		return Next
	end

	return nil
end

--[[ tipping, named by whatever the payment is for ]]

local function Tip(
	Store: Ledger.Store<Profile>,
	OrderId: string,
	From: number,
	To: number,
	Amount: number
): (boolean, Ledger.Reason?)
	return Store:Transfer(From, To, Amount, `tip:{OrderId}`):Wait()
end

--[[ compensation, a support grant, a scheduled reward: works offline ]]

local function Grant(Store: Ledger.Store<Profile>, UserId: number, Amount: number, Reason: string)
	Store:Edit(UserId, "AddGold", { Amount = Amount })
	Store:Edit(UserId, "Mail", { Text = Reason })
end

local function GrantMany(Store: Ledger.Store<Profile>, Recipients: { number }, Amount: number)
	for _, UserId in Recipients do
		Store:Edit(UserId, "AddGold", { Amount = Amount })
	end
end

--[[ reading someone else's profile, for a viewer or support tool ]]

local function Inspect(Store: Ledger.Store<Profile>, UserId: number): Profile?
	local State = Store:Peek(UserId):Wait()
	return State
end

--[[
    Peek is eventually consistent, because a live session somewhere may be holding unflushed
    ops. show it, never decide on it. decisions belong in ops, where the reducer arbitrates.

    a false Transfer always carries a reason. Refused and Busy both mean nothing moved, so they
    are safe to show the player. Unresolved means Ledger is still finishing it, so re-read the
    keys later and never call it again under a new id.

    that is why the id is worth passing even though it is optional: a retry with the same one
    is safe, a retry without one is a second transfer. a tip id and a trade id may now be the
    same string without colliding, since transfers and transactions are namespaced apart in the
    applied-id set.

    an Edit cannot create invalid state any more than gameplay can. it goes through the same
    reducer. so an offline grant of a negative amount is refused exactly like a live one.
--]]

return table.freeze({
	Reducer = Reducer,
	Tip = Tip,
	Grant = Grant,
	GrantMany = GrantMany,
	Inspect = Inspect
})
