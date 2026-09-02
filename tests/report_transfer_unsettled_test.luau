local Engine = require("../zune/Engine")
Engine.Install()

local Ledger = require("../src")

print("Testing Transfer crash after delivery before settle, then retry...")

local store = Ledger.New({
    Name = "TestTransferCrash",
    Default = { Gold = 100 },
    Balance = "Gold",
    Keys = "String",
    Mock = true,
    Reducer = function(state, op)
        return state
    end,
})

-- Seed two accounts
store:Edit("Alice", "Seed", {}):Wait()
store:Edit("Bob", "Seed", {}):Wait()

print("Alice start balance:", store:Peek("Alice"):Wait().Gold)
print("Bob start balance:", store:Peek("Bob"):Wait().Gold)

local Transfer = require("../src/Protocol/Transfer")
local Records = (store :: any):Records()
local Format = (store :: any):Format()

-- Run Reserve
local ruling = Transfer.Reserve(Records, Format, "Alice", "Bob", 30, "tx_transfer_1")
print("Reserve outcome:", (ruling :: any).Outcome)

-- Run Post manually delivering to Bob without Settle on Alice
local Kinds = require("../src/Core/Constants/Kinds")
local Print = Transfer.Terms("Alice", "Bob", 30)
local DeliverOp = { Id = `{Kinds.DELIVER_ID}:tx_transfer_1`, Kind = Kinds.DELIVER, From = "Alice", Amount = 30, Tid = "tx_transfer_1", At = os.time(), Print = Print }
Records:Append("Bob", { DeliverOp })

print("Bob balance after delivery:", store:Peek("Bob"):Wait().Gold)
print("Alice balance after delivery (before settle):", store:Peek("Alice"):Wait().Gold)
print("Alice _Held after delivery (before settle):", store:Peek("Alice"):Wait()._Held)

-- NOW: Caller retries Transfer("Alice", "Bob", 30, "tx_transfer_1")
print("\nCaller retries store:Transfer('Alice', 'Bob', 30, 'tx_transfer_1')...")
local retryOk, retryWhy = store:Transfer("Alice", "Bob", 30, "tx_transfer_1"):Wait()
print(`Retry result: ok={retryOk}, why={retryWhy}`)

local aliceState = store:Peek("Alice"):Wait()
print("Alice balance after retry:", aliceState.Gold)
print("Alice _Held after retry:", aliceState._Held)
print("Is tx_transfer_1 still in Alice _Held?", aliceState._Held and aliceState._Held["tx_transfer_1"] ~= nil)
