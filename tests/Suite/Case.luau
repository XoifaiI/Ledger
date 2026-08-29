--!strict
--!optimize 2

--[=[
	Case: One rule, its bench, and everything it is allowed to say.

	A case gets a world of its own: a fresh datastore, a clock that starts at the same second, and no
	faults until it asks for some. The datastore is the mock src ships and the clock is the scheduler
	src ships, so a case tests against the same two fakes a game would.
	The case body runs as a thread on that scheduler and the bench steps it. Nothing waits on a frame:
	the clock only moves when nothing is left to run, so a case that crosses a thirty day horizon costs
	what its work costs. Race is that same loop with more than one thread in it, which is why an
	interleaving replays.
	A store is built under a name of its own so two fixtures can share one disk, and then its wrappers
	are pointed at the shared name. Each store gets a hook of its own over the one service, so two
	stores on one datastore are two servers, and a fault aimed at one leaves the other working. A store
	name could not say that, because two servers share it.
	Closing takes down every store this server holds and not only the ones the bench built, because a
	store a case made by hand and could not take down again would sit in the shared sweep with its own
	budget and stop every later case reaping.
	Every check reads its own label, so a failure names the thing that was wrong.

	Return type: A table with Open, Close and Judge, and the names a bench builds under. The types are Case and Spec.
	Example usage:
		local Bank = T:Bank()
		T:Is("gold after the transfer", Bank:Amount("a"), 50)
--]=]

local Fixture = require("./Fixture")
local Reducers = require("./Reducers")

local Ledger = require("../../src") :: any
local Sizes = require("../../src/Core/Constants/Sizes")
local Warnings = require("../../src/Util/Warnings")
local Clock = require("../../src/Util/Clock")
local Ident = require("../../src/Encode/Ident")
local Wrapper = require("../../src/Util/DataStoreWrapper")
local Memory = require("../../src/Hooks/Memory")
local Registry = require("../../src/Store/Registry")
local Virtual = require("../../src/Schedulers/Virtual")
local Mock = require("../../src/Mock")

type Entry = Warnings.Entry

export type Spec = {
	Keys: string?,
	Default: any?,
	Reducer: any?,
	Balance: string?,
	Field: string?,
	Migrations: { any }?,
	OnLoadFailed: any?,
	Data: string?,
	Node: string?,
}

type CaseImpl = {
	__index: CaseImpl,

	Open: (Name: string) -> Case,
	Close: (self: Case) -> (),
	Judge: (self: Case) -> { string },
	Drive: (self: Case, Body: (Case) -> ()) -> string?,

	Store: (self: Case, Held: Spec) -> Fixture.Fixture,
	Bank: (self: Case, Node: string?) -> Fixture.Fixture,
	Market: (self: Case, Node: string?) -> Fixture.Fixture,
	Vault: (self: Case, Node: string?) -> Fixture.Fixture,
	Shelf: (self: Case, Node: string?) -> Fixture.Fixture,
	Players: (self: Case, Node: string?) -> Fixture.Fixture,
	Player: (self: Case, UserId: number) -> any,

	Is: (self: Case, Label: string, Got: any, Want: any) -> (),
	Ok: (self: Case, Label: string, Got: any) -> (),
	No: (self: Case, Label: string, Got: any) -> (),
	Near: (self: Case, Label: string, Got: number, Want: number, Slack: number) -> (),
	Throws: (self: Case, Label: string, Body: () -> ()) -> string?,
	Holds: (self: Case, Label: string, Body: () -> ()) -> (),
	Warns: (self: Case, Label: string, Fragment: string, Count: number?) -> (),
	AtMost: (self: Case, Label: string, Fragment: string, Most: number) -> (),
	Silent: (self: Case, Label: string, Fragment: string) -> (),
	Accuses: (self: Case, Label: string, Fragment: string) -> (),
	Said: (self: Case) -> { string },
	Fail: (self: Case, Label: string, Says: string) -> (),

	Race: (self: Case, Bodies: { () -> () }) -> (),
	Spawn: (self: Case, Body: () -> ()) -> thread,
	Wait: (self: Case, Seconds: number?) -> (),
	Until: (self: Case, Done: () -> boolean) -> boolean,
	Advance: (self: Case, Seconds: number) -> (),
	Now: (self: Case) -> number,
	Sweep: (self: Case) -> (),
}

