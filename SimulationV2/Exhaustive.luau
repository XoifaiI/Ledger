--!strict
--!optimize 2

--[=[
	Exhaustive: Walks every sequence of draws that the bounds allow.

	A sweep says a bug did not show up in the seeds it tried. This says the bug is not there at all,
	for every choice up to the bounds given.

	Return type: A table with New and MAX_DRAWS. The type is Walk.
	Example usage:
		local Walk = Exhaustive.New()
		while not Walk:Done() do Run(Walk:Upto(3)) end
--]=]

local MAX_DRAWS = 64

type Slot = {
	Value: number,
	Bound: number
}

type WalkImpl = {
	__index: WalkImpl,

	Done: (self: Walk) -> boolean,
	Upto: (self: Walk, Bound: number) -> number,
	Between: (self: Walk, Least: number, Most: number) -> number,
	Index: (self: Walk, Held: { any }) -> number,
	Pick: <T>(self: Walk, Held: { T }) -> T,
	Boolean: (self: Walk) -> boolean,
	Shuffle: <T>(self: Walk, Held: { T }) -> ()
}

export type Walk = setmetatable<{
	Slots: { Slot },
	At: number,
	Reach: number,
	Started: boolean
}, WalkImpl>

local Walk = {} :: WalkImpl
Walk.__index = Walk

local function Draw(self: Walk, Bound: number): number
	assert(Bound >= 0, "an exhaustive draw needs a bound of zero or more")

	self.At += 1
	local At = self.At
	assert(At <= MAX_DRAWS, `an exhaustive walk made more than {MAX_DRAWS} draws in one pass, so it will not finish`)

	if At > self.Reach then
		self.Slots[At] = { Value = 0, Bound = Bound }
		self.Reach = At
	end

	local Slot = self.Slots[At]
	Slot.Bound = Bound
	return Slot.Value
end

local function New(): Walk
	return setmetatable({ Slots = {}, At = 0, Reach = 0, Started = false }, Walk) :: any
end

function Walk.Done(self: Walk): boolean
	self.At = 0

	if not self.Started then
		self.Started = true
		return false
	end

	for Index = self.Reach, 1, -1 do
		local Slot = self.Slots[Index]
		if Slot.Value < Slot.Bound then
			Slot.Value += 1
			self.Reach = Index
			return false
		end
	end

	return true
end

function Walk.Upto(self: Walk, Bound: number): number
	return Draw(self, Bound)
end

function Walk.Between(self: Walk, Least: number, Most: number): number
	assert(Least <= Most, "an exhaustive range needs its least to be no larger than its most")
	return Least + Draw(self, Most - Least)
end

function Walk.Index(self: Walk, Held: { any }): number
	assert(#Held > 0, "an exhaustive index needs something to index into")
	return Draw(self, #Held - 1) + 1
end

function Walk.Pick<T>(self: Walk, Held: { T }): T
	return Held[self:Index(Held)]
end

function Walk.Boolean(self: Walk): boolean
	return Draw(self, 1) == 1
end

function Walk.Shuffle<T>(self: Walk, Held: { T })
	for Index = 1, #Held do
		local Swap = Draw(self, Index - 1) + 1
		Held[Index], Held[Swap] = Held[Swap], Held[Index]
	end
end

table.freeze(Walk)

return table.freeze({
	New = New,
	MAX_DRAWS = MAX_DRAWS
})
