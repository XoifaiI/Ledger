--!strict
--!optimize 2

--[=[

	Errors: Plumbing. Misuse throws at the game's own call, and Bug warns about Ledger's own mistake.

	Every Bug warning starts with BUG. OnServer throws when a call that needs the server runs on a
	client. It raises its own error at level 3 and does not call Misuse.

	Return type: A table with Misuse, Bug, OnServer and BUG.
	Example usage:
		Errors.Misuse("a transaction needs at least two legs")
--]=]

local Server = require("../Adapters/Server")

local BUG = "Ledger bug:"

local Errors = { BUG = BUG }

function Errors.Misuse(Message: string, Depth: number?): never
	error(`Ledger: {Message}`, 3 + (Depth or 0))
end

function Errors.Bug(Message: string)
	warn(`{BUG} {Message}. please report this`)
end

function Errors.OnServer(What: string)
	if Server.IsServer() then
		return
	end
	error(`Ledger: {What} runs on the server, since only the server can reach a datastore. the client can read Ledger.Answer`, 3)
end

return Errors
