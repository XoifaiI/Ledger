--!strict

--[=[
    Purchases: ProcessReceipt, and the reason Once exists.

    It calls ProcessReceipt again when the user makes another
    purchase or rejoins any server, and it keeps calling until you answer PurchaseGranted. It
    also says a callback may still fail to record on its backend after you answered granted,
    so a retry follows a perfectly healthy grant. Two servers may even run the same receipt at
    once if the user joins the second before the first answered.

    So the grant has to land at most once and still report granted on every replay after that.
    Once is that: name the op with the PurchaseId and Ledger applies it a single time, forever,
    and remembers the name in the profile where a compaction cannot lose it.

    Do not answer from whether the write changed anything. A replay changes nothing and is
    still granted. Answer from DidApply.

    these are illustrations, not modules. they assume the store was built and skip everything
    that is not Ledger.
--]=]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Ledger = require("../src")

export type Profile = {
	Gold: number,
	Gamepasses: { [string]: boolean }
}

local Products = {
	[123456] = 500,
	[123457] = 1200
}

--[[ the reducer branch. it never has to dedupe, Once already did ]]

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	if Op.Kind == "ProductGrant" then
		local Amount = Products[Op.ProductId :: number]
		if Amount == nil then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold += Amount
		return Next
	elseif Op.Kind == "UnlockGamepass" then
		local Pass = Op.Pass :: string
		if State.Gamepasses[Pass] then
			return nil
		end

		local Next = table.clone(State)
		Next.Gamepasses = table.clone(State.Gamepasses)
		Next.Gamepasses[Pass] = true
		return Next
	end

	return nil
end

--[[ the handler ]]

local function Install(Store: Ledger.Store<Profile>)
	MarketplaceService.ProcessReceipt = function(Receipt): Enum.ProductPurchaseDecision
		local Player = Players:GetPlayerByUserId(Receipt.PlayerId)
		if not Player then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local Session = Store:WaitForLoaded(Player)
		if not Session then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local Name = `receipt:{Receipt.PurchaseId}`
		local _, Why = Session:Commit("ProductGrant", { ProductId = Receipt.ProductId, Once = Name }):Wait()

		if Why == Ledger.Reason.Unresolved or not Session:DidApply(Name) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

--[[
    why WaitForLoaded and not Get. the callback fires as the user joins, which can be before
    their profile has loaded, and a ProcessReceipt callback may yield for as long as the server
    runs with no timeout. answering NotProcessedYet because the session was not ready yet would
    spend the whole retry, and the next one is not until they rejoin again.

    why DidApply and not the Commit result. Commit answers whether this call changed anything.
    The first one did. Every replay after it does not, and every replay after it is still a
    granted purchase. DidApply answers the question Roblox is actually asking.

    the one commit answer that still matters is Unresolved. It means there is no settled answer
    yet, a stuck transaction can leave the fold provisional, so answer NotProcessedYet and let
    the retry ask again on settled ground.

    the Once name is remembered in the profile itself, so it survives a compaction and a
    rejoin, and both servers of a concurrent receipt see the same answer.

    anything other than granted answers NotProcessedYet and the player keeps their Robux until
    the grant is durable. an unresolved purchase is never refunded, so never answer granted for
    something that did not land.
--]]

--[[ a one time unlock, where the id is yours to pick ]]

local function BuyGamepass(Session: Ledger.Session<Profile>, Pass: string): boolean
	local Name = `pass:{Pass}`
	local _, Why = Session:Commit("UnlockGamepass", { Pass = Pass, Once = Name }):Wait()
	return Why ~= Ledger.Reason.Unresolved and Session:DidApply(Name)
end

--[[ granting to someone who is not here, from a webhook or a support tool ]]

local function GrantOffline(Store: Ledger.Store<Profile>, UserId: number, ProductId: number, OrderId: string): boolean
	local Name = `order:{OrderId}`
	Store:Edit(UserId, "ProductGrant", { ProductId = ProductId, Once = Name }):Wait()
	return Store:DidApply(UserId, Name):Wait()
end

return table.freeze({
	Reducer = Reducer,
	Install = Install,
	BuyGamepass = BuyGamepass,
	GrantOffline = GrantOffline
})
