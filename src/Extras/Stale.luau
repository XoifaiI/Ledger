--!strict
--!optimize 2

--[=[
	Stale: the keys this server wrote that its observers show too old (extras sheet E9, R8). Once Stale is called, a
	landing of this server above the q it shows for a key, or of another incarnation than the one it shows, emits
	that key on the Stale stream. It sends nothing, and a key never shown is not stale.

	Return type: A plain table with OnStale and NoteLanded.
	Example usage:
		Stale.NoteLanded(State, Landed, Commands)
--]=]

local Composed = require("../Composed")
local Events = require("../Events")
local ExtrasShapes = require("./Shapes")
local Replies = require("../Replies")
local Shapes = require("../Shapes")
local Shown = require("../Reading/Shown")

type Command = Events.Command
type StaleCall = ExtrasShapes.StaleCall
type LandedValue = Shapes.LandedValue
type State = Composed.State

local StaleStream = "Stale"

local function OnStale(State: State, Call: StaleCall, _Arrived: number, _Clock: number, Commands: { Command })
	State.Extras.IsStaleWatched = true
	Replies.Reply(Commands, Call.CallId, Replies.DoneAnswer)
end

local function NoteLanded(State: State, Landed: LandedValue, Commands: { Command })
	if not State.Extras.IsStaleWatched then
		return
	end
	local Written = Landed.Written.Book
	if not Shown.IsNewerThanShown(State.Server, Landed.Key, Written.Writes, Written.Identity) then
		return
	end
	local Emission: Command = { Kind = "Emit", Stream = StaleStream, Key = Landed.Key, Value = nil }
	table.insert(Commands, Emission)
end

return {
	OnStale = OnStale,
	NoteLanded = NoteLanded,
}
