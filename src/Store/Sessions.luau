--!strict
--!optimize 2

--[=[
	Sessions: Object. The sessions one store has open, and the loads still running.

	Spec: record 5.2 and 6.

	A load reads the player's key, with a fresh read when the shown table has forgotten the key. A
	key that holds nothing opens on the store's default, unless the store's keys must exist. A second
	Load of a player whose load is still running gets the same future. A player whose load fails is
	kicked, unless OnLoadFailed says it handled them, and a handler that throws counts as not
	handled. A player who left during their load is unloaded once it ends.

	Return type: The Sessions module, and the Held and Handler types.
	Example usage:
		local Loaded = Sessions.Load(Held, Owner, Player):Wait()
--]=]

local Answer = require("../Core/Answer")
local Book = require("../Record/Book")
local Clock = require("../Machine/Clock")
local Future = require("../Util/Future")
local Keys = require("./Keys")
local Peek = require("../Calls/Peek")
local Queue = require("../Record/Queue")
local Runtime = require("./Runtime")
local Session = require("./Session")
local View = require("../Record/View")

type Answer = Answer.Answer
type Reply = Queue.Reply

export type Handler = (Player: Player, Why: Answer) -> boolean

export type Held = {
	read Loaded: { [Player]: Session.Session },
	read Loading: { [Player]: Future.Future<Reply> },
	read OnLoadFailed: Handler?,
}

local KICKED = "Your data could not load. Please rejoin."

local Shared = Runtime.Shared

local Sessions = {}

local function Open(Held: Held, Owner: Keys.Owner, Player: Player): Reply
	local Key = tostring(Player.UserId)
	local At = Keys.Ref(Owner, Key)
	local Found = Keys.Read(Owner, Key, if Shared.Shown:Stale(Book.Address(At)) then Peek.Fresh else Peek.Cached)
	local Loaded: View.View? = nil
	if type(Found) == "table" then
		Loaded = Found
	elseif Found ~= Answer.Missing or Owner.MustExist then
		return Found
	end
	local Opened = Session.New(Shared, Shared:SaveFor(At, { Player.UserId }), Loaded, Owner.MustExist, Clock.Now())
	Held.Loaded[Player] = Opened
	Shared:Watch(Opened, At)
	return true
end

local function Failed(Held: Held, Owner: Keys.Owner, Player: Player, Why: Answer)
	local Handle = Held.OnLoadFailed
	if Handle then
		local Ok, Handled = pcall(Handle, Player, Why)
		if Ok and Handled == true then
			return
		elseif not Ok then
			warn(`Ledger: OnLoadFailed of {Owner.Name} threw for {Player.Name}, so they are kicked: {Handled}`)
		end
	end
	Player:Kick(KICKED)
end

local function Load(Held: Held, Owner: Keys.Owner, Player: Player): Reply
	local Reply = Open(Held, Owner, Player)
	Held.Loading[Player] = nil
	if Player.Parent == nil then
		Sessions.Unload(Held, Player)
	elseif Reply ~= true then
		Failed(Held, Owner, Player, Reply)
	end
	return Reply
end

function Sessions.New(OnLoadFailed: Handler?): Held
	return { Loaded = {}, Loading = {}, OnLoadFailed = OnLoadFailed }
end

function Sessions.Load(Held: Held, Owner: Keys.Owner, Player: Player): Future.Future<Reply>
	if Held.Loaded[Player] then
		return Future.Completed(true :: Reply)
	end
	local Running = Held.Loading[Player] or Future.Spawn(Load, Held, Owner, Player)
	Held.Loading[Player] = Running
	return Running
end

function Sessions.Get(Held: Held, Player: Player): Session.Session?
	return Held.Loaded[Player]
end

function Sessions.Unload(Held: Held, Player: Player): Future.Future<boolean>
	local Opened = Held.Loaded[Player]
	if Opened == nil then
		return Future.Completed(true)
	end
	Held.Loaded[Player] = nil
	Shared:Unwatch(Opened)
	return Opened:Unload(Clock.Now())
end

return Sessions
