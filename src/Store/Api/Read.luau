--!strict
--!optimize 2

--[=[
	Read: The reads of a store.

	A state, a record, a version and its history, and whether a name has been applied.
	Each read answers a value and a reason. A value of nil therefore always means the read failed,
	and never means empty.
	Inspect copies the record and freezes it, so a caller cannot reach what this server folds from.
	Each read is the same shape: try it, and turn a failure into a reason. Reading holds that shape,
	so a read here is only the part that is its own.

	Return type: A table with Peek, DidApply, History, PeekVersion and Inspect.
	Example usage:
		local Read = require("./Read")
		local State = self:Peek(1):Wait()
--]=]

local Future = require("../../Util/Future")
local TableUtil = require("../../Util/TableUtil")
local Shapes = require("../../Core/Shapes")
local Reasons = require("../../Core/Reasons")
local Applied = require("../../Core/Applied")
local Write = require("./Write")
local Store = require("../Class")
local Types = require("../Types")

type Future<T...> = Future.Future<T...>
type Record = Shapes.Record<any>
type KeyLike = Shapes.KeyLike
type HistoryEntry = Shapes.HistoryEntry
type Reason = Reasons.Reason
type Store = Types.Store<any>

local Failed = Write.Failed

local function Reading<T>(What: string, Key: string, Body: () -> T): Future<T?, Reason?>
	return Future.New(function(): (T?, Reason?)
		local Ok, Held = pcall(Body)
		if not Ok then
			return nil, Failed(What, Key, Held)
		end
		return Held, nil
	end)
end

local function Followed(self: Store, Key: string): any
	local Record = self:ReadRecord(Key)
	self:Watch(Key, Record)

	local State = self:Fold(Record)
	self:WatchHeld(Key, State)
	return State
end

function Store.Peek(self: Store, Key: KeyLike): Future<any?, Reason?>
	local Resolved = self:Resolve(Key, "Peek")

	return Reading("read", Resolved, function(): any
		return Followed(self, Resolved)
	end)
end

function Store.DidApply(self: Store, Key: KeyLike, Id: string): Future<boolean?, Reason?>
	local Resolved = self:Resolve(Key, "DidApply")
	assert(type(Id) == "string" and #Id > 0, "DidApply needs the same Once name the op was written under")

	return Reading("check what has been applied to", Resolved, function(): boolean
		return Applied.Has(Followed(self, Resolved)._Received, Applied.ONCE, Id)
	end)
end

function Store.History(self: Store, Key: KeyLike, Limit: number?): Future<{ HistoryEntry }?, Reason?>
	local Resolved = self:Resolve(Key, "History")
	local Page = math.clamp(if type(Limit) == "number" then Limit else 25, 1, 100)

	return Reading("list the history for", Resolved, function(): { HistoryEntry }
		local Fine, Pages = self.Wrapper:ListVersionsAsync(Resolved, Enum.SortDirection.Descending, nil, nil, Page)
		if not Fine then
			error(Pages)
		end

		local Out: { HistoryEntry } = {}
		for _, Info in (Pages :: DataStoreVersionPages):GetCurrentPage() do
			local Version = Info :: DataStoreObjectVersionInfo
			table.insert(Out, { Version = Version.Version, At = Version.CreatedTime / 1000, Deleted = Version.IsDeleted })
		end
		return Out
	end)
end

function Store.PeekVersion(self: Store, Key: KeyLike, Version: string): Future<any?, Reason?>
	local Resolved = self:Resolve(Key, "PeekVersion")
	assert(type(Version) == "string" and #Version > 0, "PeekVersion needs a Version string from History")

	return Reading(`read version '{Version}' of`, Resolved, function(): any
		return self:Fold(self:Records():ReadVersion(Resolved, Version))
	end)
end

function Store.Inspect(self: Store, Key: KeyLike): Future<Record?, Reason?>
	local Resolved = self:Resolve(Key, "Inspect")

	return Reading("inspect", Resolved, function(): Record
		return TableUtil.DeepFreeze(TableUtil.DeepCopy(self:ReadRecord(Resolved)))
	end)
end

return table.freeze({})
