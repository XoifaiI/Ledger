--!strict
--!optimize 2

--[=[

	Follow: A copy every server reads, and the tick that keeps a followed key fresh.

	One MemoryStore item per copy holds a state, its record's stamp, the time it was made and the
	build that made it. A build older than that refuses the copy. A source makes the state: a key's
	folds its record to the game's fields, a total's sums its shards. The one server whose claim
	lands refills a stale or absent item. The rest answer the copy they hold and never wait. Each
	copy rolls its own slack onto the stale window. A state too big for an item takes the item off,
	and every server makes its own. A map that misses holds a server to its copy for a keep window.
	An item, a write or a refill with an older stamp than the copy is left alone. What a copy hands
	back is frozen. A followed copy stays for as long as the store. The rest sit in an Lru, so the
	copy used longest ago goes first. A tick reads the item,
	doubles its interval while the stamp sits still up to a cap, and pushes only when it moved. A
	write on this server goes into its own copy, never the map. A Peek with a MaxAge of zero
	refills through the claim, and an item refilled inside the claim window answers it.

	Return type: An empty table. It writes Copy, Recorded, Copied, Degraded, Refilled, Noted, Uncopied, Follow and Unfollowed onto the class.
	Example usage:
		local Follow = require("./Follow")
		self:Follow("config"):Subscribe(Show)
--]=]

local Clock = require("../../Util/Clock")
local Future = require("../../Util/Future")
local Observer = require("../../Util/Observer")
local SetInterval = require("../../Util/SetInterval")
local TableUtil = require("../../Util/TableUtil")
local Windows = require("../../Core/Constants/Windows")
local Follows = require("../../Core/Constants/Follows")
local MemoryStore = require("../../Core/Constants/MemoryStore")
local Reasons = require("../../Core/Constants/Reasons")
local Shapes = require("../../Core/Shapes")
local Mark = require("../../Encode/Mark")
local Measure = require("../../Encode/Measure")
local Storable = require("../../Encode/Storable")
local Schema = require("../../Record/Schema")
local Write = require("./Write")
local Store = require("../Class")
local Types = require("../Types")

type KeyLike = Shapes.KeyLike
type Reason = Reasons.Reason
type Store = Types.Store<any>
type Copy = Types.Copy
type Item = Types.Copied
type Source = Types.Source

local ITEM_ROOM = MemoryStore.MAX_ITEM - Follows.ROOM
local NUMBERS = table.freeze({ "Stamp", "Claimed", "Version", "Floor" })

local UNRESOLVED = Reasons.Unresolved
local BEHIND = Reasons.Behind

local Failed = Write.Failed

local function Fields(State: any): any
	if type(State) ~= "table" then
		return State
	end

	local Kept: { [any]: any } = {}
	for Key, Value in State do
		if type(Key) == "string" and Storable.Bookkeeping(Key) then
			continue
		end
		Kept[Key] = Value
	end
	return Kept
end

local function Read(Value: any): Item?
	if type(Value) ~= "table" or type(Value.At) ~= "number" then
		return nil
	end
	if Value.State ~= nil and type(Value.State) ~= "table" then
		return nil
	end
	for _, Named in NUMBERS do
		if Value[Named] ~= nil and type(Value[Named]) ~= "number" then
			return nil
		end
	end
	return Value
end

local function Fresh(Item: Item, Now: number, Copy: Copy, Force: boolean): boolean
	return Item.State ~= nil and Now - Item.At <= (if Force then Windows.TALLY_CLAIM else Windows.TALLY_CACHE + Copy.Slack)
end

local function Claimed(Item: Item, Now: number): boolean
	local At = Item.Claimed
	return At ~= nil and Now - At <= Windows.TALLY_CLAIM
end

local function Usable(Item: Item, Known: number): boolean
	return Item.State ~= nil and (Item.Version or 0) >= Known
end

local function Held(Copy: Copy): (any?, Reason?)
	return Copy.State, if Copy.State == nil then UNRESOLVED else nil
end

local function Newer(Copy: Copy, Item: Item): boolean
	return Copy.State == nil or (Item.Stamp or 0) >= (Copy.Stamp or 0)
end

