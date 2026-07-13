--!strict
--!optimize 2

--[=[
    Deconstructor: bundles cleanables into a single cleanup function, the one liner for observer teardowns.

    takes the same things a janitor does (connections, threads, instances, functions, tables with
    a Destroy or Disconnect) and hands back one function that cleans them all, so a source can
    just return Deconstructor(Connection, Thread) instead of writing the closure out. values are
    captured when Deconstructor is called: for a resource that only exists later (a connection
    made after a yield), add it to a Janitor and hand the janitor to Deconstructor instead.

    Return type: the Deconstructor function
    Example usage:
        local Deconstructor = require("./Deconstructor")
        return Deconstructor(Connection, Wiring)
--]=]

local Janitor = require("./Janitor")

type Cleanable = Janitor.Cleanable

local function Deconstructor(...: Cleanable?): () -> ()
	local Bin = Janitor.New()

	for Index = 1, select("#", ...) do
		local Item = (select(Index, ...))
		if Item ~= nil then
			Bin:Add(Item)
		end
	end

	return function()
		Bin:Destroy()
	end
end

return Deconstructor
