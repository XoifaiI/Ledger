--!strict
--!optimize 2

--[=[
	Showables: where rule 2's remembered states live (transaction sheet 19, Tx/Beside), and the one owner of that
	placement. A key this server serves (an open session, a local Follower, a copy holder) keeps its state whole in
	its cache entry. Any other key's state goes to a small set, Unserved, of at most UnservedShowableKeys keys
	(the server's Limits), which lets its least recently kept state go once the new one is in (Recency says why).

	A key that starts being served takes its state from the small set into its cache entry (Serve). A released
	session's state is dropped (Release); a key that stops being followed or held moves to the small set (Unserve).
	Either keeps the state while another role still serves the key. A key found gone loses its state wherever it is
	(Forget). Tx/Beside decides what is kept; this module only where.

	Return type: A plain table of functions, and the Served type.
	Example usage:
		local Held = Showables.Find(Server, Key)
		Showables.Keep(Server, Entry, Key, Remembered, Composed.ServedOf(State))
--]=]

local Cache = require("./Cache")
local Names = require("../Encoding/Names")
local Recency = require("../Recency")
local Shapes = require("../Shapes")

type StoreKey = Names.StoreKey
type CacheEntry = Shapes.CacheEntry
type ServerState = Shapes.ServerState
type Showable = Shapes.Showable

export type Served = {
	read Open: { read [string]: unknown },
	read Followers: { read [string]: unknown },
	read CopyHolders: { read [string]: unknown },
}

local function IsServed(Served: Served, Text: string): boolean
	return Served.Open[Text] ~= nil or Served.Followers[Text] ~= nil or Served.CopyHolders[Text] ~= nil
end

local function ForgetUnserved(Server: ServerState, Text: string)
	local Unserved = Server.Unserved
	Unserved.States[Text] = nil
	Recency.Remove(Unserved.Order, Text)
end

local function KeepUnserved(Server: ServerState, Text: string, Held: Showable)
	local Unserved = Server.Unserved
	local Order = Unserved.Order
	Unserved.States[Text] = Held
	Recency.Use(Order, Text)
	if Order.Count <= Cache.ServerLimits(Server).UnservedShowableKeys then
		return
	end
	local Least = Recency.Oldest(Order)
	if Least ~= nil then
		ForgetUnserved(Server, Least)
	end
end

local function Find(Server: ServerState, Key: StoreKey): Showable?
	local Text = Names.KeyText(Key)
	local Entry = Server.Caches[Text]
	if Entry ~= nil and Entry.Showable ~= nil then
		return Entry.Showable
	end
	return Server.Unserved.States[Text]
end

local function Keep(Server: ServerState, Entry: CacheEntry, Key: StoreKey, Held: Showable, Served: Served)
	local Text = Names.KeyText(Key)
	if IsServed(Served, Text) then
		Entry.Showable = Held
		ForgetUnserved(Server, Text)
		return
	end
	Entry.Showable = nil
	KeepUnserved(Server, Text, Held)
end

local function Serve(Server: ServerState, Key: StoreKey)
	local Text = Names.KeyText(Key)
	local Held = Server.Unserved.States[Text]
	local Entry = Server.Caches[Text]
	if Held == nil or Entry == nil then
		return
	end
	Entry.Showable = Held
	ForgetUnserved(Server, Text)
end

local function Forget(Server: ServerState, Key: StoreKey)
	local Text = Names.KeyText(Key)
	local Entry = Server.Caches[Text]
	if Entry ~= nil then
		Entry.Showable = nil
	end
	ForgetUnserved(Server, Text)
end

local function Release(Server: ServerState, Key: StoreKey, Served: Served)
	if IsServed(Served, Names.KeyText(Key)) then
		return
	end
	Forget(Server, Key)
end

local function Unserve(Server: ServerState, Key: StoreKey, Served: Served)
	local Text = Names.KeyText(Key)
	local Entry = Server.Caches[Text]
	if IsServed(Served, Text) or Entry == nil or Entry.Showable == nil then
		return
	end
	KeepUnserved(Server, Text, Entry.Showable)
	Entry.Showable = nil
end

return {
	Find = Find,
	Keep = Keep,
	Serve = Serve,
	Release = Release,
	Forget = Forget,
	Unserve = Unserve,
}
