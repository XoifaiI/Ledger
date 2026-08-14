--!strict
--!optimize 2

--[=[
	Swarm: Makes a seed do a few things many times, and not many things one time.

	A seed turns some choices off and gives a weight to the choices that are left. An exponential
	draw is small most times and large sometimes, which is the shape of a real workload.

	Return type: A table with Weights, Pick, Exponential, Index and Seed.
	Example usage:
		local Drawn = Swarm.Weights(Rng, { "Edit", "Transfer" })
--]=]

export type Weighted = { { Name: string, Weight: number } }

local function Weights(Rng: Random, Names: { string }): Weighted
	local Count = #Names
	assert(Count > 0, "a swarm needs at least one name to choose between")
	local Sample = Rng:NextInteger(1, Count)

	local Order: { number } = table.create(Count) :: { number }
	for Index = 1, Count do
		Order[Index] = Index
	end
	for Index = Count, 2, -1 do
		local Swap = Rng:NextInteger(1, Index)
		Order[Index], Order[Swap] = Order[Swap], Order[Index]
	end

	local Enabled: { [number]: boolean } = {}
	for Index = 1, Sample do
		Enabled[Order[Index]] = true
	end

	local Drawn: Weighted = table.create(Count) :: Weighted
	for Index, Name in Names do
		Drawn[Index] = { Name = Name, Weight = if Enabled[Index] then Rng:NextInteger(1, 100) else 0 }
	end
	return Drawn
end

local function Pick(Rng: Random, Drawn: Weighted): string
	local Total = 0
	for _, Held in Drawn do
		Total += Held.Weight
	end
	assert(Total > 0, "every choice in this swarm was weighted zero, so nothing can be picked")

	local Roll = Rng:NextInteger(1, Total)
	for _, Held in Drawn do
		Roll -= Held.Weight
		if Roll <= 0 then
			return Held.Name
		end
	end

	error("a weighted pick ran off the end of its own weights", 0)
end

local function Exponential(Rng: Random, Mean: number): number
	assert(Mean > 0, "an exponential draw needs a positive mean")
	return -math.log(1 - Rng:NextNumber()) * Mean
end

local function Index(Rng: Random, Count: number, Hot: number, Cold: number): number
	assert(Count > 0, "a hot or cold draw needs at least one key to draw from")
	assert(Hot < Cold, "the hot set has to be smaller than the cold one, or there is only one set")

	local Mean = if Rng:NextNumber() < 0.5 then Hot else Cold
	return math.min(math.floor(Exponential(Rng, Mean)) + 1, Count)
end

local function Seed(Text: string): number
	if #Text == 40 and string.match(Text, "^%x+$") ~= nil then
		return tonumber(string.sub(Text, 1, 12), 16) :: number
	end
	return assert(tonumber(Text), `a seed has to be a number or a 40 character commit hash, got '{Text}'`)
end

return table.freeze({
	Weights = Weights,
	Pick = Pick,
	Exponential = Exponential,
	Index = Index,
	Seed = Seed
})
