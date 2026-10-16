--!strict
--!optimize 2

--[=[
	Sessions: a player store's Load, Unload, lookups and each key's session until Release answers. Load answers the
	session, nil and the load's reason (after OnLoadFailed, then the kick if Kick), or nil and nil if the player left,
	the server closed or Destroy began meanwhile. A second Load answers as the first. Loading a held key ends its
	session first.

	Return type: A plain table with Load, Unload, Get, Expect, IsLoaded, WaitForLoaded, Read and ReleaseAll.
	Example usage:
		Store.Load = Sessions.Load
		local Session, Reason = Vault:Load(Player)
--]=]

local Args = require("./Validate/Args")
local Calls = require("../Shell/Calls")
local Events = require("../Events")
local Future = require("../Util/Future")
local Keys = require("./Validate/Keys")
local Names = require("../Encoding/Names")
local Reasons = require("../Constants/Reasons")
local Runner = require("../Shell/Runner")
local Session = require("./Session")
local ShellSetup = require("../Shell/Setup")
local Stores = require("./Validate/Stores")
local Threads = require("../Util/Threads")

type Call = Events.Call
type Future<T...> = Future.Future<T...>
type Reason = Reasons.Reason
type Session = Session.Session
type Settings = ShellSetup.Settings

type Holder = {
	read Settings: Settings,
	read Sessions: { [string]: Session },
}

local Phases = Session.Phase

local PlayersService = "Players"

local function NotLoaded(Where: string, Player: Player): string
	return `{Where}: Player must be a player whose session is loaded on this store, got the player with UserId `
		.. `{Player.UserId}`
end

local function IsGone(Player: Player): boolean
	return Player.Parent ~= game:GetService(PlayersService)
end

local function Failed(Settings: Settings, Player: Player, Why: Reason)
	local Handler = Settings.OnLoadFailed
	if Handler ~= nil then
		Threads.Spawn(Handler, Player, Why)
	end
	if Settings.Kick then
		Player:Kick(Settings.KickMessage)
	end
end

local function IsHeldFor(Found: Session, Player: Player): boolean
	local Phase = Session.PhaseOf(Found)
	if Found.Player ~= Player then
		return false
	end
	return Phase == Phases.Loading or Phase == Phases.Leaving or Phase == Phases.Loaded
end

local function Leave(Found: Session)
	if Session.PhaseOf(Found) == Phases.Loaded then
		Session.End(Found)
		return
	end
	Session.MarkLeaving(Found)
	Session.WaitForEnd(Found)
end

local function DropWhenEnded(Store: Holder, Text: string, Found: Session)
	Session.WaitForEnd(Found)
	if Store.Sessions[Text] == Found then
		Store.Sessions[Text] = nil
	end
end

local function HeldOf(Store: Holder, Text: string): Session?
	local Found = Store.Sessions[Text]
	if Found == nil or Session.PhaseOf(Found) == Phases.Released then
		return nil
	end
	return Found
end

local function TextOf(Store: Holder, Player: Player, Where: string): string
	local Checked = Keys.Player(Store.Settings, Player, Where)
	return Names.KeyText(Keys.Key(Store.Settings, Checked, Where))
end

local function FoundOf(Store: Holder, Player: Player, Where: string): Session?
	local Found = HeldOf(Store, TextOf(Store, Player, Where))
	if Found == nil or Found.Player ~= Player then
		return nil
	end
	return Found
end

local function LoadedOf(Store: Holder, Player: Player, Where: string): Session?
	local Found = FoundOf(Store, Player, Where)
	if Found == nil or Session.PhaseOf(Found) ~= Phases.Loaded then
		return nil
	end
	return Found
end

local function HeldSessions(Store: Holder): { Session }
	local Held: { Session } = {}
	for Text in Store.Sessions do
		local Found = HeldOf(Store, Text)
		if Found ~= nil then
			table.insert(Held, Found)
		end
	end
	return Held
end

local function LeaveAll(Leaving: { Session }, Seconds: number)
	if #Leaving == 0 then
		return
	end
	local AllLeft: Future<()>, EndAll: () -> () = Future.Pending()
	local Left = #Leaving
	local function LeaveOne(Found: Session)
		Leave(Found)
		Left -= 1
		if Left == 0 then
			EndAll()
		end
	end
	for _, Found in Leaving do
		Threads.Spawn(LeaveOne, Found)
	end
	AllLeft:Wait(Seconds)
