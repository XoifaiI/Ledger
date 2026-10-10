--!strict
--!optimize 2

--[=[
	ProbeAdvice: the warning a DidApply asked without the probe flag earns when it answers Unresolved for a timed name,
	once per store. Without the flag the read writes nothing, so it can answer true or Unresolved and never false.

	Return type: A plain table with Heard.
	Example usage:
		ProbeAdvice.Heard(Settings.Name, Asked, IsProbe, Answered)
--]=]

local Events = require("../Events")
local Reasons = require("../Constants/Reasons")
local Shapes = require("../Shapes")

type Answer = Events.Answer
type AskedName = Shapes.AskedName

local Warned: { [string]: true } = {}

local function Advice(Store: string): string
	return `Ledger: DidApply on the store {Store} answered Unresolved for a name with a first send time. It was asked `
		.. "without Probe = true, so it read and wrote nothing and can only answer true or Unresolved. "
		.. "Ask again with Probe = true to get true or false. Ledger warns of this once per store."
end

local function IsTimed(Asked: AskedName): boolean
	return Asked.Kind == "Drawn" or (Asked.Kind == "Game" and Asked.Stamp ~= nil)
end

local function Heard(Store: string, Asked: AskedName, IsProbe: boolean, Given: Answer)
	if IsProbe or Warned[Store] ~= nil or not IsTimed(Asked) then
		return
	end
	if Given.Kind == "Failed" and Given.Reason == Reasons.Unresolved then
		Warned[Store] = true
		warn(Advice(Store))
	end
end

return {
	Heard = Heard,
}