export type Wanted = {
	Kind: string,
	Label: string,
	Fragment: string,
	Count: number?,
}

export type Case = setmetatable<{
	Name: string,
	Turn: Virtual.Virtual,
	Broken: { string },
	Service: Mock.Service,
	Hook: Memory.Memory,
	Built: { Fixture.Fixture },
	Records: { Entry },
	Expect: { Wanted },
}, CaseImpl>

local DATA = "Case"
local VAULT = "CaseVault"
local NODE = "node1"
local SIM_NODE = "v2case00000000"

local ACCUSED = "this is a bug in Ledger"

local STEP_CAP = 1000000
local EPOCH = 1700000000

local Case = {} :: CaseImpl
Case.__index = Case

Registry.Sweep():Stop()

local Claimed = 0

local function Quicken(Wrapper: any)
	Wrapper.Attempts = 3
	Wrapper.Constant = 0
	Wrapper.Exponent = 0
	Wrapper.Jitter = 0
end

local function Counted(Records: { Entry }, Fragment: string): number
	local Count = 0
	for _, Held in Records do
		if string.find(Held.Says, Fragment, 1, true) ~= nil then
			Count += Held.Count
		end
	end
	return Count
end

function Case.Open(Name: string): Case
	Warnings.Reset()
	Ident.Restart(SIM_NODE)

	local Walker = Registry.Sweep()
	Walker:Stop()
	Walker.Passes = 0
	Walker.Resume = 1

	local Turn = Virtual.New(EPOCH)
	local Service = Mock.New({ Throttled = false }, Turn)
	Clock.Use(Turn)

	return setmetatable({
		Name = Name,
		Turn = Turn,
		Broken = {},
		Service = Service,
		Hook = Memory.New(Turn, nil, Service),
		Built = {},
		Records = Warnings.Records(),
		Expect = {},
	}, Case) :: any
end

local function Pump(self: Case, Thread: thread): boolean
	local Steps = 0
	while coroutine.status(Thread) ~= "dead" do
		Steps += 1
		if Steps > STEP_CAP or not self.Turn.Step() then
			return false
		end
	end
	return true
end

function Case.Close(self: Case)
	Sizes.Reset()

	local Thread = self.Turn.Defer(function()
		for _, Held in self.Built do
			Held:Healed()
		end
		for _, Held in self.Built do
			pcall(function()
				Held.Store:Destroy()
			end)
		end

		local Stores = Registry.Stores
		for Index = #Stores, 1, -1 do
			local Held = Stores[Index]
			pcall(function()
				Held:Destroy()
			end)
		end
	end)

	if not Pump(self, Thread) then
		table.insert(self.Broken, "the bench could not be taken down, something it was saving never finished")
	end

	Registry.Sweep():Stop()
	Clock.Use(nil)
end

function Case.Drive(self: Case, Body: (Case) -> ()): string?
	local Raised: string? = nil
	local Thread = self.Turn.Defer(function()
		local Fine, Held = pcall(Body, self)
		if not Fine then
			Raised = tostring(Held)
		end
	end)

	if not Pump(self, Thread) then
		table.insert(self.Broken, "the case never finished, it is waiting on something nothing will do")
	end
	for _, Line in self.Turn.Failures() do
		table.insert(self.Broken, `a thread died: {Line}`)
	end
	return Raised
end

