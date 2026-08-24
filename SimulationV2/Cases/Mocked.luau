--!strict
--!optimize 2

--[=[
	Mocked: One rule per promise the shipped mock makes.

	The mock in src is what a game tests against, so it has to behave like the real service. A mock
	that is more forgiving lets a game ship something that only fails once it is live.
	The budget is the subtle one, because a real server spends from two pools and the gauge shows one.

	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, and it runs the next time you press play.
--]=]

local Suite = require("../Suite")

local Mock = Suite.Insides.Mock

type Case = Suite.Case

local Cases = Suite.File("Mocked")

Cases.Case("the mock refuses a transform that yields", function(T: Case)
	local Store = Mock.New({ Throttled = false }):GetDataStore("Yielder")
	Store:SetAsync("count", { N = 0 })

	local Ok, Why = pcall(function()
		Store:UpdateAsync("count", function(Current: any): any
			task.wait()
			return { N = 1 }
		end)
	end)

	T:Is("a transform that waits", Ok, false)
	T:Is("it said the transform yielded", string.find(tostring(Why), "yielded", 1, true) ~= nil, true)
	T:Is("the key was left alone", (Store:GetAsync("count") :: any).N, 0)
end)

Cases.Case("the mock refuses a transform that touches the datastore", function(T: Case)
	local Store = Mock.New({ Throttled = false }):GetDataStore("Reentrant")
	Store:SetAsync("count", { N = 0 })

	local Ok, Why = pcall(function()
		Store:UpdateAsync("count", function(Current: any): any
			Store:SetAsync("count", { N = 99 })
			return { N = 1 }
		end)
	end)

	T:Is("a transform that writes the key itself", Ok, false)
	T:Is("it said the transform yielded", string.find(tostring(Why), "yielded", 1, true) ~= nil, true)
end)

Cases.Case("a mock transform still sees what is on the key", function(T: Case)
	local Store = Mock.New({ Throttled = false }):GetDataStore("Plain")
	Store:SetAsync("count", { N = 7 })

	local Seen: any = nil
	local Got = Store:UpdateAsync("count", function(Current: any): any
		Seen = Current
		return { N = (if type(Current) == "table" then Current.N else 0) + 1 }
	end)

	T:Is("what the transform was handed", if type(Seen) == "table" then Seen.N else nil, 7)
	T:Is("what it handed back", (Got :: any).N, 8)
	T:Is("what is on the key", (Store:GetAsync("count") :: any).N, 8)
end)

Cases.Case("the mock keeps the limits the real service keeps", function(T: Case)
	local Store = Mock.New({ Throttled = false }):GetDataStore("Caps")

	local Long = pcall(function()
		Store:SetAsync(string.rep("k", Mock.MAX_KEY + 1), 1)
	end)
	local Fat = pcall(function()
		Store:SetAsync("big", { Blob = string.rep("x", Mock.MAX_VALUE) })
	end)
	local Loop: any = {}
	Loop.Self = Loop
	local Odd = pcall(function()
		Store:SetAsync("bad", Loop)
	end)

	T:Is("a key past the length cap", Long, false)
	T:Is("a value past the size cap", Fat, false)
	T:Is("a value that cannot be encoded at all", Odd, false)
end)

Cases.Case("swapping the mock under a live store warns", function(T: Case)
	local Ledger = Suite.Insides.Ledger

	local Built = Ledger.New({
		Name = "CaseSwap",
		Keys = "Player",
		Default = { Gold = 0, Touches = 0 },
		Reducer = Suite.Reducers.Banker,
	})

	local Fine, Raised = pcall(function()
		Built:Edit(4019838803, "Fund", { Amount = 100 }):Wait()
		local Before = (Built:Peek(4019838803):Wait() :: any).Gold

		Ledger.UseMock()
		local After = (Built:Peek(4019838803):Wait() :: any).Gold

		T:Is("gold the store wrote", Before, 100)
		T:Is("gold once the mock was swapped under it", After, 0)
		T:Warns("it said what that cost", "nothing they wrote before this reads back")
	end)

	pcall(function()
		Built:Destroy()
	end)
	if not Fine then
		T:Fail("the swap", tostring(Raised))
	end
end)

Cases.Case("the mock runs out of experience budget while the gauge still shows room", function(T: Case)
	local Service = Mock.New({ Players = 30 })
	local Write = Enum.DataStoreRequestType.UpdateAsync
	local ServerCap = 60 + 30 * 40

	local Spent = 0
	for _ = 1, ServerCap do
		local Thread = coroutine.create(function()
			Service:Spend(Write)
		end)
		coroutine.resume(Thread)
		if coroutine.status(Thread) ~= "dead" then
			break
		end
		Spent += 1
	end

	T:Is("whether it blocked before the server budget ran out", Spent < ServerCap, true)
	T:Is("what the server gauge still reports once it blocks", Service:GetRequestBudgetForRequestType(Write) > 0, true)
end)

return Cases
