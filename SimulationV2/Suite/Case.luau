--!strict
--!optimize 2

--[=[
	Case: One rule, its bench, and everything it is allowed to say.

	A case gets a world of its own: a fresh disk, a clock that starts at the same second, and no
	faults until it asks for some. Nothing waits on a frame, because the disk gives its turn to a
	driver that hands it straight back. Race and Slow are how a case asks for real turns instead.
	Every check reads its own label, so a failure names the thing that was wrong.

	Return type: A table with Open, Close and Judge, and the names a bench builds under. The types are Case and Spec.
	Example usage:
		local Bank = T:Bank()
		T:Is("gold after the transfer", Bank:Amount("a"), 50)
--]=]

local Board = require("../Board")
local Disk = require("../Disk")
local Lib = require("../Lib")
local Scheduler = require("../Scheduler")
local Time = require("../Time")
local Fault = require("./Fault")
local Fixture = require("./Fixture")
local Reducers = require("./Reducers")

local Ledger = Lib.Ledger
local Limits = require("../../src/Contract/Limits")
local Say = require("../../src/Util/Tools/Say")

type Spec0 = Fault.Spec
type Entry = Say.Entry

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

	Open: (Name: string, Seed: number) -> Case,
	Close: (self: Case) -> (),
	Judge: (self: Case) -> { string },

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
	Settle: (self: Case) -> (),
	Slow: (self: Case) -> (),
	Advance: (self: Case, Seconds: number) -> (),
	Now: (self: Case) -> number,
	Sweep: (self: Case) -> (),
	Conflicts: (self: Case) -> number,
}

export type Wanted = {
	Kind: string,
	Label: string,
	Fragment: string,
	Count: number?,
}

export type Case = setmetatable<{
	Name: string,
	Seed: number,
	Rng: Random,
	Broken: { string },
	Plate: Disk.Disk,
	Faulty: Board.Board,
	Built: { Fixture.Fixture },
	Records: { Entry },
	Expect: { Wanted },
	Free: any,
}, CaseImpl>

local DATA = "Case"
local VAULT = "CaseVault"
local NODE = "node1"
local SIM_NODE = "v2case00000000"

local ACCUSED = "this is a bug in Ledger"

local Case = {} :: CaseImpl
Case.__index = Case

local Free: any = table.freeze({
	Wait = function() end,
})

local Walker = Lib.Sweep()
Walker:Stop()

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

function Case.Open(Name: string, Seed: number): Case
	Say.Reset()
	Time.Restart()
	Ledger.UseClock(Time.Read, Time.Sleep)
	Lib.Ident.Restart(SIM_NODE)

	Walker:Stop()
	Walker.Passes = 0
	Walker.Resume = 1

	local Plate = Disk.New()
	Plate.Throttled = false
	Plate.Turn = Free
	Time.Bind(Free)

	local Faulty = Board.New(Random.new(Seed))
	Board.Heal(Faulty)
	Board.Install(Faulty, Lib.Wrapper, Plate)

	return setmetatable({
		Name = Name,
		Seed = Seed,
		Rng = Random.new(Seed),
		Broken = {},
		Plate = Plate,
		Faulty = Faulty,
		Built = {},
		Records = Say.Records(),
		Expect = {},
		Free = Free,
	}, Case) :: any
end

function Case.Close(self: Case)
	Limits.Reset()

	for _, Held in self.Built do
		Held:Healed()
	end
	for _, Held in self.Built do
		pcall(function()
			Held.Store:Destroy()
		end)
	end

	Walker:Stop()
	self.Plate.Turn = nil
	Time.Bind(nil)
	Lib.Wrapper.Use(nil, nil)
	Ledger.UseReal()
	Ledger.UseClock(nil, nil)
	task.wait()
end

function Case.Store(self: Case, Held: Spec): Fixture.Fixture
	Claimed += 1
	local Data = Held.Data or DATA
	local Marked = `{Data}_Tx`
	local Node = Held.Node or NODE

	local Built = Ledger.New({
		Name = `V2case{Claimed}`,
		Keys = Held.Keys or "String",
		Default = Held.Default or Reducers.MONEY,
		Balance = Held.Balance,
		Reducer = Held.Reducer or Reducers.Banker,
		Migrations = Held.Migrations,
		OnLoadFailed = Held.OnLoadFailed,
	})

	Built.Wrapper = Lib.Wrapper.New(Data)
	Built.TxWrapper = Lib.Wrapper.New(Marked)
	Built.Books, Built.Shaped = nil, nil
	Quicken(Built.Wrapper)
	Quicken(Built.TxWrapper)

	local Made = Fixture.New(Built, self.Plate, Data, Marked, Node, Held.Field or Held.Balance)
	Built.Wrapper.Store = Fault.Wrap(Board.Wrap(self.Faulty, Disk.Open(self.Plate, Data), Node), Made.Faults)
	Built.TxWrapper.Store = Fault.Wrap(Board.Wrap(self.Faulty, Disk.Open(self.Plate, Marked), Node), Made.MarkerFaults)

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
	local Turn = Scheduler.New(self.Seed)
	self.Plate.Turn = Turn
	Time.Bind(Turn)

	for _, Body in Bodies do
		Turn:Spawn(Body)
	end
	Turn:Run()

	self.Plate.Turn = self.Free
	Time.Bind(self.Free)
	if Turn.GaveUp then
		self:Fail("the race", "it gave up with threads still running")
	end
end

function Case.Slow(self: Case)
	self.Plate.Turn = nil
	Time.Bind(nil)
	self.Free = nil
end

function Case.Settle(self: Case)
	self.Plate.Turn = nil
	Time.Bind(nil)
	task.wait()
	self.Plate.Turn = self.Free
	Time.Bind(self.Free)
end

function Case.Advance(self: Case, Seconds: number)
	Time.Advance(Seconds)
end

function Case.Now(self: Case): number
	return Time.Read()
end

function Case.Sweep(self: Case)
	Walker:Pass()
end

function Case.Conflicts(self: Case): number
	return self.Plate.Conflicts
end

table.freeze(Case)

return table.freeze({
	Open = Case.Open,
	Close = Case.Close,
	Judge = Case.Judge,

	DATA = DATA,
	VAULT = VAULT,
	ACCUSED = ACCUSED,
})
