--!strict
--!optimize 2

--[=[

	Observer: Plumbing. Sends each value pushed to every listener, in the order they subscribed.

	A listener must not yield. One that yields is stopped, and one that throws is warned about.

	Count gives how many listeners are connected.

	Return type: The Observer class, with New and the methods Subscribe, Push, Count and Destroy. The
	types are Observer and Connection.
	Example usage:
		Stream:Subscribe(print)
--]=]

type ConnectionImpl = {
	__index: ConnectionImpl,
	Disconnect: (self: Connection) -> (),
}

type ConnectionData = {
	Connected: boolean,
	read Listener: (any) -> (),
	read Nodes: { Connection },
}

export type Connection = setmetatable<ConnectionData, ConnectionImpl>

type ObserverImpl<T> = {
	__index: ObserverImpl<T>,
	New: () -> Observer<T>,
	Subscribe: (self: Observer<T>, Listener: (T) -> ()) -> Connection,
	Push: (self: Observer<T>, Value: T) -> (),
	Count: (self: Observer<T>) -> number,
	Destroy: (self: Observer<T>) -> (),
}

type Data = {
	read Nodes: { Connection },
}

export type Observer<T> = setmetatable<Data, ObserverImpl<T>>

local Connection = {} :: ConnectionImpl
Connection.__index = Connection

local Observer = {} :: ObserverImpl<any>
Observer.__index = Observer

function Connection.Disconnect(self: Connection)
	if not self.Connected then
		return
	end
	self.Connected = false
	local Nodes = self.Nodes
	local At = table.find(Nodes, self)
	if At then
		table.remove(Nodes, At)
	end
end

local function Run(Listener: (any) -> (), Value: any)
	local Thread = coroutine.create(Listener)
	local Ok, Err = coroutine.resume(Thread, Value)
	if not Ok then
		warn(`Ledger: an Observer listener threw: {Err}`)
	elseif coroutine.status(Thread) ~= "dead" then
		coroutine.close(Thread)
		warn("Ledger: an Observer listener yielded and was stopped. a listener runs the moment a value is pushed")
	end
end

function Observer.New<T>(): Observer<T>
	local Fresh: Data = { Nodes = {} }
	return setmetatable(Fresh, Observer)
end

function Observer.Subscribe<T>(self: Observer<T>, Listener: (T) -> ()): Connection
	local Fresh: ConnectionData = { Connected = true, Listener = Listener, Nodes = self.Nodes }
	local Made = setmetatable(Fresh, Connection)
	table.insert(self.Nodes, Made)
	return Made
end

function Observer.Push<T>(self: Observer<T>, Value: T)
	for _, Node in table.clone(self.Nodes) do
		if Node.Connected then
			Run(Node.Listener, Value)
		end
	end
end

function Observer.Count<T>(self: Observer<T>): number
	return #self.Nodes
end

function Observer.Destroy<T>(self: Observer<T>)
	for _, Node in self.Nodes do
		Node.Connected = false
	end
	table.clear(self.Nodes)
end

return Observer
