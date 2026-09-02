local Engine = require("../zune/Engine")
Engine.Install()

local Ledger = require("../src")

print("Testing Store:DidApply during active session with pending Once op...")

local store = Ledger.New({
    Name = "TestDidApply",
    Default = { Gold = 100 },
    Mock = true,
    Reducer = function(state, op)
        if op.Kind == "Reward" then
            local next = table.clone(state)
            next.Gold += op.Amount
            return next
        end
        return nil
    end,
})

local player = { UserId = 55555, Name = "Player55555", Parent = game:GetService("Players") }
store:Load(player :: any)
local session = store:Expect(player :: any)

-- Apply op with Once
local applied, why = session:Apply("Reward", { Amount = 50, Once = "reward_daily_1" })
print(`Session:Apply result: {applied}, why: {why}`)

-- Check session:DidApply
local sessionDidApply = session:DidApply("reward_daily_1")
print(`session:DidApply("reward_daily_1"): {sessionDidApply}`)

-- Check store:DidApply with player.UserId
local storeDidApply = store:DidApply(player.UserId, "reward_daily_1"):Wait()
print(`store:DidApply(player.UserId, "reward_daily_1"): {storeDidApply}`)
