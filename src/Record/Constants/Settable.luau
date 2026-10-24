--!strict
--!optimize 2

--[=[
	Settable: the constants a game may set, each with its default and the Check rule its value must
	pass. Every time is whole seconds. Only bounds on one value are rules here: a bound between two settable
	values is a cross rule that Api/Validate owns.

	Return type: A frozen table of entries, each with a Default and a Rule; LegLimit has no Default.
	Example usage:
		local Settable = require("./Constants/Settable")
		local Problem = Settable.SaveInterval.Rule(Options.SaveInterval)
--]=]

local Check = require("../Encoding/Check")
local Cuts = require("./Cuts")
local Messages = require("./Messages")
local Record = require("./Record")
local Transaction = require("./Transaction")

local TimedWindowDefault = 3 * Record.SecondsPerMinute

local Settable = {
	SaveInterval = table.freeze({
		Default = 30,
		Rule = Check.Whole(1, Record.Ceiling),
	}),

	IdleReadInterval = table.freeze({
		Default = 120,
		Rule = Check.Whole(1, Record.Ceiling),
	}),

	OrphanAge = table.freeze({
		Default = Record.SecondsPerDay,
		Rule = Check.Whole(Transaction.OrphanAgeLeast, Transaction.OrphanAgeMost),
	}),

	TimedWindow = table.freeze({
		Default = TimedWindowDefault,
		Rule = Check.Whole(Record.TimedWindowLeast, Record.Ceiling),
	}),

	UntimedWindow = table.freeze({
		Default = TimedWindowDefault,
		Rule = Check.Whole(Record.UntimedWindowLeast, Record.Ceiling),
	}),

	CutWindow = table.freeze({
		Default = 6 * Record.SecondsPerMinute,
		Rule = Check.Whole(Record.Late + Cuts.EraseBound + Record.SkewSigmas * Record.Sigma + 1, Record.Ceiling),
	}),

	HoldMax = table.freeze({
		Default = 900,
		Rule = Check.Whole(1, Record.Ceiling),
	}),

	Kick = table.freeze({
		Default = true,
		Rule = Check.Boolean,
	}),

	KickMessage = table.freeze({
		Default = Messages.KickMessageDefault,
		Rule = Check.TextAtLeast(1),
	}),

	LegLimit = table.freeze({
		Rule = Check.WholeAtLeast(Transaction.LegLeast),
	}),
}

return table.freeze(Settable)