local function Settle(Copy: Copy, State: any, Stamp: number?, At: number, Seen: number): any
	local Moved = Copy.State == nil or (Stamp or 0) ~= (Copy.Stamp or 0)
	Copy.State = TableUtil.FreezeDelta(State)
	Copy.Stamp = Stamp
	Copy.At = At
	Copy.Seen = Seen

	local Emit = Copy.Emit
	if Moved and Emit ~= nil then
		Emit(Copy.State)
	end
	return Copy.State
end

function Store.Copy(self: Store, Key: string): Copy
	local Held = self.Followed[Key] or self.Copies:Get(Key)
	if Held ~= nil then
		return Held
	end

	local Fresh: Copy = { At = 0, Seen = 0, Slack = self.Wrapper.Scheduler.Roll() * Windows.COPY_SLACK, Behind = false }
	return self.Copies:Put(Key, Fresh)
end

function Store.Recorded(self: Store, Key: string): Source
	return {
		Key = Key,
		Slot = Mark.Cached({ self.Wrapper.Name, Key }),
		Map = self.Copier,
		Cost = 1,
		Fits = true,
		Refill = function(_Copy: Copy): (any?, number?, Reason?)
			local Ok, Stamp, Folded = pcall(function(): (number?, any)
				local Stored, Stamped = self:Records():Read(Key)
				self:Watch(Key, Stored)
				local State = self:Fold(Stored)
				self:WatchHeld(Key, State)
				return Stamped, State
			end)
			if not Ok then
				return nil, nil, Failed("read", Key, Stamp)
			end
			return Fields(Folded), Stamp, nil
		end,
	}
end

function Store.Uncopied(self: Store, Key: string, Bytes: number)
	local Meter = self.Meter
	local Now = Clock.Now()
	if Now - Meter.Uncopied < Windows.AUTOSAVE then
		return
	end

	Meter.Uncopied = Now
	local Why = if Bytes == math.huge then "holds a buffer, which a MemoryStore item cannot" else `is {Bytes} bytes as json and a MemoryStore item holds {MemoryStore.MAX_ITEM}`
	warn(`Ledger: '{Key}' on '{self.Options.Name}' {Why}, so every server reads it from the datastore on every tick. keep a followed key small`)
end

