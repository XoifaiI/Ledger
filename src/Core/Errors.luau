--!strict
--!optimize 2

--[=[

	Errors: The two ways Ledger speaks up that are not answers.

	Misuse throws at the game's own call when it was handed something it cannot use. Bug warns when
	Ledger caught its own mistake, and every such warning starts with BUG, so a test fails on one it
	did not ask for. What the datastore or another server did is never thrown: it comes back as an
	answer. OnServer is the misuse of calling a part of Ledger that needs the server from a client.
	It asks when it is called and not when a module is required, so a client can still require Ledger.
	It raises its own error rather than calling Misuse, since the compiler inlines a call inside one
	module and the level would then point one frame too far out.

	Return type: A table with Misuse, Bug, OnServer and BUG.
	Example usage:
		local Errors = require("./Errors")
		Errors.Misuse("a transaction needs at least two legs")
--]=]

local BUG = "Ledger bug:"

local function Misuse(Message: string, Depth: number?): never
	error(`Ledger: {Message}`, 3 + (Depth or 0))
end

local function Bug(Message: string)
	warn(`{BUG} {Message}. please report this`)
end

local function OnServer(What: string)
	if game:GetService("RunService"):IsServer() then
		return
	end
	error(`Ledger: {What} runs on the server, since only the server can reach a datastore. the client can read Ledger.Answer`, 3)
end

return table.freeze({
	Misuse = Misuse,
	Bug = Bug,
	OnServer = OnServer,
	BUG = BUG,
})
