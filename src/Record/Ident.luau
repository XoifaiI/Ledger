--!strict
--!optimize 2

-- a unique op id built from this server plus a count, so the half that repeats on every op costs almost nothing once a record is compressed

local HttpService = game:GetService("HttpService")

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
	return Node
end

local function Fresh(): string
	Count += 1
	return `{Home()}:{Count}`
end

local function Restart(Named: string?)
	Node = Named or ""
	Count = 0
end

return table.freeze({
	Fresh = Fresh,
	Restart = Restart,
	NODE_CHARS = NODE_CHARS
})
