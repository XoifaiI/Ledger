local Engine = require("../zune/Engine")
Engine.Install()

local Ledger = require("../src")

print("Testing quick leave and rejoin race condition...")

local store = Ledger.New({
    Name = "TestRace",
    Default = { Gold = 100 },
    Mock = true,
    Reducer = function(state, op)
        if op.Kind == "Add" then
            local next = table.clone(state)
            next.Gold += op.Amount
            return next
        end
        return nil
    end,
})

-- We need a slow Hook to simulate network latency on Load
local rawStore = (store :: any).Wrapper.Hook.Open("TestRace")

local player1 = { UserId = 8888, Name = "Player8888", Parent = game:GetService("Players") }

-- Start Load 1 in a separate thread
task.spawn(function()
    store:Load(player1 :: any)
end)

-- While Load 1 is in-flight (yielding on datastore), player leaves
task.wait(0) -- yield once to let Load 1 start
print(`Loads state after Load 1 started: {(store :: any).Loads[8888]}`)

store:Unload(player1 :: any)
print(`Loads state after Unload: {(store :: any).Loads[8888]}`)

-- Player immediately rejoins
local player2 = { UserId = 8888, Name = "Player8888", Parent = game:GetService("Players") }
task.spawn(function()
    store:Load(player2 :: any)
end)
print(`Loads state after Load 2 started: {(store :: any).Loads[8888]}`)

-- Wait for both loads to complete
task.wait(0.5)

print(`Final Loaded entry: {store:IsLoaded(player2 :: any)}`)
local session = store:Get(player2 :: any)
print(`Session exists: {session ~= nil}`)
