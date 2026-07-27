--!strict

--[=[
    Purchases: ProcessReceipt, the reason Commit and CommitOp exist.

    Roblox calls ProcessReceipt again and again until you answer PurchaseGranted, so the grant
    has to be idempotent across those retries. CommitOp is the tool: you own the op's Id, so
    you set it from the receipt's PurchaseId and every retry appends the same op, which the
    log refuses a second time.

    Commit(Kind, Fields) would be wrong here. It makes a fresh id per call, so two retries are
    two grants.

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

--[[ the reducer branch ]]

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

		local Session = Store:Get(Player)
		if not Session then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local Granted = Session:CommitOp({
			Id = `receipt:{Receipt.PurchaseId}`,
			Kind = "ProductGrant",
			ProductId = Receipt.ProductId
		}):Wait()

		if Granted ~= true then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

--[[
    a retry after the grant already landed answers true, because the append deduped and the
    fold still shows that op accepted. so the second call returns PurchaseGranted and Roblox
    stops asking.

    anything other than true, including the datastore being down, answers NotProcessedYet and
    Roblox asks again later. the player keeps their Robux until the grant is durable.

    write the reducer branch so a product grant cannot be refused. adding to a balance always
    succeeds. if a grant can refuse, a player can pay and get nothing.
--]]

--[[ a one time unlock, where Commit is enough because you generate the op ]]

local function BuyGamepass(Session: Ledger.Session<Profile>, Pass: string): boolean
	if Session:Get().Gamepasses[Pass] then
		return false
	end

	return Session:Commit("UnlockGamepass", { Pass = Pass }):Wait() == true
end

return table.freeze({
	Reducer = Reducer,
	Install = Install,
	BuyGamepass = BuyGamepass
})
