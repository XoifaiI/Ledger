--!strict

--[=[
    Clans: an entity store, and a transaction that crosses two stores.

    Keys = "String" gives you a store keyed by plain strings for state no single server owns.
    Many servers write the same clan at once and the validating fold arbitrates, which is
    exactly the case a session lock cannot serve, because no server can hold the lock.

    An entity store has no sessions and no autosave. There is no player to attach one to, so
    it gets the cross-server surface only.

    these are illustrations, not modules.
--]=]

local Ledger = require("../src")

export type Clan = {
	Gold: number,
	Motd: string,
	Members: { [string]: boolean }
}

export type Profile = {
	Gold: number,
	Clan: string?
}

--[[ the clan store's reducer ]]

local function ClanReducer(State: Clan, Op: Ledger.Op): Clan?
	if Op.Kind == "Deposit" then
		local Amount = Op.Amount :: number
		if Amount <= 0 then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold += Amount
		return Next
	elseif Op.Kind == "Withdraw" then
		local Amount = Op.Amount :: number
		if Amount <= 0 or Amount > State.Gold then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold -= Amount
		return Next
	elseif Op.Kind == "Join" then
		local UserId = Op.UserId :: string
		if State.Members[UserId] then
			return nil
		end

		local Next = table.clone(State)
		Next.Members = table.clone(State.Members)
		Next.Members[UserId] = true
		return Next
	elseif Op.Kind == "SetMotd" then
		local Next = table.clone(State)
		Next.Motd = Op.Text :: string
		return Next
	end

	return nil
end

--[[ the player store's reducer, which owns the other half of a deposit ]]

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	if Op.Kind == "SpendGold" then
		local Amount = Op.Amount :: number
		if Amount <= 0 or Amount > State.Gold then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold -= Amount
		return Next
	elseif Op.Kind == "SetClan" then
		local Next = table.clone(State)
		Next.Clan = Op.Tag :: string
		return Next
	end

	return nil
end

--[[
    built alongside the player store

        local Clans = Ledger.New({
            Name = "Clans",
            Keys = "String",
            Default = { Gold = 0, Motd = "", Members = {} },
            Reducer = ClanReducer
        })
--]]

--[[ ordinary single key writes, from any server, with nobody online ]]

local function Join(Clans: Ledger.Store<Clan>, Tag: string, UserId: number)
	Clans:Edit(Tag, "Join", { UserId = tostring(UserId) })
end

local function SetMotd(Clans: Ledger.Store<Clan>, Tag: string, Text: string)
	Clans:Edit(Tag, "SetMotd", { Text = Text })
end

--[[
    a clan that was never written folds to the Default, so nil here always means the read itself
    failed. Behind means a newer server wrote this record and you are mid deploy, anything else is
    worth another go later
--]]

local function Read(Clans: Ledger.Store<Clan>, Tag: string): (Clan?, Ledger.Reason?)
	return Clans:Peek(Tag):Wait()
end

--[[
    a player paying into the bank. two keys on two different stores, so it is a transaction.
    the store you call Tx on is the coordinator, and a leg naming another store uses Key
    instead of UserId to match that store's key mode.
--]]

local function Deposit(
	Players: Ledger.Store<Profile>,
	Clans: Ledger.Store<Clan>,
	DepositId: string,
	UserId: number,
	Tag: string,
	Amount: number
): (boolean, Ledger.Reason?)
	return Players:Tx(`deposit:{DepositId}`, {
		{ UserId = UserId, Kind = "SpendGold", Fields = { Amount = Amount } },
		{ Store = Clans, Key = Tag, Kind = "Deposit", Fields = { Amount = Amount } }
	}):Wait()
end

--[[
    A transaction holds each of its keys until the transaction is complete. If ten servers
    deposit into the same clan at the same time, one transaction gets the keys. The other
    nine transactions get Busy.

    Busy changes nothing. Send the same transaction again after a short delay, and use the
    same DepositId. A retry with the same Id is safe.

    Transfer does not help here. Transfer moves a balance between two keys of one store. It
    cannot move a balance from one store to a different store.

    If the clan bank only holds a total, and no player key must change at the same moment,
    use Bump and Total. Bump and Total divide the count across many keys.

    Do not keep a global counter in an entity store. A million Add ops give the reducer
    nothing to approve.
--]]

return table.freeze({
	ClanReducer = ClanReducer,
	Reducer = Reducer,
	Join = Join,
	SetMotd = SetMotd,
	Read = Read,
	Deposit = Deposit
})
