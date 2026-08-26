--!strict
--!optimize 2

--[=[
	Seeds: Turns a little true randomness into as many seeds as a sweep wants.

	A sweep walks seeds in order, so the next run covers ground the last one already walked. Paste a
	value from random.org into the runner and each index becomes a seed spread over the whole space
	instead. One fetch is enough for millions of them, and the same value walks the same seeds again,
	so a failure is still a seed you can put in SEEDS on its own.
	At takes the index and not the seed before it, so a worker draws its own slice and nothing has to
	hold the whole list. A hash takes bytes and gives bytes back, so the entropy goes into a buffer
	once and only the index is written again per seed.

	Fetch draws the entropy from random.org, one request for a whole sweep, and it needs Allow HTTP
	Requests turned on in Game Settings.

	Return type: A table with Fetch, At, Spread and MAX.
	Example usage:
		local Seeds = require("./Seeds")
		local Seed = Seeds.At("8f3ac1", 42)
--]=]

local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")

local ALGORITHM = Enum.HashAlgorithm.Blake3

local SOURCE = "https://www.random.org/strings/?num=1&len=24&digits=on&upperalpha=off&loweralpha=on&unique=on&format=plain&rnd=new"

local INDEX_BYTES = 4

local MAX = 2 ^ 31 - 1

local function Fetch(): string
	local Ok, Answer = pcall(HttpService.GetAsync, HttpService, SOURCE)
	assert(Ok, `could not reach random.org for entropy, turn on Allow HTTP Requests in Game Settings: {tostring(Answer)}`)

	local Drawn = (string.gsub(Answer :: string, "%s", ""))
	assert(string.match(Drawn, "^%w+$") ~= nil and #Drawn >= 8, `random.org answered '{Drawn}', which is not a value to draw seeds from`)
	return Drawn
end

local function Held(Entropy: string): buffer
	local Bytes = buffer.create(#Entropy + INDEX_BYTES)
	buffer.writestring(Bytes, 0, Entropy)
	return Bytes
end

local function Draw(Bytes: buffer, Offset: number, Index: number): number
	buffer.writeu32(Bytes, Offset, Index)
	return buffer.readu32(EncodingService:ComputeBufferHash(Bytes, ALGORITHM), 0) % MAX + 1
end

local function At(Entropy: string, Index: number): number
	if Entropy == "" then
		return Index
	end

	return Draw(Held(Entropy), #Entropy, Index)
end

local function Spread(Entropy: string, From: number, To: number): { number }
	assert(To >= From, "a spread of seeds needs its last index at or after its first")

	local Drawn = table.create(To - From + 1) :: { number }
	if Entropy == "" then
		for Index = From, To do
			table.insert(Drawn, Index)
		end
		return Drawn
	end

	local Bytes = Held(Entropy)
	local Offset = #Entropy
	for Index = From, To do
		table.insert(Drawn, Draw(Bytes, Offset, Index))
	end
	return Drawn
end

return table.freeze({
	Fetch = Fetch,
	At = At,
	Spread = Spread,
	MAX = MAX,
})
