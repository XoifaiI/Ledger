--!strict
--!optimize 2

--[=[
	Read: what a read of a part teaches the quantity's view (hot keys sheet H9), for a walk's read and for Total's.
	The cache learns the stored value, and the view merges its entry by q. A part the key lacks is a zero entry, which
	every real write beats, and the view notes when it was read absent. A failed read teaches nothing.

	Return type: A plain table with LearnPart.
	Example usage:
		local Read = PartRead.LearnPart(State, "Shop", "global", Quantity, 2, Fetched, Clock)
--]=]

local Cache = require("../../../Keys/DataStore/Cache")
local Composed = require("../../../Shared/Composed")
local Events = require("../../../Shared/Events")
local HotShapes = require("../../../Shared/QuantityShapes")
local HotState = require("../State")
local Numbers = require("../../../Keys/DataStore/Numbers")
local PartBuild = require("../../../Keys/Quantity/Build")
local View = require("./View")

type ReadOutcome = Events.ReadOutcome
type QuantityName = HotShapes.QuantityName
type StoredRead = Numbers.StoredRead
type State = Composed.State

local function LearnPart(
	State: State,
	Store: string,
	Scope: string,
	Quantity: QuantityName,
	Index: number,
	Fetched: ReadOutcome,
	Clock: number
): StoredRead?
	if Fetched.Kind == "Failed" then
		return nil
	end
	local Server = State.Server
	local Key = PartBuild.PartKey(Store, Scope, Quantity, Index)
	local Read = Numbers.LearnStored(Server, Key, Cache.StoreOf(Server, Key).Setup, Fetched, Clock)
	local Known = HotState.ViewOf(State.Hot, Store, Scope, Quantity)
	local Entry = View.EntryOfRead(Read)
	if Entry ~= nil then
		View.Merge(Known, Index, Entry)
	end
	if Read.Kind == "Nothing" then
		View.NoteAbsent(Known, Index, Clock)
	end
	return Read
end

return {
	LearnPart = LearnPart,
}
