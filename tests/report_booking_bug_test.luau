local Engine = require("../zune/Engine")
Engine.Install()

local Clock = require("../src/Util/Clock")
local Ledger = require("../src")
local Booking = require("../src/Layers/Booking")
local Recovery = require("../src/Protocol/Recovery")
local Windows = require("../src/Core/Constants/Windows")

print("Testing Recovery.Bookings refunding in-flight booking where Handing == true...")

local store = Ledger.New({
    Name = "TestBookingDoubleSpend",
    Default = { Stock = 10 },
    Balance = "Stock",
    Keys = "String",
    Mock = true,
    Reducer = function(state, op)
        return state
    end,
})

store:Edit("Warehouse", "Seed", {}):Wait()
store:Edit("Customer", "Seed", {}):Wait()

local Records = (store :: any):Records()
local Format = (store :: any):Format()

-- 1. Reserve 5 stock on Warehouse to Customer with Hold = 60 seconds
local reserveOp = Booking.Book("order_999", "Stock", 5, 60, "Customer")
Records:Append("Warehouse", { reserveOp })

print("Warehouse stock after reserve:", store:Peek("Warehouse"):Wait().Stock)

-- 2. Mark Handing = true (handover started)
Records:Append("Warehouse", { Booking.Hand("order_999") })

local warehouseState = store:Peek("Warehouse"):Wait()
local bookedEntry = warehouseState._Booked["order_999"]
print("Is Handing == true?", bookedEntry.Handing == true)

-- 3. Fast-forward clock by 60s (Hold) + 601s (> BOOK_MARGIN 10m)
local realScheduler = Clock.Held()
local simTime = realScheduler.Now() + 60 + Windows.BOOK_MARGIN + 10
Clock.Use({
    Now = function() return simTime end,
    Wait = realScheduler.Wait,
    Spawn = realScheduler.Spawn,
    Resume = realScheduler.Resume,
    Defer = realScheduler.Defer,
    Delay = realScheduler.Delay,
    Cancel = realScheduler.Cancel,
})

-- 4. Run Recovery.Bookings
print("\nRunning Recovery.Bookings after Hold + BOOK_MARGIN expired...")
local recovered = Recovery.Bookings(Records, Format, "Warehouse", store:Peek("Warehouse"):Wait(), function(to)
    return store:Peek(to):Wait()
end)
print("Recovery.Bookings returned:", recovered)

local afterState = store:Peek("Warehouse"):Wait()
print("Warehouse stock after recovery:", afterState.Stock)
print("Warehouse booked after recovery:", afterState._Booked)
print("WAS STOCK REFUNDED TO WAREHOUSE WHILE HANDING OVER?", afterState.Stock == 10)