end

local function AnswerOfEarlier(Earlier: Session): (Session?, Reason?)
	if Session.WaitForLoad(Earlier) then
		return Earlier, nil
	end
	return nil, Session.LoadFailureOf(Earlier)
end

local function LoadOpening(Settings: Settings, Player: Player, Opening: Session): (Session?, Reason?)
	local Made: Call = {
		Kind = "Call",
		Method = "Load" :: "Load",
		CallId = Calls.NewCallId(),
		Key = Opening.Key,
		MustExist = Settings.MustExist,
	}
	local Given = Runner.Call(Made):Wait()
	local HasLeft = Session.PhaseOf(Opening) == Phases.Leaving or IsGone(Player)
	if Given.Kind ~= "Succeeded" then
		local IsReported = Given.Reason ~= Reasons.Closed and not HasLeft
		local Why = if IsReported then Given.Reason else nil
		Session.NotOpened(Opening, Why)
		if Why ~= nil then
			Failed(Settings, Player, Why)
		end
		return nil, Why
	end
	if HasLeft then
		Session.End(Opening)
		return nil, nil
	end
	Session.Opened(Opening)
	return Opening, nil
end

local function Load(self: Holder, Player: Player): (Session?, Reason?)
	local Where = "Store:Load"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckNotDestroying(self, Settings.Name)
	local Checked = Keys.Player(Settings, Player, Where)
	local Key = Keys.Key(Settings, Checked, Where)
	Args.OutsideListener(Where)
	local Text = Names.KeyText(Key)

	local Earlier = HeldOf(self, Text)
	while Earlier ~= nil do
		if IsHeldFor(Earlier, Checked) then
			return AnswerOfEarlier(Earlier)
		end
		Leave(Earlier)
		Earlier = HeldOf(self, Text)
	end
	if Stores.IsDestroyingOrDestroyed(self) then
		return nil, nil
	end

	local Opening = Session.New(Settings, Checked, Key)
	self.Sessions[Text] = Opening
	Threads.Spawn(DropWhenEnded, self, Text, Opening)
	local IsAnswered, Loaded, Why = pcall(LoadOpening, Settings, Checked, Opening)
	if not IsAnswered then
		Session.EndUnanswered(Opening)
		error(Loaded, 0)
	end
	return Loaded, Why
end

local function Unload(self: Holder, Player: Player): ()
	local Where = "Store:Unload"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	local Found = FoundOf(self, Player, Where)
	Args.OutsideListener(Where)
	if Found ~= nil then
		Leave(Found)
	end
end

local function Get(self: Holder, Player: Player): Session?
	local Where = "Store:Get"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	return LoadedOf(self, Player, Where)
end

local function Expect(self: Holder, Player: Player): Session
	local Where = "Store:Expect"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	local Found = LoadedOf(self, Player, Where)
	if Found == nil then
		error(NotLoaded(Where, Player), 0)
	end
	return Found
end

local function IsLoaded(self: Holder, Player: Player): boolean
	local Where = "Store:IsLoaded"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	return LoadedOf(self, Player, Where) ~= nil
end

local function WaitForLoaded(self: Holder, Player: Player): Session?
	local Where = "Store:WaitForLoaded"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	local Found = FoundOf(self, Player, Where)
	if Found == nil then
		return nil
	end
	if Session.PhaseOf(Found) ~= Phases.Loaded then
		Args.OutsideListener(Where)
	end
	if not Session.WaitForLoad(Found) then
		return nil
	end
	return Found
end

local function Read(self: Holder, Player: Player): unknown
	local Where = "Store:Read"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	local Found = LoadedOf(self, Player, Where)
	if Found == nil then
		return nil
	end
	return Found:Get()
end

local function ReleaseAll(Store: Holder, Seconds: number): number
	local Releasing = HeldSessions(Store)
	LeaveAll(Releasing, Seconds)
	local Unknown = 0
	for _, Found in Releasing do
		Unknown += Session.UnknownFateCount(Found)
	end
	return Unknown
end

return {
	Load = Load,
	Unload = Unload,
	Get = Get,
	Expect = Expect,
	IsLoaded = IsLoaded,
	WaitForLoaded = WaitForLoaded,
	Read = Read,
	ReleaseAll = ReleaseAll,
}
