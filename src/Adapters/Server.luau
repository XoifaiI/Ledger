--!strict
--!optimize 2

--[=[

	Server: Plumbing. The engine's server, as Ledger reaches it.

	IsServer says whether this code runs on a server. JobId names this server. Each reaches the
	engine only when it is called.

	Return type: A table with IsServer and JobId.
	Example usage:
		local Job = Server.JobId()
--]=]

local RunService = game:GetService("RunService")

local Server = {}

function Server.IsServer(): boolean
	return RunService:IsServer()
end

function Server.JobId(): string
	return game.JobId
end

return Server
