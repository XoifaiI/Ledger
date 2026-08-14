--!strict
--!optimize 2

--[=[
	Board: Puts faults between the library and the disk.

	It holds no data. It decides only whether a request arrives, and whether the answer comes back.
	Faults come in outages, because one lost call alone is rarely seen. Every write passes through
	here, so this is also where a run keeps its journal of what landed.

	Return type: A table with New, Drawn, Install, Heal, Wrap, DOWN and SWALLOWED.
	Example usage:
		local Faulty = Board.New(Rng)
		Board.Install(Faulty, Wrapper, Plate)
--]=]

local Disk = require("./Disk")
local Swarm = require("./Swarm")

export type Faults = {
	Loss: number,
	Silent: number,
	Misdirect: number,
	Outage: number,
	OutageFor: number
}

export type Board = {
	Faults: Faults,
	Rng: Random,
	Dark: number,
	Calls: number,
	Injected: number,
	Lost: number,
	Moved: { string },
	Keeping: boolean,
	Journal: { string }
}

local DOWN = "SimulationV2: the request never reached the datastore"
local SWALLOWED = "SimulationV2: the write landed and the answer was lost"

local OUTAGE_LEAST = 8
local OUTAGE_MOST = 40

local WRITES: { [string]: boolean } = {
	UpdateAsync = true,
	RemoveAsync = true
}

local function Drawn(Rng: Random): Faults
	local Shapes = Swarm.Weights(Rng, { "Loss", "Silent", "Outage" })
	local Held: { [string]: number } = {}
	for _, Weight in Shapes do
		Held[Weight.Name] = if Weight.Weight == 0 then 0 else Weight.Weight / 100 * 0.15
	end

	return {
		Loss = Held.Loss,
		Silent = Held.Silent,
		Misdirect = 0,
		Outage = Held.Outage * 0.05,
		OutageFor = Rng:NextInteger(OUTAGE_LEAST, OUTAGE_MOST)
	}
end

local function New(Rng: Random, Faults: Faults?): Board
	return {
		Faults = Faults or Drawn(Rng),
		Rng = Rng,
		Dark = 0,
		Calls = 0,
		Injected = 0,
		Lost = 0,
		Moved = {},
		Keeping = false,
		Journal = {}
	}
end

local function Rolls(self: Board, Chance: number): boolean
	if Chance <= 0 then
		return false
	end
	return self.Rng:NextNumber() < Chance
end

local function Darkened(self: Board): boolean
	if self.Dark > 0 then
		self.Dark -= 1
		return true
	end
	if not Rolls(self, self.Faults.Outage) then
		return false
	end

	self.Dark = self.Faults.OutageFor
	return true
end

local function Elsewhere(Key: string): string
	local Last = tonumber(string.sub(Key, -1))
	if Last == nil then
		return `{Key}x`
	end
	return `{string.sub(Key, 1, -2)}{(Last + 1) % 10}`
end

local function Ids(Record: any): { [string]: boolean }
	local Held: { [string]: boolean } = {}
	if type(Record) ~= "table" or type(Record.Ops) ~= "table" then
		return Held
	end

	for _, Entry in Record.Ops do
		local Op: any = Entry
		if type(Op) == "table" and type(Op.Id) == "string" then
			Held[Op.Id] = true
		end
	end
	return Held
end

local function Readable(Value: any): string
	if type(Value) ~= "string" then
		return tostring(Value)
	end
	return (string.gsub(Value, "%c", "|"))
end

local function Marked(self: Board, Named: string, Key: string, Next: any)
	if not self.Keeping or type(Next) ~= "table" or type(Next.Status) ~= "string" then
		return
	end

	local Adopted = 0
	for _ in if type(Next.Adopted) == "table" then Next.Adopted else {} do
		Adopted += 1
	end

	table.insert(
		self.Journal,
		`{Named} marked '{Key}' {Next.Status}, {Adopted} of {tostring(Next.Total)} adopted, gen {tostring(Next.Gen)}, terms {Readable(Next.Terms)}`
	)
end

