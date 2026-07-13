--!strict
--!optimize 2

--[=[
    Janitor: cleanup bag, add a connection instance thread function or anything with destroy disconnect cancel or cleanup, then wipe them all at once

    Return type: frozen table { New }
    Example usage:
        local Janitor = require("./Janitor")
        local Bin = Janitor.New()
        Bin:Add(Instance.new("Part"))
        Bin:Destroy()
--]=]

export type Cleanable =
	((...any) -> ...any)
	| thread
	| Instance
	| RBXScriptConnection
	| { read Destroy: any }
	| { read Disconnect: any }
	| { read Cancel: any }
	| { read Cleanup: any }

type Entry = {
	Item: any,
	Method: string?,
}

type JanitorImpl = {
	__index: JanitorImpl,

	Add: <T>(self: Janitor, Item: T & Cleanable, MethodName: string?) -> T,
	Remove: (self: Janitor, Item: any) -> (),
	Cleanup: (self: Janitor) -> (),
	Destroy: (self: Janitor) -> (),
}

export type Janitor = setmetatable<{}, JanitorImpl>

type Private = {
	Tasks: {Entry},
	Destroyed: boolean,
}

local Janitor = {}
Janitor.__index = Janitor

local function ToPrivate(self: Janitor): Private
	return self :: any
end

local function Clean(Entry: Entry)
	local Item = Entry.Item
	local Method = Entry.Method
	local Kind = typeof(Item)

	if Method then
		Item[Method](Item)
	elseif Kind == "function" then
		Item()
	elseif Kind == "thread" then
		if coroutine.status(Item) ~= "dead" then
			task.cancel(Item)
		end
	elseif Kind == "RBXScriptConnection" then
		Item:Disconnect()
	elseif Kind == "Instance" then
		Item:Destroy()
	elseif Kind == "table" then
		local Object = Item :: {
			Destroy: ((any) -> ())?,
			Disconnect: ((any) -> ())?,
			Cancel: ((any) -> ())?,
			Cleanup: ((any) -> ())?,
		}
		if Object.Destroy then
			Object.Destroy(Object)
		elseif Object.Disconnect then
			Object.Disconnect(Object)
		elseif Object.Cancel then
			Object.Cancel(Object)
		elseif Object.Cleanup then
			Object.Cleanup(Object)
		end
	end
end

function Janitor.Add<T>(self: Janitor, Item: T & Cleanable, MethodName: string?): T
	local Private = ToPrivate(self)
	if Private.Destroyed then
		local Ok, Err = pcall(Clean, { Item = Item, Method = MethodName })
		if not Ok then
			warn(`Janitor cleanup errored: {Err}`)
		end
		return Item
	end

	table.insert(Private.Tasks, { Item = Item, Method = MethodName })
	return Item
end

function Janitor.Remove(self: Janitor, Item: any)
	local Tasks = ToPrivate(self).Tasks
	for Index = #Tasks, 1, -1 do
		if Tasks[Index].Item == Item then
			local Ok, Err = pcall(Clean, Tasks[Index])
			if not Ok then
				warn(`Janitor cleanup errored: {Err}`)
			end
			table.remove(Tasks, Index)
		end
	end
end

function Janitor.Cleanup(self: Janitor)
	local Tasks = ToPrivate(self).Tasks
	for Index = #Tasks, 1, -1 do
		local Ok, Err = pcall(Clean, Tasks[Index])
		if not Ok then
			warn(`Janitor cleanup errored: {Err}`)
		end
		Tasks[Index] = nil
	end
end

function Janitor.Destroy(self: Janitor)
	ToPrivate(self).Destroyed = true
	self:Cleanup()
end

local function New(): Janitor
	return setmetatable({ Tasks = {}, Destroyed = false } :: any, Janitor)
end

return table.freeze({
	New = New,
})