function Store.Refilled(self: Store, Copy: Copy, Now: number, Source: Source, Minted: boolean?): (any?, Reason?)
	local Wrapper = Source.Map
	local State, Stamp, Why = Source.Refill(Copy)
	if State == nil then
		if Minted and Wrapper ~= nil then
			Wrapper:RemoveAsync(Source.Slot)
		end
		return nil, Why
	end

	local Walked = Clock.Now()
	if Wrapper ~= nil then
		local Steps = self.Migrations
		local Bytes = if not Source.Fits then 0 elseif TableUtil.HasBuffer(State) then math.huge else Measure(State)
		if Bytes <= ITEM_ROOM then
			local Wrote = Wrapper:UpdateAsync(Source.Slot, function(Current: any): any
				local Newer = Read(Current)
				if Newer ~= nil and Newer.State ~= nil and Newer.At > Walked then
					return nil
				end
				return { State = State, Stamp = Stamp, At = Walked, Version = #Steps, Floor = Schema.FloorOf(Steps) }
			end, Windows.TALLY_KEEP)
			Copy.Down = if Wrote then nil else Walked
		else
			self:Uncopied(Source.Key, Bytes)
			Wrapper:RemoveAsync(Source.Slot)
		end
	end

	if Copy.State ~= nil and (Stamp or 0) < (Copy.Stamp or 0) then
		return Settle(Copy, Copy.State, Copy.Stamp, Copy.At, Walked), nil
	end
	return Settle(Copy, State, Stamp, Walked, Walked), nil
end

function Store.Degraded(self: Store, Copy: Copy, Now: number, Source: Source): (any?, Reason?)
	if Copy.State ~= nil and Now - Copy.Seen <= Windows.TALLY_KEEP then
		return Copy.State, nil
	end
	if not self:Affords(Enum.DataStoreRequestType.GetAsync, Source.Cost) then
		return nil, UNRESOLVED
	end
	return self:Refilled(Copy, Now, Source)
end

function Store.Copied(self: Store, Copy: Copy, Now: number, Force: boolean, Source: Source): (any?, Reason?)
	local Wrapper = Source.Map
	if Wrapper == nil then
		return self:Refilled(Copy, Now, Source)
	end

	local Known = #self.Migrations
	local Got, Value = Wrapper:GetAsync(Source.Slot)
	if not Got then
		Copy.Down = Now
		return self:Degraded(Copy, Now, Source)
	end

	Copy.Down = nil
	local Item = Read(Value)
	if Item ~= nil then
		local Floor = Item.Floor
		if Floor ~= nil and Floor > Known then
			if not Copy.Behind then
				Copy.Behind = true
				warn(`Ledger: could not read the copy of '{Source.Key}', a newer server wrote it and this one cannot read that yet. finish the deploy`)
			end
			return nil, BEHIND
		end
		Copy.Behind = false

		if Claimed(Item, Now) or (Fresh(Item, Now, Copy, Force) and Usable(Item, Known)) then
			if Usable(Item, Known) and Newer(Copy, Item) then
				return Settle(Copy, Item.State, Item.Stamp, Item.At, Now), nil
			end
			return Held(Copy)
		end
	end

	local Seen: Item? = nil
	local Minted = false
	local Won, Claim = Wrapper:UpdateAsync(Source.Slot, function(Current: any): any
		Seen = nil
		Minted = false
		local Standing = Read(Current)
		if Standing ~= nil and (Claimed(Standing, Now) or (Fresh(Standing, Now, Copy, Force) and Usable(Standing, Known))) then
			Seen = Standing
			return nil
		end

		Minted = Standing == nil
		local Next: any = if Standing ~= nil then table.clone(Standing) else { At = 0 }
		Next.Claimed = Now
		return Next
	end, Windows.TALLY_KEEP)

	if not Won then
		Copy.Down = Now
		if Item ~= nil and Usable(Item, Known) and Newer(Copy, Item) then
			return Settle(Copy, Item.State, Item.Stamp, Item.At, Now), nil
		end
		return self:Degraded(Copy, Now, Source)
	end
	if Claim ~= nil then
		return self:Refilled(Copy, Now, Source, Minted)
	end

	local Standing = Seen
	if Standing ~= nil and Usable(Standing, Known) and Newer(Copy, Standing) then
		return Settle(Copy, Standing.State, Standing.Stamp, Standing.At, Now), nil
	end
	return Held(Copy)
end

function Store.Noted(self: Store, Key: string, Record: Shapes.Record<any>, Stamp: number?)
	local Copy = self.Followed[Key] or self.Copies:Get(Key)
	if Copy == nil or Stamp == nil then
		return
	end
	if Copy.Stamp ~= nil and Stamp <= Copy.Stamp then
		return
	end

	local Ok, State = pcall(function(): any
		return Fields(self:Fold(Record))
	end)
	if not Ok then
		return
	end
	Settle(Copy, State, Stamp, Copy.At, Clock.Now())
end

function Store.Follow(self: Store, Key: KeyLike): Observer.Observer<any>
	local Resolved = self:Resolve(Key, "Follow")
	assert(self.Keys == "String", `Follow is for string keyed stores, '{self.Options.Name}' uses player keys`)

	local Copy = self:Copy(Resolved)
	local Stream = Copy.Stream
	if Stream ~= nil then
		return Stream
	end

	local Scheduler = self.Wrapper.Scheduler
	local Source = self:Recorded(Resolved)
	Stream = Observer.From(function(Emit: (any) -> ()): () -> ()
		Copy.Emit = Emit

		local Interval = Windows.FOLLOW
		Copy.Ticker = SetInterval(Scheduler, Interval, function(): number
			local Before = Copy.Stamp
			Future.New(function()
				self:Copied(Copy, Clock.Now(), false, Source)
			end):Wait()

			Interval = if (Copy.Stamp or 0) ~= (Before or 0) then Windows.FOLLOW else math.min(Interval * 2, Windows.FOLLOW_CAP)
			return Interval
		end, Scheduler.Roll() * Windows.FOLLOW)

		return function()
			local Ticker = Copy.Ticker
			Copy.Ticker = nil
			Copy.Emit = nil
			if Ticker ~= nil then
				Scheduler.Cancel(Ticker)
			end
		end
	end)
	Copy.Stream = Stream
	self.Followed[Resolved] = Copy
	return Stream
end

function Store.Unfollowed(self: Store)
	for _, Copy in self.Followed do
		local Stream = Copy.Stream
		if Stream ~= nil then
			Stream:Destroy()
		end
	end
	table.clear(self.Followed)
	self.Copies:Clear()
end

return table.freeze({})
