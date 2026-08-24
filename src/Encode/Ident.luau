--!strict
--!optimize 2

--[=[
	Ident: Makes an op id from this server and a count.

	The half of the id that repeats on each op costs almost nothing after the record is compressed.
	Restart pins the server name, which a test uses to get the same ids two times.

	Return type: A table with Fresh, Home, Restart and NODE_CHARS.
	Example usage:
		local Ident = require("./Ident")
		local Id = Ident.Fresh()
--]=]

local HttpService = game:GetService("HttpService")

local Fault = require("../Contract/Fault")

local NODE_CHARS = 16

local Node = ""
local Count = 0

local function Home(): string
	if Node ~= "" then
		return Node
	end

	local Job = game.JobId
	local Source = if type(Job) == "string" and #Job > 0 then Job else HttpService:GenerateGUID(false)
	Node = string.sub((string.gsub(Source, "[^%w]", "")), 1, NODE_CHARS)
	Fault.Holds(#Node > 0, "an op id needs a server name to build on, and this server gave nothing usable")
	return Node
end

local function Fresh(): string
	Count += 1
	Fault.Holds(Count < 2 ^ 53, "this server has built more op ids than a number can count exactly")
	return `{Home()}:{Count}`
end

local function Restart(Named: string?)
	Node = Named or ""
	Count = 0
end

return table.freeze({
	Fresh = Fresh,
	Home = Home,
	Restart = Restart,
	NODE_CHARS = NODE_CHARS,
})
