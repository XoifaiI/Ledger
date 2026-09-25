--!strict
--!optimize 2

--[=[

	Players: The sessions a store keeps for the players on this server.

	Load reads a player's key into a session and starts its autosave, and Unload saves it on the way
	out. A load and its waiters belong to the Player object that asked. A player who rejoins while the
	load they left is still running gets the answer to their own load, never to the one they left.
	Two copies of one player share one session, and only the copy that called Load last releases it.
	A session that loads with money still being sent picks that up in the background. An idle session
	reads its key every fourth autosave, and an autosave short of budget skips rather than spend it.

	Return type: An empty table. It writes Wake, Handled, Autosave, Save, PickUp, Load, Unload, Get, Expect, IsLoaded, WaitForLoaded and Read onto the class.
	Example usage:
		require("./Api/Players")
		Bank:Load(Player)
--]=]

local Future = require("../../Util/Future")
local SetInterval = require("../../Util/SetInterval")
local TableUtil = require("../../Util/TableUtil")
local Windows = require("../../Core/Constants/Windows")
local Reasons = require("../../Core/Constants/Reasons")
local Compact = require("../../Record/Compact")
local Recovery = require("../../Protocol/Recovery")
local Session = require("../../Session/Session")
local Registry = require("../Registry")
local Write = require("./Write")
local Store = require("../Class")
local Types = require("../Types")

type Future<T...> = Future.Future<T...>
type Reason = Reasons.Reason
type Store = Types.Store<any>

local Players = game:GetService("Players")

local IDLE_EVERY = 4
local MIN_WRITE_BUDGET = 4
local MIN_HEAVY_BUDGET = 1
local HEAVY_PENDING = 256

local UNRESOLVED = Reasons.Unresolved
local REFUSED = Reasons.Refused

function Store.Wake(self: Store, Player: Player, Active: any?)
	local List = self.Waiters[Player]
	if List == nil then
		return
	end
	self.Waiters[Player] = nil
	for _, Thread in List do
		self.Wrapper.Scheduler.Resume(Thread, Active)
	end
end

function Store.Handled(self: Store, Player: Player, Why: Reason): boolean
	local Answer = self.Options.OnLoadFailed
	if Answer == nil then
		return false
	end

	local Ok, Took = pcall(Answer, Player, Why)
	if not Ok then
		warn(`Ledger: OnLoadFailed threw for {Player.Name}, so they get kicked as if it had said no: {Took}`)
		return false
	end
	if Took ~= true then
		return false
	end

	if Player.Parent ~= nil and Players:GetPlayerByUserId(Player.UserId) ~= nil then
		warn(`Ledger: OnLoadFailed said it handled {Player.Name} after a '{Why}' load but they are still in the server with no data. send them somewhere or kick them`)
	end
	return true
end

function Store.Autosave(self: Store, UserId: number)
	local Entry = self.Loaded[UserId]
	if Entry == nil then
		return
	end

	local Active = Entry.Active
	local Writing = #Active.Pending > 0 or Compact.Oversized(Active.LogSize, Active.LogBytes, Active.StateBytes)

	Entry.Ticks += 1
	if not Writing and Active.Parked == 0 and Entry.Ticks % IDLE_EVERY ~= 0 then
		return
	end

	local Reads = Enum.DataStoreRequestType.GetAsync
	local Writes = Enum.DataStoreRequestType.UpdateAsync

	local Floor = if #Active.Pending >= HEAVY_PENDING then MIN_HEAVY_BUDGET else MIN_WRITE_BUDGET
	local Short = if self.Wrapper:Budget(Reads) < Floor then Reads elseif Writing and self.Wrapper:Budget(Writes) < Floor then Writes else nil
	if Short ~= nil then
		self:Starved(Short)
		return
	end

	local Ok, Why = Entry.Active:Flush():Wait()
	if Ok and Compact.Oversized(Entry.Active.LogSize, Entry.Active.LogBytes, Entry.Active.StateBytes) then
		Ok, Why = Entry.Active:Compact():Wait()
	end
	if Ok or Active.Released or Why == REFUSED then
		return
	end
	warn(`Ledger: the autosave for {UserId} keeps failing, the datastore is probably down`)
end

function Store.Save(self: Store, Active: any): Future<boolean, Reason?>
	for UserId, Entry in self.Loaded do
		assert((Entry.Active :: any) ~= (Active :: any), `the session for {UserId} is being saved on the way out while the store still lists it as live`)
	end

	local Job = Active:Release()
	self.Saving[Job] = true
	self.Wrapper.Scheduler.Spawn(function()
		Job:Wait()
		self.Saving[Job] = nil
	end)
	return Job
end

