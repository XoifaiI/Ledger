--!strict
--!optimize 2

--[=[
	OwnOpKinds: the op kinds Ledger sends for itself, which no game op kind may take (one name, one concept): a
	quantity part's ops, a total's Bump, a cut's Cut, and a part's balance debits, named by their prefix. Built from
	the lists their protocols own.

	Return type: A frozen table with Names and Prefixes.
	Example usage:
		local OwnOpKinds = require("./Constants/OwnOpKinds")
		local Taken = table.find(OwnOpKinds.Names, "Take") ~= nil
--]=]

local Cuts = require("./Cuts")
local Extras = require("./Extras")
local Hot = require("./Hot")

local Names: { string } = {}
for _, PartOpKind in Hot.PartOpKinds do
	table.insert(Names, PartOpKind)
end
table.insert(Names, Extras.BumpOpKind)
table.insert(Names, Cuts.CutOpKind)

local Prefixes: { string } = { Hot.DebitKindPrefix }

return table.freeze({
	Names = table.freeze(Names),
	Prefixes = table.freeze(Prefixes),
})
