--!strict
--!optimize 2

--[=[
	Memory: runs the MemoryStore commands and the JSON Decode, each in its own thread, and feeds the event each gives
	back. SetAsync throws when it cannot set, so its boolean is not read. An Update answering nil is a cancel only when
	its last run returned nil, else the retry limit. A throwing item is raised again and feeds nothing.

	Return type: A plain table with OnGet, OnSet, OnUpdate, OnRemove and OnDecode.
	Example usage:
		Memory.OnGet(Command, Feed)
--]=]

local Events = require("../Events")
local Platform = require("./Platform")
local Services = require("./Services")
local Threads = require("../Util/Threads")

type DecodeCommand = Events.DecodeCommand
type DecodeOutcome = Events.DecodeOutcome
type Happening = Events.Happening
type MemoryFetched = Events.MemoryFetched
type MemoryGetCommand = Events.MemoryGetCommand
type MemoryOutcome = Events.MemoryOutcome
type MemoryRemoveCommand = Events.MemoryRemoveCommand
type MemorySetCommand = Events.MemorySetCommand
type MemoryUpdateCommand = Events.MemoryUpdateCommand
type Result = Services.Result

type Feed = (Happening: Happening) -> ()

type CompletedRun = { read Output: unknown }

local function CoreFault(Command: MemoryUpdateCommand): never
	error(
		`Memory: the core faulted inside the item of the MemoryUpdate request on {Command.Map}/{Command.Key}.`
			.. ` The update did not land and no event was fed.`
			.. ` See the console's TransformCallbackFailed line for the fault.`,
		0
	)
end

local function FetchedOf(Result: Result): MemoryFetched
	if Result.Kind == "Ok" then
		return { Kind = "Found", Value = Result.Value }
	end
	if Result.Kind == "Absent" then
		return { Kind = "Absent" }
	end
	return { Kind = "Failed" }
end

local function UpdateOutcomeOf(Result: Result, LastRun: CompletedRun?): MemoryOutcome
	if Result.Kind == "Err" or LastRun == nil then
		return { Kind = "Err" }
	end
	if Result.Kind == "Ok" then
		return { Kind = "Ok" }
	end
	if LastRun.Output ~= nil then
		return { Kind = "Err" }
	end
	return { Kind = "Nil" }
end

local function SetOutcomeOf(Result: Result): MemoryOutcome
	if Result.Kind == "Err" then
		return { Kind = "Err" }
	end
	return { Kind = "Ok" }
end

local function DecodeOutcomeOf(Result: Result): DecodeOutcome
	if Result.Kind == "Ok" then
		return { Kind = "Found", Value = Result.Value }
	end
	if Result.Kind == "Absent" then
		return { Kind = "Found", Value = nil }
	end
	return { Kind = "Failed" }
end

local function OnGet(Command: MemoryGetCommand, Feed: Feed)
	Threads.Spawn(function()
		local Fetched = FetchedOf(Services.MemoryGet(Command.Map, Command.Key))
		Feed({ Kind = "MemoryRead", RequestId = Command.RequestId, Fetched = Fetched, Fraction = Platform.Fraction() })
	end)
end

local function OnSet(Command: MemorySetCommand, Feed: Feed)
	Threads.Spawn(function()
		local Result = Services.MemorySet(Command.Map, Command.Key, Command.Item, Command.Expiry)
		Feed({ Kind = "MemoryResult", RequestId = Command.RequestId, Outcome = SetOutcomeOf(Result) })
	end)
end

local function OnUpdate(Command: MemoryUpdateCommand, Feed: Feed)
	Threads.Spawn(function()
		local IsRunning = false
		local LastRun: CompletedRun? = nil
		local Result = Services.MemoryUpdate(Command.Map, Command.Key, function(Current: unknown): unknown
			IsRunning = true
			local Next = Command.Item(Current, Platform.Now())
			IsRunning = false
			LastRun = { Output = Next }
			return Next
		end, Command.Expiry)
		if IsRunning then
			CoreFault(Command)
		end
		Feed({ Kind = "MemoryResult", RequestId = Command.RequestId, Outcome = UpdateOutcomeOf(Result, LastRun) })
	end)
end

local function OnRemove(Command: MemoryRemoveCommand, Feed: Feed)
	Threads.Spawn(function()
		local Result = Services.MemoryRemove(Command.Map, Command.Key)
		local Outcome: MemoryOutcome = if Result.Kind == "Err" then { Kind = "Err" } else { Kind = "Ok" }
		Feed({ Kind = "MemoryResult", RequestId = Command.RequestId, Outcome = Outcome })
	end)
end

local function OnDecode(Command: DecodeCommand, Feed: Feed)
	Threads.Spawn(function()
		local Outcome = DecodeOutcomeOf(Services.JsonDecode(Command.Text))
		Feed({ Kind = "Decoded", RequestId = Command.RequestId, Outcome = Outcome })
	end)
end

return {
	OnGet = OnGet,
	OnSet = OnSet,
	OnUpdate = OnUpdate,
	OnRemove = OnRemove,
	OnDecode = OnDecode,
}