function Case.Store(self: Case, Held: Spec): Fixture.Fixture
	Claimed += 1
	local Data = Held.Data or DATA
	local Marked = `{Data}_Tx`
	local Node = Held.Node or NODE

	local Turn = self.Turn
	local Hook = Memory.New(Turn, nil, self.Service)
	local Built = Ledger.New({
		Name = `V2case{Claimed}`,
		Scheduler = Turn,
		Hook = Hook,
		Keys = Held.Keys or "String",
		Default = Held.Default or Reducers.MONEY,
		Balance = Held.Balance,
		Reducer = Held.Reducer or Reducers.Banker,
		Migrations = Held.Migrations,
		OnLoadFailed = Held.OnLoadFailed,
	})

	Built.Wrapper = Wrapper.New(Data, Turn, Hook)
	Built.TxWrapper = Wrapper.New(Marked, Turn, Hook)
	Built.Books, Built.Shaped = nil, nil
	Built.Node = Node
	Quicken(Built.Wrapper)
	Quicken(Built.TxWrapper)

	Built.Wrapper.Store = Hook.Open(Data)
	Built.TxWrapper.Store = Hook.Open(Marked)

	local Made = Fixture.New(Built, Hook, self.Service, Data, Marked, Node, Held.Field or Held.Balance)

	table.insert(self.Built, Made)
	return Made
end

function Case.Bank(self: Case, Node: string?): Fixture.Fixture
	return self:Store({ Default = Reducers.MONEY, Reducer = Reducers.Banker, Balance = "Gold", Node = Node })
end

function Case.Market(self: Case, Node: string?): Fixture.Fixture
	return self:Store({ Default = Reducers.WARES, Reducer = Reducers.Trader, Node = Node })
end

function Case.Vault(self: Case, Node: string?): Fixture.Fixture
	return self:Store({ Default = Reducers.COINS, Reducer = Reducers.Vaulter, Data = VAULT, Node = Node, Field = "Coins" })
end

function Case.Shelf(self: Case, Node: string?): Fixture.Fixture
	return self:Store({ Default = Reducers.SHELF, Reducer = Reducers.Shopkeeper, Node = Node, Field = "Stock" })
end

function Case.Players(self: Case, Node: string?): Fixture.Fixture
	return self:Store({ Keys = "Player", Default = Reducers.PLAIN, Reducer = Reducers.Keep, Node = Node })
end

function Case.Player(self: Case, UserId: number): any
	local Fake: any = { UserId = UserId, Name = `player{UserId}`, Parent = workspace, Kicked = 0 }
	Fake.Kick = function(Held: any)
		Held.Kicked += 1
	end
	return Fake
end

function Case.Is(self: Case, Label: string, Got: any, Want: any)
	if Got == Want then
		return
	end
	table.insert(self.Broken, `{Label}: got {tostring(Got)}, wanted {tostring(Want)}`)
end

function Case.Ok(self: Case, Label: string, Got: any)
	self:Is(Label, Got, true)
end

function Case.No(self: Case, Label: string, Got: any)
	self:Is(Label, Got, false)
end

function Case.Near(self: Case, Label: string, Got: number, Want: number, Slack: number)
	if type(Got) == "number" and math.abs(Got - Want) <= Slack then
		return
	end
	table.insert(self.Broken, `{Label}: got {tostring(Got)}, wanted {Want} give or take {Slack}`)
end

function Case.Throws(self: Case, Label: string, Body: () -> ()): string?
	local Fine, Raised = pcall(Body)
	if Fine then
		table.insert(self.Broken, `{Label}: it went through, and it had to throw`)
		return nil
	end
	return tostring(Raised)
end

function Case.Holds(self: Case, Label: string, Body: () -> ())
	local Fine, Raised = pcall(Body)
	if Fine then
		return
	end
	table.insert(self.Broken, `{Label}: it threw, and it had to go through: {tostring(Raised)}`)
end

function Case.Warns(self: Case, Label: string, Fragment: string, Count: number?)
	table.insert(self.Expect, { Kind = "Warns", Label = Label, Fragment = Fragment, Count = Count })
end

function Case.AtMost(self: Case, Label: string, Fragment: string, Most: number)
	table.insert(self.Expect, { Kind = "AtMost", Label = Label, Fragment = Fragment, Count = Most })
end

