local Engine = require("../zune/Engine")
Engine.Install()

local Ledger = require("../src")
local Sizes = require("../src/Core/Constants/Sizes")

print("Testing full log deadlock scenario...")

local store = Ledger.New({
    Name = "TestFullLog",
    Default = { Items = {} },
    Mock = true,
    Reducer = function(state, op)
        if op.Kind == "AddItem" then
            local next = table.clone(state)
            local items = table.clone(next.Items)
            table.insert(items, op.Data)
            next.Items = items
            return next
        end
        return nil
    end,
})

local fakePlayer = { UserId = 12345, Name = "Tester", Parent = game:GetService("Players") }
store:Load(fakePlayer :: any)

local session = store:Expect(fakePlayer :: any)

print(`Log cap is: {Sizes.Log} bytes`)

local bigString = string.rep("x", 1000)
local opCount = math.ceil(Sizes.Log / 1000) + 10

print(`Applying {opCount} ops of ~1KB each...`)
local applied = 0
for i = 1, opCount do
    local ok, why = session:Apply("AddItem", { Data = bigString .. tostring(i) })
    if ok then
        applied += 1
    else
        print(`Apply stopped at {i}: {why}`)
        break
    end
end
print(`Successfully applied {applied} ops to session`)

-- Now try to flush or autosave
print("Attempting to flush session...")
local flushOk, flushWhy = session:Flush():Wait()
print(`Flush result: ok={flushOk}, why={flushWhy}`)

-- Now try to compact session
print("Attempting to compact session...")
local compactOk, compactWhy = session:Compact():Wait()
print(`Compact result: ok={compactOk}, why={compactWhy}`)

-- Now try release (player leaves)
print("Attempting to release session (player leave)...")
local releaseOk, releaseWhy = session:Release():Wait()
print(`Release result: ok={releaseOk}, why={releaseWhy}`)
