--!strict
--!optimize 2

--[=[

	Observer: Plumbing. Sends each value pushed to every listener, in the order they subscribed.

	A listener must not yield. One that yields is stopped, and one that throws is warned about.

	Return type: The Observer class, with New and the methods Subscribe, Push and Destroy.
	Example usage:
		Stream:Subscribe(print)
--]=]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Observer<T> = {
	Subscribe: (self: Observer<T>, Listener: (T) -> ()) -> Connection,
	Push: (self: Observer<T>, Value: T) -> (),
	Destroy: (self: Observer<T>) -> (),
}

type Node = {
	Connected: boolean,
	Disconnect: (self: any) -> (),
	Listener: (any) -> (),
	Owner: Private,
}

type Private = {
	Nodes: { Node },
}

local Observer = {}
Observer.__index = Observer

local function Disconnect(self: Node)
	if not self.Connected then
		return
	end
	self.Connected = false
	local Nodes = self.Owner.Nodes
	table.remove(Nodes, table.find(Nodes, self) :: number)
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

function Observer.New(): Observer<any>
	local Body: Private = { Nodes = {} }
	return setmetatable(Body :: any, Observer) :: any
end

function Observer.Subscribe(self: Private, Listener: (any) -> ()): Connection
	local Node: Node = { Connected = true, Disconnect = Disconnect, Listener = Listener, Owner = self }
	table.insert(self.Nodes, Node)
	return Node :: any -- TODO: Make stricter
end

function Observer.Push(self: Private, Value: any)
	for _, Node in table.clone(self.Nodes) do
		if Node.Connected then
			Run(Node.Listener, Value)
		end
	end
end

function Observer.Destroy(self: Private)
	for _, Node in self.Nodes do
		Node.Connected = false
	end
	table.clear(self.Nodes)
end

return Observer