local function Note(self: Board, Named: string, Key: string, Had: { [string]: boolean }, Next: any)
	if not self.Keeping or type(Next) ~= "table" or type(Next.Ops) ~= "table" then
		return Marked(self, Named, Key, Next)
	end

	for _, Entry in Next.Ops do
		local Op: any = Entry
		if type(Op) ~= "table" or Had[tostring(Op.Id)] then
			continue
		end
		table.insert(
			self.Journal,
			`{Named} put {tostring(Op.Kind)} on '{Key}' as {tostring(Op.Id)}, name {tostring(Op.Rid or Op.Tid or Op.Tx)}, amount {tostring(Op.Amount)}`
		)
	end
end

local function Wrap(self: Board, Inner: any, Named: string?): any
	local Who = Named or "somebody"
	local Proxy = {}

	local function Call(Named: string, Key: string, Run: (string) -> ...any): ...any
		self.Calls += 1

		if Darkened(self) or Rolls(self, self.Faults.Loss) then
			self.Injected += 1
			error(DOWN, 0)
		end

		local Landed = Key
		if WRITES[Named] and Rolls(self, self.Faults.Misdirect) then
			self.Injected += 1
			Landed = Elsewhere(Key)
			table.insert(self.Moved, `{Named} meant for '{Key}' landed on '{Landed}'`)
		end

		local Held = table.pack(Run(Landed))

		if WRITES[Named] and Rolls(self, self.Faults.Silent) then
			self.Injected += 1
			self.Lost += 1
			error(SWALLOWED, 0)
		end

		return table.unpack(Held, 1, Held.n)
	end

	function Proxy.GetAsync(_: any, Key: string): ...any
		return Call("GetAsync", Key, function(Landed: string): ...any
			return Inner:GetAsync(Landed)
		end)
	end

	function Proxy.UpdateAsync(_: any, Key: string, Transform: any): ...any
		local Had: { [string]: boolean } = {}
		local Watched = function(Current: any, Info: any): any
			Had = Ids(Current)
			return Transform(Current, Info)
		end

		return Call("UpdateAsync", Key, function(Landed: string): ...any
			local Stored, Mark = Inner:UpdateAsync(Landed, Watched)
			Note(self, Who, Key, Had, Stored)
			return Stored, Mark
		end)
	end

	function Proxy.RemoveAsync(_: any, Key: string): ...any
		return Call("RemoveAsync", Key, function(Landed: string): ...any
			local Was, Mark = Inner:RemoveAsync(Landed)
			if self.Keeping and Was ~= nil then
				table.insert(self.Journal, `{Who} took '{Key}' off {if type(Was) == "table" and Was.Status ~= nil then "the markers" else "the records"}`)
			end
			return Was, Mark
		end)
	end

	function Proxy.GetVersionAsync(_: any, Key: string, Version: string): ...any
		return Call("GetVersionAsync", Key, function(Landed: string): ...any
			return Inner:GetVersionAsync(Landed, Version)
		end)
	end

	function Proxy.ListVersionsAsync(_: any, Key: string, Direction: any, Least: any, Most: any, Size: any): ...any
		return Call("ListVersionsAsync", Key, function(Landed: string): ...any
			return Inner:ListVersionsAsync(Landed, Direction, Least, Most, Size)
		end)
	end

	function Proxy.ListKeysAsync(_: any, Prefix: any, Size: any, Cursor: any, Hiding: any): ...any
		return Call("ListKeysAsync", "", function(): ...any
			return Inner:ListKeysAsync(Prefix, Size, Cursor, Hiding)
		end)
	end

	return Proxy
end

local function Install(self: Board, Wrapper: any, Held: Disk.Disk)
	Wrapper.Use(function(Name: string): any
		return Wrap(self, Disk.Open(Held, Name))
	end, function(Kind: Enum.DataStoreRequestType): number
		return if Held.Throttled then 100 else 1000
	end)
end

local function Heal(self: Board)
	self.Faults = { Loss = 0, Silent = 0, Misdirect = 0, Outage = 0, OutageFor = 0 }
	self.Dark = 0
end

return table.freeze({
	New = New,
	Drawn = Drawn,
	Install = Install,
	Heal = Heal,
	Wrap = Wrap,
	DOWN = DOWN,
	SWALLOWED = SWALLOWED
})
