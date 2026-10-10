--!strict
--!optimize 2

--[=[
	Streams: the observer streams the core's Emit commands feed, by stream name and key. A key's last View is kept with
	no listener. Follows keeps one observer per key, whose first caller's Start and Stop serve all; a late listener gets
	its last value. Forget drops a released session's view and its View and Fate streams, never a Follow observer.

	Return type: A plain table with OnEmit, ViewOf, Views, Fates, Follows, Stales and Forget.
	Example usage:
		Streams.Views(Key):Subscribe(print)
		Streams.OnEmit({ Kind = "Emit", Stream = "View", Key = Key, Value = View })
--]=]

local Events = require("../Events")
local Names = require("../Encoding/Names")
local Observer = require("../Util/Observer")
local Value = require("../Stored/Value")
local WritingAnswers = require("../Writing/Answers")

type Answer = Events.Answer
type EmitCommand = Events.EmitCommand
type StoreKey = Names.StoreKey
type Fields = Value.Fields
type FateEmission = WritingAnswers.FateEmission
type Observer<T> = Observer.Observer<T>
type Subject<T> = Observer.Subject<T>

type Handler = (Key: StoreKey, Given: unknown) -> ()

local function NoStream(Stream: string): string
	return `Streams: the core emitted on the stream {Stream}, which no handler feeds.`
end

local LastViews: { [string]: Fields } = {}
local ViewSubjects: { [string]: Subject<Fields> } = {}
local FateSubjects: { [string]: Subject<FateEmission> } = {}

local FollowObservers: { [string]: Observer<Answer> } = {}
local FollowEmits: { [string]: (Answer) -> () } = {}

local StaleSubjects: { [string]: Subject<StoreKey> } = {}

local function SubjectOf<T>(Subjects: { [string]: Subject<T> }, Text: string): Subject<T>
	local Kept = Subjects[Text]
	if Kept ~= nil then
		return Kept
	end
	local Made: Subject<T> = Observer.New()
	Subjects[Text] = Made
	return Made
end

local function DestroySubject<T>(Subjects: { [string]: Subject<T> }, Text: string)
	local Kept = Subjects[Text]
	if Kept == nil then
		return
	end
	Kept:Destroy()
	Subjects[Text] = nil
end

local function OnView(Key: StoreKey, View: Fields)
	local Text = Names.KeyText(Key)
	LastViews[Text] = View
	local Subject = ViewSubjects[Text]
	if Subject ~= nil then
		Subject:Push(View)
	end
end

local function OnFate(Key: StoreKey, Emission: FateEmission)
	local Subject = FateSubjects[Names.KeyText(Key)]
	if Subject ~= nil then
		Subject:Push(Emission)
	end
end

local function OnFollow(Key: StoreKey, Given: Answer)
	local Emit = FollowEmits[Names.KeyText(Key)]
	if Emit ~= nil then
		Emit(Given)
	end
end

local function OnStale(Key: StoreKey)
	local Subject = StaleSubjects[Key.Store]
	if Subject ~= nil then
		Subject:Push(Key)
	end
end

local Handlers = {
	View = OnView,
	Fate = OnFate,
	Follow = OnFollow,
	Stale = OnStale,
}

local function OnEmit(Command: EmitCommand)
	local Handler = (Handlers :: { [string]: Handler })[Command.Stream]
	if Handler == nil then
		error(NoStream(Command.Stream), 0)
	end
	Handler(Command.Key, Command.Value)
end

local function ViewOf(Key: StoreKey): Fields?
	return LastViews[Names.KeyText(Key)]
end

local function Views(Key: StoreKey): Observer<Fields>
	return SubjectOf(ViewSubjects, Names.KeyText(Key))
end

local function Fates(Key: StoreKey): Observer<FateEmission>
	return SubjectOf(FateSubjects, Names.KeyText(Key))
end

local function Follows(Key: StoreKey, Start: () -> (), Stop: () -> ()): Observer<Answer>
	local Text = Names.KeyText(Key)
	local Kept = FollowObservers[Text]
	if Kept ~= nil then
		return Kept
	end
	local Made = Observer.FromLatest(function(Emit: (Answer) -> ())
		FollowEmits[Text] = Emit
		Start()
		return function()
			FollowEmits[Text] = nil
			Stop()
		end
	end)
	FollowObservers[Text] = Made
	return Made
end

local function Stales(Store: string): Observer<StoreKey>
	return SubjectOf(StaleSubjects, Store)
end

local function Forget(Key: StoreKey)
	local Text = Names.KeyText(Key)
	LastViews[Text] = nil
	DestroySubject(ViewSubjects, Text)
	DestroySubject(FateSubjects, Text)
end

return {
	OnEmit = OnEmit,
	ViewOf = ViewOf,
	Views = Views,
	Fates = Fates,
	Follows = Follows,
	Stales = Stales,
	Forget = Forget,
}
