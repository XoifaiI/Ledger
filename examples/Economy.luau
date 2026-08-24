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
	Mail: { string },
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
	elseif Op.Kind == "Compensate" then
		local Amount = Op.Amount :: number
		if Amount <= 0 then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold += Amount
		Next.Mail = table.clone(State.Mail)
		table.insert(Next.Mail, Op.Text :: string)
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

local function Tip(Store: Ledger.Store<Profile>, OrderId: string, From: number, To: number, Amount: number): (boolean, Ledger.Reason?)
	return Store:Transfer(From, To, Amount, `tip:{OrderId}`):Wait()
end

--[[ compensation, a support grant, a scheduled reward: works offline ]]

--[[
    DidApply answers nil when the record could not be read, which is not the same as the grant not
    happening. only a true means it went through
--]]

local function Grant(Store: Ledger.Store<Profile>, UserId: number, Amount: number, Reason: string, GrantId: string): boolean
	local Name = `grant:{GrantId}`
	Store:Edit(UserId, "Compensate", { Amount = Amount, Text = Reason, Once = Name }):Wait()
	return Store:DidApply(UserId, Name):Wait() == true
end

local function GrantMany(Store: Ledger.Store<Profile>, Recipients: { number }, Amount: number, GrantId: string): number
	local Granted = 0
	for _, UserId in Recipients do
		if Grant(Store, UserId, Amount, "a gift for everyone", `{GrantId}:{UserId}`) then
			Granted += 1
		end
	end
	return Granted
end

--[[ reading someone else's profile, for a viewer or support tool ]]

local function Inspect(Store: Ledger.Store<Profile>, UserId: number): Profile?
	local State = Store:Peek(UserId):Wait()
	return State
end

--[[
    Peek can give an old answer, because a live session on a different server can hold ops
    that it has not written yet. Show the result to the player. Do not make a decision from
    the result. Put each decision in an op, where the reducer approves it.

    A false Transfer always has a reason. There are six reasons:

        Refused     The move is not permitted. The sender does not hold enough. Nothing
                    moved. Tell the player.
        Busy        A different write holds the sender. Nothing moved. Send the transfer
                    again in a moment.
        Spent       A different transfer already used this Id. Use a new Id.
        Closed      The server is shutting down and the write was dropped before it ran.
                    Nothing moved. Do not send it again here.
        Held        The amount left the sender and waits in escrow for the receiver. The
                    money did move. Do not tell the player that nothing moved. Ledger
                    delivers the amount, or gives the amount back after the window. An
                    amount that stays too long is written off, and Ledger writes a warning
                    that a person must read.
        Unresolved  Ledger has not finished the transfer. Read both keys again later. Do not
                    send the transfer again with a new Id.

    Refused and Busy are the only two reasons that mean nothing moved.

    The Id is optional, but always give an Id. A transfer that you send again with the same
    Id moves the amount one time. A transfer that you send again with no Id moves the amount
    a second time. A tip Id and a trade Id can be the same text, because Ledger keeps the
    names of transfers apart from the names of transactions.

    An Edit cannot make a state that gameplay cannot make. An Edit uses the same reducer. The
    reducer refuses an offline grant of a negative amount, and it refuses a live grant of a
    negative amount.

    The gold and the mail are one op. They are not two ops. If they are two ops, one op can
    apply and the other op can fail. A player who reads a message about a gift, and who has
    no more gold, sends a support request. Shop gives the same rule.

    Each grant has a name, so a job that you run two times pays each player one time. Get the
    name from the thing that you pay for. Do not get the name from the clock. Grant reads the
    result of DidApply, and not the result of the Edit, because a second run changes nothing
    and is still a grant.

    GrantMany waits for each grant. A loop that does not wait starts all of the writes at the
    same time, and a few hundred players use all of the request budget. If the list is long,
    run the job on a different thread, and let the job take the time that it needs.
--]]

return table.freeze({
	Reducer = Reducer,
	Tip = Tip,
	Grant = Grant,
	GrantMany = GrantMany,
	Inspect = Inspect,
})
