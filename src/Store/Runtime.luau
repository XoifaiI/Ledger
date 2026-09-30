--!strict
--!optimize 2

--[=[

	Runtime: What this server holds for every store: its number, its shown table, one Sender per
	key, and the heartbeat that acts for the open sessions.

	Number takes the server's number the first time it is asked for, and yields until it has one.
	SenderFor gives back the one Sender of a key, made on first use. Watch puts a session on the
	heartbeat and Unwatch takes it off. Every Windows.BEAT seconds the heartbeat asks each session
	what is due, and pushes or reads for it. CloseAll releases every session and flushes every key.

	Return type: A table with Shown, Number, SenderFor, Watch, Unwatch and CloseAll. The type is Watch.
	Example usage:
		local Key = Runtime.SenderFor(Store, Name, Build, { UserId })
--]=]

local Clock = require("../Server/Clock")
local DataStore = require("../Adapters/DataStore")
local Driver = require("../Server/Driver")
local Future = require("../Util/Future")
local Names = require("../Core/Constants/Names")
local Numbers = require("../Server/Numbers")
local Observer = require("../Util/Observer")
local Peek = require("../Server/Peek")
local Sender = require("../Server/Sender")
local Session = require("../Server/Session")
local Shown = require("../Server/Shown")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

export type Watch = {
	read Store: DataStore.Store,
	read Name: string,
	read Mark: string,
	read Build: Types.Build,
}

local Runtime = {}

Runtime.Shown = Shown.New()

local Taking: Future.Future<number?>? = nil
local Senders: { [string]: Sender.Sender } = {}
local Watched: { [Session.Session]: Watch } = {}
local Beating = false

local function Refresh(Player: Session.Session, Entry: Watch)
	local Context = Peek.Context(Entry.Store, Entry.Name, Entry.Mark, Entry.Build, Runtime.Shown)
	local Found = Driver.Run(Peek.Cached, Context):Wait()
	if type(Found) == "table" then
		Player:Adopt(Found)
	end
end

local function Beat()
	local Now = Clock.Now()
	for Player, Entry in Watched do
		local Due = Player:Due(Now)
		if Due == Session.DUE.Push then
			Player:Flush(Now)
		elseif Due == Session.DUE.Read then
			Player:Read(Now)
			task.spawn(Refresh, Player, Entry)
		end
	end
end

local function Heartbeat()
	while true do
		task.wait(Windows.BEAT)
		Beat()
	end
end

local function Take(): Future.Future<number?>
	local Counters = DataStore.Open(Names.NUMBERS)
	return Driver.Run(Numbers.Take, Numbers.Context(Counters, game.JobId))
end

function Runtime.Number(): number
	local Held = Taking or Take()
	Taking = Held
	local Number = Held:Wait()
	return Number :: number
end

function Runtime.SenderFor(Store: DataStore.Store, Name: string, Mark: string, Build: Types.Build, UserIds: { number }?): Sender.Sender
	local Held = Senders[Mark]
	if Held == nil then
		Held = Sender.New(Store, Name, Build, Runtime.Number(), UserIds)
		Senders[Mark] = Held
	end
	return Held :: Sender.Sender
end

function Runtime.Watch(Player: Session.Session, Entry: Watch)
	Watched[Player] = Entry
	if not Beating then
		Beating = true
		task.spawn(Heartbeat)
	end
end

function Runtime.Unwatch(Player: Session.Session)
	Watched[Player] = nil
end

function Runtime.CloseAll()
	local Now = Clock.Now()
	for Player in Watched do
		Player:Release(Now)
		Watched[Player] = nil
	end
	local Waits: { Future.Future<boolean> } = {}
	for _, Key in Senders do
		if Key.Writer.Items[1] then
			local Job, Settle = Future.Pending()
			local Connection: Observer.Connection
			Connection = Key.Emptied:Subscribe(function()
				Connection:Disconnect()
				Settle(true)
			end)
			Key:Flush()
			table.insert(Waits, Job)
		end
	end
	for _, Job in Waits do
		Job:Wait(Windows.CLOSE)
	end
end

return Runtime
