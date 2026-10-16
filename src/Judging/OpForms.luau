--!strict
--!optimize 2

--[=[
	OpForms: what an op's form says of the op, for the modules that queue, send, judge and run ops. A cut, a
	Tent and a Commit have no sequence number: HasSequence says so, and SequenceOf throws for one.

	Return type: A plain table with HasSequence, SequenceOf and IsDurable.
	Example usage:
		local Sequence = OpForms.SequenceOf(Op.Form)
--]=]

local Shapes = require("../Shapes")

type OpForm = Shapes.OpForm

local ModuleName = "OpForms"
local NoSequence =
	`{ModuleName}: a cut, a Tent or a Commit has no sequence number. The caller must not queue, send or decide one here`

local function HasSequence(Form: OpForm): boolean
	return Form.Kind ~= "Cut" and Form.Kind ~= "Tent" and Form.Kind ~= "Commit"
end

local function SequenceOf(Form: OpForm): number
	if Form.Kind == "Cut" or Form.Kind == "Tent" or Form.Kind == "Commit" then
		error(NoSequence)
	end
	return Form.Sequence
end

local function IsDurable(Form: OpForm): boolean
	return Form.Kind ~= "Hopeful"
end

return {
	HasSequence = HasSequence,
	SequenceOf = SequenceOf,
	IsDurable = IsDurable,
}
