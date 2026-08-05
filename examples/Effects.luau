--!strict

--[=[
    Effects: deriving gameplay from state, and getting time into a pure reducer.

    A reducer may not read the clock. Same State and Op has to give the same result on every
    server and every replay, so anything time dependent captures the time at the call site and
    passes it in the op.

    Effects are rendered from state rather than granted from a return value. Then a fold that
    refuses the op removes the effect for you, and there is no revocation code to write.

    these are illustrations, not modules.
--]=]

local Ledger = require("../src")

export type Profile = {
	Gold: number,
	LastClaim: number,
	BoostUntil: number,
	Streak: number
}

local DAY = 86400
local BOOST_COST = 100
local BOOST_LENGTH = 600

--[[ the reducer branches. no os.time anywhere in here ]]

local function Reducer(State: Profile, Op: Ledger.Op): Profile?
	if Op.Kind == "ClaimDaily" then
		local At = Op.At :: number
		if At - State.LastClaim < DAY then
			return nil
		end

		local Next = table.clone(State)
		Next.Streak = if At - State.LastClaim < 2 * DAY then State.Streak + 1 else 1
		Next.Gold += 100 * Next.Streak
		Next.LastClaim = At
		return Next
	elseif Op.Kind == "BuyBoost" then
		local At = Op.At :: number
		if State.Gold < BOOST_COST or State.BoostUntil > At then
			return nil
		end

		local Next = table.clone(State)
		Next.Gold -= BOOST_COST
		Next.BoostUntil = At + BOOST_LENGTH
		return Next
	end

	return nil
end

--[[ the call site captures the clock ]]

local function ClaimDaily(Session: Ledger.Session<Profile>): (boolean, Ledger.Reason?)
	return Session:Apply("ClaimDaily", { At = os.time() })
end

local function BuyBoost(Session: Ledger.Session<Profile>): (boolean, Ledger.Reason?)
	return Session:Apply("BuyBoost", { At = os.time() })
end

--[[
    the effect is a view of state, not something the call site grants.

    if a foreign write lands between the Apply and its fold and the op is refused, BoostUntil
    is simply not in the corrected state, this fires again, and the speed drops back. nothing
    to revoke.
--]]

local function Render(Session: Ledger.Session<Profile>, Humanoid: Humanoid): () -> ()
	local function Paint(State: Profile)
		Humanoid.WalkSpeed = if State.BoostUntil > os.time() then 32 else 16
	end

	Paint(Session:Get())
	local Connection = Session:Observe():Subscribe(Paint)

	return function()
		Connection:Disconnect()
	end
end

--[[
    Observe fires on every accepted op, so a raw subscription repaints even when the field you
    draw did not move. map to the field, then drop repeats.

    disconnecting the last subscriber tears the whole chain down, so one teardown is enough for
    the Map and the Changed as well.
--]]

local function ShowGold(Session: Ledger.Session<Profile>, Label: TextLabel): () -> ()
	Label.Text = tostring(Session:Get().Gold)

	local Connection = Session:Observe()
		:Map(function(State: Profile): number
			return State.Gold
		end)
		:Changed()
		:Subscribe(function(Gold: number)
			Label.Text = tostring(Gold)
		end)

	return function()
		Connection:Disconnect()
	end
end

--[[
    a boost expiring is not a state change, so nothing fires when the deadline passes. drive
    that from a loop, reading state each time.
--]]

local function Watch(Session: Ledger.Session<Profile>, Humanoid: Humanoid): thread
	return task.spawn(function()
		while task.wait(1) do
			Humanoid.WalkSpeed = if Session:Get().BoostUntil > os.time() then 32 else 16
		end
	end)
end

return table.freeze({
	Reducer = Reducer,
	ClaimDaily = ClaimDaily,
	BuyBoost = BuyBoost,
	Render = Render,
	ShowGold = ShowGold,
	Watch = Watch
})