function Case.Silent(self: Case, Label: string, Fragment: string)
	table.insert(self.Expect, { Kind = "Silent", Label = Label, Fragment = Fragment })
end

function Case.Accuses(self: Case, Label: string, Fragment: string)
	table.insert(self.Expect, { Kind = "Accuses", Label = Label, Fragment = Fragment })
end

function Case.Judge(self: Case): { string }
	local Wanted: { string } = {}
	for _, Held in self.Expect do
		local Seen = Counted(self.Records, Held.Fragment)

		if Held.Kind == "Silent" then
			if Seen > 0 then
				table.insert(self.Broken, `{Held.Label}: '{Held.Fragment}' was warned about {Seen} time(s) and should not have been`)
			end
			continue
		end

		if Held.Kind == "AtMost" then
			if Seen == 0 then
				table.insert(self.Broken, `{Held.Label}: nothing warned about '{Held.Fragment}'`)
			elseif Seen > (Held.Count :: number) then
				table.insert(self.Broken, `{Held.Label}: '{Held.Fragment}' was warned about {Seen} time(s), more than the {Held.Count} allowed`)
			end
			continue
		end

		if Held.Kind == "Accuses" then
			table.insert(Wanted, Held.Fragment)
		end
		if Held.Count ~= nil then
			self:Is(Held.Label, Seen, Held.Count)
		elseif Seen == 0 then
			table.insert(self.Broken, `{Held.Label}: nothing warned about '{Held.Fragment}'`)
		end
	end

	local Loose: { string } = {}
	for _, Held in self.Records do
		local Line = Held.Says
		if string.find(Line, ACCUSED, 1, true) == nil then
			continue
		end

		local Asked = false
		for _, Fragment in Wanted do
			if string.find(Line, Fragment, 1, true) ~= nil then
				Asked = true
				break
			end
		end
		if not Asked then
			table.insert(Loose, Line)
		end
	end
	return Loose
end

function Case.Said(self: Case): { string }
	local Lines: { string } = {}
	for _, Held in self.Records do
		table.insert(Lines, Held.Says)
	end
	return Lines
end

function Case.Fail(self: Case, Label: string, Says: string)
	table.insert(self.Broken, `{Label}: {Says}`)
end

function Case.Race(self: Case, Bodies: { () -> () })
	local Threads: { thread } = {}
	for _, Body in Bodies do
		table.insert(
			Threads,
			self.Turn.Defer(function()
				local Fine, Raised = pcall(Body)
				if not Fine then
					self:Fail("a raced thread", tostring(Raised))
				end
			end)
		)
	end

	local Steps = 0
	while true do
		local Running = false
		for _, Thread in Threads do
			if coroutine.status(Thread) ~= "dead" then
				Running = true
				break
			end
		end
		if not Running then
			return
		end

		Steps += 1
		if Steps > STEP_CAP or not self.Turn.Step() then
			self:Fail("the race", "it gave up with a thread still running")
			return
		end
	end
end

function Case.Spawn(self: Case, Body: () -> ()): thread
	return self.Turn.Spawn(function()
		local Fine, Raised = pcall(Body)
		if not Fine then
			self:Fail("a spawned thread", tostring(Raised))
		end
	end)
end

function Case.Wait(self: Case, Seconds: number?)
	self.Turn.Wait(Seconds or 0)
end

function Case.Until(self: Case, Done: () -> boolean): boolean
	local Steps = 0
	while not Done() do
		Steps += 1
		if Steps > STEP_CAP or not self.Turn.Step() then
			return Done()
		end
	end
	return true
end

function Case.Advance(self: Case, Seconds: number)
	self.Turn.Advance(Seconds)
end

function Case.Now(self: Case): number
	return self.Turn.Now()
end

function Case.Sweep(self: Case)
	Registry.Sweep():Pass()
end

table.freeze(Case)

return table.freeze({
	Open = Case.Open,
	Close = Case.Close,
	Drive = Case.Drive,
	Judge = Case.Judge,

	DATA = DATA,
	VAULT = VAULT,
	ACCUSED = ACCUSED,
})
