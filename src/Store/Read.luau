--!strict
--!optimize 2

--[=[
	Read: The reads of a store.

	A state, a record, a version and its history, and whether a name has been applied.
	Each read answers a value and a reason. A value of nil therefore always means the read failed,
	and never means empty.
	Inspect copies the record and freezes it, so a caller cannot reach what this server folds from.

	Return type: A table with Peek, DidApply, History, PeekVersion and Inspect.
	Example usage:
		local Read = require("./Read")
		local State = self:Peek(1):Wait()
--]=]

local Future = require("../Util/Future")
local TableUtil = require("../Util/TableUtil")
local Contract = require("../Contract/Op")
local Reasons = require("../Contract/Reason")
local Entries = require("../Kernel/Entries")
local Write = require("./Write")
local Store = require("./Class")
local Types = require("./Types")

type Future<T...> = Future.Future<T...>
type Record = Contract.Record<any>
type KeyLike = Contract.KeyLike
type HistoryEntry = Contract.HistoryEntry
type Reason = Reasons.Reason
type Store = Types.Store

local Failed = Write.Failed

function Store.Peek(self: Store, Key: KeyLike): Future<any?, Reason?>
	local Resolved = self:Resolve(Key, "Peek")

	return Future.New(function(): (any?, Reason?)
		local Ok, State = pcall(function(): any
			local Record = self:ReadRecord(Resolved)
			self:Watch(Resolved, Record)

			local Folded = self:Fold(Record)
			self:WatchHeld(Resolved, Folded)
			return Folded
		end)
		if not Ok then
			return nil, Failed("read", Resolved, State)
		end
		return State, nil
	end)
end

function Store.DidApply(self: Store, Key: KeyLike, Id: string): Future<boolean?, Reason?>
	local Resolved = self:Resolve(Key, "DidApply")
	assert(type(Id) == "string" and #Id > 0, "DidApply needs the same Once name the op was written under")

	return Future.New(function(): (boolean?, Reason?)
		local Ok, Applied = pcall(function(): boolean
			local Record = self:ReadRecord(Resolved)
			self:Watch(Resolved, Record)

			local State: any = self:Fold(Record)
			self:WatchHeld(Resolved, State)
			return Entries.Has(State._Received, Entries.ONCE, Id)
		end)
		if not Ok then
			return nil, Failed(`check what has been applied to`, Resolved, Applied)
		end
		return Applied, nil
	end)
end

function Store.History(self: Store, Key: KeyLike, Limit: number?): Future<{ HistoryEntry }?, Reason?>
	local Resolved = self:Resolve(Key, "History")
	local Page = math.clamp(if type(Limit) == "number" then Limit else 25, 1, 100)

	return Future.New(function(): ({ HistoryEntry }?, Reason?)
		local Ok, Rows = pcall(function(): { HistoryEntry }
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
		if not Ok then
			return nil, Failed("list the history for", Resolved, Rows)
		end
		return Rows, nil
	end)
end

function Store.PeekVersion(self: Store, Key: KeyLike, Version: string): Future<any?, Reason?>
	local Resolved = self:Resolve(Key, "PeekVersion")
	assert(type(Version) == "string" and #Version > 0, "PeekVersion needs a Version string from History")

	return Future.New(function(): (any?, Reason?)
		local Ok, State = pcall(function(): any
			return self:Fold(self:Records():ReadVersion(Resolved, Version))
		end)
		if not Ok then
			return nil, Failed(`read version '{Version}' of`, Resolved, State)
		end
		return State, nil
	end)
end

function Store.Inspect(self: Store, Key: KeyLike): Future<Record?, Reason?>
	local Resolved = self:Resolve(Key, "Inspect")

	return Future.New(function(): (Record?, Reason?)
		local Ok, Stored = pcall(function(): Record
			return self:ReadRecord(Resolved)
		end)
		if not Ok then
			return nil, Failed("inspect", Resolved, Stored)
		end
		return TableUtil.DeepFreeze(TableUtil.DeepCopy(Stored)), nil
	end)
end

return table.freeze({})
