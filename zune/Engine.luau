--!strict

--[=[

	Engine: The Roblox globals Ledger reads, answered by Zune.

	Ledger takes its datastore, scheduler and clock as arguments, so what is left is vocabulary: a
	hash, base64, json, a guid, the request kinds, the sort directions, task, workspace, Random and
	warn. Install puts them in place, and Listen points warn at something other than the screen.
	The hash hands back raw bytes rather than hex, since a fingerprint cuts the first six and a shard
	reads the first four.

	Return type: A table with Install and Listen.
	Example usage:
		local Engine = require("./Engine")
		Engine.Install()
--]=]

local Serde = zune.serde
local Crypto = zune.crypto

local BLAKE = "blake3"
local GUID = "%x%x%x%x%x%x%x%x%-"

type Member = { read Name: string, read Value: number, read EnumType: string }

local function Members(Named: string, Names: { string }): { [string]: Member }
	local Held: { [string]: Member } = {}
	for Value, Name in Names do
		Held[Name] = table.freeze({ Name = Name, Value = Value - 1, EnumType = Named })
	end
	return table.freeze(Held)
end

local Enums = table.freeze({
	DataStoreRequestType = Members("DataStoreRequestType", {
		"GetAsync",
		"GetSortedAsync",
		"OnUpdate",
		"SetIncrementAsync",
		"SetIncrementSortedAsync",
		"UpdateAsync",
		"GetVersionAsync",
		"RemoveVersionAsync",
		"ListAsync",
	}),
	SortDirection = Members("SortDirection", { "Ascending", "Descending" }),
	HashAlgorithm = Members("HashAlgorithm", { "Blake3" }),
})

local EncodingService = table.freeze({
	ComputeStringHash = function(_: any, Text: string, _Algorithm: any): string
		local Held = Crypto.createHash(BLAKE)
		Held:update(Text)
		return buffer.tostring(Held:digest("binary"))
	end,
	Base64Encode = function(_: any, Held: buffer): buffer
		return Serde.base64.encode(Held)
	end,
	Base64Decode = function(_: any, Held: buffer): buffer
		return Serde.base64.decode(Held)
	end,
})

local HttpService = table.freeze({
	JSONEncode = function(_: any, Value: any): string
		return Serde.json.encode(Value)
	end,
	JSONDecode = function(_: any, Text: string): any
		return Serde.json.decode(Text)
	end,
	GenerateGUID = function(_: any, Braces: boolean?): string
		local Held = Crypto.uuid.v4()
		return if Braces == false then Held else "{" .. Held .. "}"
	end,
})

local RunService = table.freeze({
	IsServer = function(): boolean
		return true
	end,
	IsClient = function(): boolean
		return false
	end,
	IsStudio = function(): boolean
		return true
	end,
})

local Players = table.freeze({
	GetPlayerByUserId = function(_: any, _UserId: number): any
		return nil
	end,
})

local DataStoreService = table.freeze({
	GetDataStore = function(_: any, Name: string): any
		error(`Ledger under Zune: something asked for the real datastore '{Name}'. hand the store a hook instead`, 0)
	end,
	GetRequestBudgetForRequestType = function(_: any, _Kind: any): number
		return 0
	end,
})

local Random = {}
Random.__index = Random

local MODULUS = 2147483648
local MULTIPLIER = 1103515245
local INCREMENT = 12345

function Random.NextNumber(self: any, Least: number?, Most: number?): number
	self.Seed = (self.Seed * MULTIPLIER + INCREMENT) % MODULUS
	local Held = self.Seed / MODULUS
	if Least == nil or Most == nil then
		return Held
	end
	return Least + Held * (Most - Least)
end

function Random.NextInteger(self: any, Least: number, Most: number): number
	return Least + math.floor(self:NextNumber() * (Most - Least + 1))
end

local function NewRandom(Seed: number?): any
	return setmetatable({ Seed = (Seed or 0) % MODULUS }, Random)
end

local Services: { [string]: any } = {
	EncodingService = EncodingService,
	HttpService = HttpService,
	RunService = RunService,
	Players = Players,
	DataStoreService = DataStoreService,
}

local Game = table.freeze({
	JobId = string.gsub(Crypto.uuid.v4(), "%-", ""),
	GetService = function(_: any, Name: string): any
		local Held = Services[Name]
		if Held == nil then
			error(`Ledger under Zune: nothing answers for '{Name}' yet. add it to zune/Engine`, 0)
		end
		return Held
	end,
})

local Heard: ((Message: string) -> ())? = nil

local function Listen(Held: ((Message: string) -> ())?)
	Heard = Held
end

local function Install()
	local Held: { [string]: any } = _G

	Held.game = Game
	Held.Enum = Enums
	Held.warn = function(...: any)
		local Parts: { string } = {}
		for Index = 1, select("#", ...) do
			table.insert(Parts, tostring((select(Index, ...))))
		end

		local Message = table.concat(Parts, " ")
		local Sink = Heard
		if Sink ~= nil then
			Sink(Message)
			return
		end
		print(Message)
	end
	Held.task = zune.task
	Held.workspace = newproxy(false)
	Held.Random = table.freeze({ new = NewRandom })
end

return table.freeze({
	Install = Install,
	Listen = Listen,

	Game = Game,
	Enums = Enums,
	GUID = GUID,
})
