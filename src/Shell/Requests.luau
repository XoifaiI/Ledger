--!strict
--!optimize 2

--[=[
	Requests: runs the DataStore commands Update, Count, Get and Remove, each in a thread, and feeds each event
	back. An Update's transform runs Transform.Step at the landing clock, as Stepping, and passes its closure to a
	rerun. A throwing transform is raised again and feeds nothing. An error Roblox raises before the store (Refusals)
	feeds an Err that says so.

	Return type: A plain table with OnUpdate, OnCount, OnGet and OnRemove, and the Store type.
	Example usage:
		Requests.OnUpdate(Command, Stores[Command.Target.Store], Feed)
--]=]

local Cache = require("../Reading/Cache")
local Events = require("../Events")
local JudgingShapes = require("../Judging/Shapes")
local Names = require("../Encoding/Names")
local Platform = require("./Platform")
local Record = require("../Constants/Record")
local Refusals = require("./Refusals")
local Services = require("./Services")
local Shapes = require("../Shapes")
local ShellSetup = require("./Setup")
local Stepping = require("./Stepping")
local Threads = require("../Util/Threads")
local Transform = require("../Judging/Transform")

type Closure = JudgingShapes.Closure
type KeyKind = Shapes.KeyKind
type Note = JudgingShapes.Note
type Setup = Shapes.Setup
type StoreKey = Names.StoreKey
type CountCommand = Events.CountCommand
type GetCommand = Events.GetCommand
type Happening = Events.Happening
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type RemoveCommand = Events.RemoveCommand
type UpdateCommand = Events.UpdateCommand
type Result = Services.Result

export type Store = {
	read Setup: Setup,
	read IsPlayerStore: boolean,
}

type Feed = (Happening: Happening) -> ()

local GameKind = Record.KeyKind.Game

local function RequestText(Target: StoreKey, Kind: string): string
	return `the {Kind} request on {Target.Store}/{Target.Scope}/{Target.Key}`
end

local function CoreFault(Target: StoreKey, Kind: string): never
	error(
		`Requests: the core faulted inside the transform of {RequestText(Target, Kind)}.`
			.. ` The write did not land and no event was fed.`
			.. ` See the console's "Transform function error" line for the fault.`,
		0
	)
end

local function NotUserId(Target: StoreKey): never
	error(
		`Requests: the key {Target.Key} of the player store {Target.Store} is not a user id.`
			.. ` The API must give a player store keys that are user ids.`,
		0
	)
end

local function UserIdsOf(Store: Store, Target: StoreKey, Kind: KeyKind): { number }?
	if not Store.IsPlayerStore or Kind ~= GameKind then
		return nil
	end
	if not ShellSetup.IsUserIdKey(Target.Key) then
		return NotUserId(Target)
	end
	return { tonumber(Target.Key) :: number }
end

local function HearRefusal(Result: Result): boolean
	return Result.Kind == "Err" and Refusals.Hear(Result.Code)
end

local function OutcomeOf(Result: Result, Note: Note?): Outcome
	if Result.Kind == "Err" then
		return { Kind = "Err", IsBeforeStore = HearRefusal(Result) }
	end
	if Note == nil then
		return { Kind = "Err" }
	end
	if Result.Kind == "Ok" then
		return { Kind = "Ok", Value = Result.Value, Note = Note }
	end
	return { Kind = "Nil", Note = Note }
end

local function FetchedOf(Result: Result): ReadOutcome
	if Result.Kind == "Ok" then
		return { Kind = "Found", Value = Result.Value }
	end
	if Result.Kind == "Absent" then
		return { Kind = "Absent" }
	end
	return { Kind = "Failed", IsThrottled = Result.IsThrottled }
end

local function OnUpdate(Command: UpdateCommand, Store: Store, Feed: Feed)
	Threads.Spawn(function()
		local Target = Command.Target
		local Kind = Cache.KindOfKey(Target)
		local UserIds = UserIdsOf(Store, Target, Kind)
		local Closure: Closure = { Wrote = false, Ran = {} }
		local LastNote: Note? = nil
		local IsRunning = false
		local Result = Services.Update(Target, function(Stored: unknown): (unknown, { number }?)
			IsRunning = true
			local Output, Note =
				Stepping.Run(Transform.Step, Stored, Command.Request, Platform.Now(), Store.Setup, Closure, Kind)
			IsRunning = false
			Closure = Note.Closure
			LastNote = Note
			if Output.Kind == "Cancel" then
				return nil, nil
			end
			return Output.Value, UserIds
		end)
		if IsRunning then
			CoreFault(Target, Command.Request.Kind)
		end
		Feed({ Kind = "Result", RequestId = Command.RequestId, Outcome = OutcomeOf(Result, LastNote) })
	end)
end

local function OnCount(Command: CountCommand, Feed: Feed)
	Threads.Spawn(function()
		local Written: string? = nil
		local IsRunning = false
		local IsRefused = false
		local Result = Services.Update(Command.Target, function(Stored: unknown): (unknown, { number }?)
			IsRunning = true
			local Added = Command.Add(Stored)
			IsRunning = false
			Written = Added
			IsRefused = Added == nil
			return Added, nil
		end)
		if IsRunning then
			CoreFault(Command.Target, Command.Kind)
		end
		HearRefusal(Result)
		if IsRefused then
			Feed({ Kind = "CounterUnusable", RequestId = Command.RequestId })
			return
		end
		local Counted = if Result.Kind == "Ok" then Written else nil
		Feed({ Kind = "Counted", RequestId = Command.RequestId, Written = Counted })
	end)
end

local function OnGet(Command: GetCommand, Feed: Feed)
	Threads.Spawn(function()
		local Result = Services.Get(Command.Target)
		HearRefusal(Result)
		Feed({
			Kind = "Read",
			RequestId = Command.RequestId,
			Fetched = FetchedOf(Result),
			Fraction = Platform.Fraction(),
		})
	end)
end

local function OnRemove(Command: RemoveCommand, Feed: Feed)
	Threads.Spawn(function()
		local Result = Services.Remove(Command.Target)
		HearRefusal(Result)
		Feed({ Kind = "Removed", RequestId = Command.RequestId, IsOk = Result.Kind ~= "Err" })
	end)
end

return {
	OnUpdate = OnUpdate,
	OnCount = OnCount,
	OnGet = OnGet,
	OnRemove = OnRemove,
}