function Store.PickUp(self: Store, Active: any, UserId: number)
	if Active.Landed ~= nil then
		self.Sweep:Add(self:Swept(), tostring(UserId))
	end

	local Held = Active:Get()._Held
	if not TableUtil.Occupied(Held) then
		return
	end

	local Writes = Enum.DataStoreRequestType.UpdateAsync
	local Pass: Recovery.Pass = {
		Limit = math.clamp(self.Wrapper:Budget(Writes) // Windows.PASS_SHARE, 1, Windows.PASS_LIMIT),
		Afford = function(): boolean
			return self:AffordsWrite(MIN_WRITE_BUDGET)
		end,
	}
	local Records, Format = self:Records(), self:Format()
	self.Wrapper.Scheduler.Spawn(function()
		local Ok, Clean = pcall(Recovery.Transfers, Records, Format, UserId, Held, Pass)
		if not Ok then
			Write.Failed("pick up the unfinished transfers on", tostring(UserId), Clean)
		end
		if not Ok or not Clean then
			self.Sweep:Add(self:Swept(), tostring(UserId))
		end
	end)
end

function Store.Load(self: Store, Player: Player)
	self:ExpectPlayers("Load")
	local UserId = Player.UserId
	local Again = self.Latest[UserId] == Player
	self.Latest[UserId] = Player

	if self.Loaded[UserId] ~= nil then
		if Again then
			warn(`Ledger: {Player.Name} already has a live session, ignoring this second Load`)
		end
		return
	end
	if self.Loads[Player] == "Loading" then
		warn(`Ledger: {Player.Name} is already loading, ignoring this second Load`)
		return
	end

	self.Loads[Player] = "Loading"

	local Job = Session.Load(self:Records(), self:Format(), tostring(UserId), self.TxWrapper)
	local Active, Why = Job:Wait()

	local Left = self.Loads[Player] == "Leaving"
	self.Loads[Player] = nil

	if Active == nil then
		self:Wake(Player, nil)
		if not self:Handled(Player, Why or UNRESOLVED) then
			Player:Kick("Your data failed to load, please rejoin")
		end
		return
	end

	local Shared = self.Loaded[UserId]
	if Shared ~= nil then
		Active:Release()
		if Left or not Player.Parent then
			self:Wake(Player, nil)
			return
		end
		self:Wake(Player, Shared.Active)
		return
	end

	local Stopping = self.Closed or Registry.Shutting.Now
	if Left or Stopping or not Player.Parent then
		if not Stopping then
			self:PickUp(Active, UserId)
		end
		self:Save(Active)
		self:Wake(Player, nil)
		return
	end

	assert(self.Loads[Player] == nil, "a load finished while this player was still marked as loading")

	self.Loaded[UserId] = {
		Active = Active,
		Ticks = 0,
		Ticker = SetInterval(self.Wrapper.Scheduler, Windows.AUTOSAVE, function()
			self:Autosave(UserId)
		end, self.Wrapper.Scheduler.Roll() * Windows.AUTOSAVE),
	}
	self:Wake(Player, Active)
	self:PickUp(Active, UserId)
end

function Store.Unload(self: Store, Player: Player)
	self:ExpectPlayers("Unload")
	local UserId = Player.UserId
	local Entry = self.Loaded[UserId]
	local Latest = self.Latest[UserId] == Player

	if Entry == nil or not Latest then
		if Latest then
			self.Latest[UserId] = nil
		end
		if self.Loads[Player] ~= nil then
			self.Loads[Player] = "Leaving"
		end
		self:Wake(Player, nil)
		return
	end

	self.Latest[UserId] = nil
	self.Loaded[UserId] = nil
	self.Wrapper.Scheduler.Cancel(Entry.Ticker)

	local Job = self:Save(Entry.Active)
	Job:Wait()
	self.Saving[Job] = nil
end

function Store.Get(self: Store, Player: Player): any?
	self:ExpectPlayers("Get")
	local Entry = self.Loaded[Player.UserId]
	return if Entry then Entry.Active else nil
end

function Store.Expect(self: Store, Player: Player): any
	self:ExpectPlayers("Expect")
	local Entry = self.Loaded[Player.UserId]
	return assert(Entry and Entry.Active, `data for {Player.Name} is not loaded`)
end

function Store.IsLoaded(self: Store, Player: Player): boolean
	self:ExpectPlayers("IsLoaded")
	return self.Loaded[Player.UserId] ~= nil
end

function Store.WaitForLoaded(self: Store, Player: Player): any?
	self:ExpectPlayers("WaitForLoaded")
	local Entry = self.Loaded[Player.UserId]
	if Entry ~= nil then
		return Entry.Active
	end
	if not Player.Parent then
		return nil
	end

	local List = self.Waiters[Player]
	if List == nil then
		List = {}
		self.Waiters[Player] = List
	end
	table.insert(List, coroutine.running())
	return coroutine.yield()
end

function Store.Read(self: Store, Player: Player): any
	self:ExpectPlayers("Read")
	local Entry = self.Loaded[Player.UserId]
	return if Entry then Entry.Active:Get() else nil
end

return table.freeze({})
