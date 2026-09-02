local Engine = require("../zune/Engine")
Engine.Install()

local Mark = require("../src/Encode/Mark")

local storeName = "PlayerData"
local key = "12345678"

local mark = Mark.Of(storeName, key)
print("Mark representation:", string.format("%q", mark))

local packed = Mark.Pack({ mark, Mark.Of("Inventory", "sword_1") })
print("Packed representation:", string.format("%q", packed))

local decodedMarks = Mark.Unpack(packed)
print("Unpacked count:", #decodedMarks)
for i, m in decodedMarks do
    local s, k = Mark.Split(m)
    print(`  [{i}] Store: {s}, Key: {k}`)
end

-- Now test through JSON encode/decode
local HttpService = game:GetService("HttpService")
local encodedJson = HttpService:JSONEncode({ Keys = packed })
print("JSON Encoded:", encodedJson)

local decodedJson = HttpService:JSONDecode(encodedJson)
local unpackedAfterJson = Mark.Unpack(decodedJson.Keys)
print("Unpacked count after JSON roundtrip:", #unpackedAfterJson)
for i, m in unpackedAfterJson do
    local s, k = Mark.Split(m)
    print(`  [{i}] Store: {s}, Key: {k}`)
end
