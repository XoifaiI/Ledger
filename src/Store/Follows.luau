--!strict
--!optimize 2

--[=[
	Follows: Object. The keys one store follows through their copies, and who listens to each.

	A store keeps what it holds of the last Limits.SHOWN_MAX keys it followed or peeked at with a
	MaxAge. One follower machine runs for a key while anything follows it. A new listener hears the
	last state shown at once. Stale hears a followed key each time a write of this server lands on it
	past the state its copy shows. Lapse is how far past a holder's lease this server waits before it
	takes the lease, drawn again for each call so that servers do not take together. Totals time
	their holder the same way.

	Return type: The Follows module, and the Followed type.
	Example usage:
		local Connection = Follows.Follow(Followed, Owner, "42", Listener)
--]=]

local Answer = require("../Core/Answer")
local Backoff = require("../Machine/Backoff")
local Copies = require("../Record/Copies")
local Copy = require("../Calls/Copy")
local Keys = require("./Keys")
local Limits = require("../Core/Constants/Limits")
local Lru = require("../Util/Lru")
local Observer = require("../Util/Observer")
local Runner = require("../Machine/Runner")
local Runtime = require("./Runtime")
local Windows = require("../Core/Constants/Windows")

type Answer = Answer.Answer
type Owner = Keys.Owner
type State = { [string]: any }

type Kept = {
	read Held: Copies.Held,
	read Watch: Observer.Observer<State>,
}

export type Followed = Lru.Lru<Kept>

local Shared = Runtime.Shared

local Follows = {}

local function Copied(Followed: Followed, Owner: Owner, Key: string | number): Kept
	local Name = tostring(Key)
	local Found = Followed:Get(Name)
	if Found == nil then
		Found = { Held = Copies.New(Keys.Ref(Owner, Key)), Watch = Observer.New() }
		Followed:Put(Name, Found)
	end
	return Found :: Kept
end

local function Following(Owner: Owner, Found: Kept)
	local Watch = Found.Watch
	local Context = Copy.Context(Found.Held, Owner.Build, Shared.Shown, Shared:Server(), Follows.Lapse())
	Context.Followed = function(): boolean
		return Watch:Count() > 0
	end
	Context.Show = function(State: State)
		Watch:Push(State)
	end
	Runner.Run(Copy.Follow, Context, Shared.Places)
end

function Follows.New(): Followed
	return Lru.New(Limits.SHOWN_MAX)
end

function Follows.Lapse(): number
	return Windows.LAPSE + Backoff.Jitter(Windows.JITTER)
end

function Follows.Peek(Followed: Followed, Owner: Owner, Key: string | number, MaxAge: number): State | Answer
	local Found = Copied(Followed, Owner, Key)
	local Context = Copy.Context(Found.Held, Owner.Build, Shared.Shown, Shared:Server(), Follows.Lapse())
	Context.Once = true
	Context.MaxAge = MaxAge
	Context.Show = function(State: State)
		Found.Watch:Push(State)
	end
	local Shown = Runner.Run(Copy.Follow, Context, Shared.Places):Wait()
	return if Shown == nil then Answer.Unresolved else Shown
end

function Follows.Follow(Followed: Followed, Owner: Owner, Key: string | number, Listener: (State: State) -> ()): Observer.Connection
	local Found = Copied(Followed, Owner, Key)
	local Made = Found.Watch:Subscribe(Listener)
	local Last = Found.Held.State
	if Last then
		task.spawn(Listener, Last)
	end
	if not Found.Held.Running then
		Copies.Start(Found.Held)
		task.spawn(Following, Owner, Found)
	end
	return Made
end

function Follows.Stale(Followed: Followed, Owner: Owner, Listener: (Key: string) -> ()): Observer.Connection
	return Shared.Landing:Subscribe(function(Landed: Runtime.Landing)
		local Found = if Landed.Ref.Store == Owner.Name then Followed:Get(Landed.Ref.Key) else nil
		if Found and Found.Held.State and Landed.Writes > Found.Held.Writes then
			Listener(Landed.Ref.Key)
		end
	end)
end

return Follows
