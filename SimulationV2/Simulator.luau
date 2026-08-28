--!strict
--!optimize 2

--[=[
	Simulator: One seeded run.

	A fleet, and not a set of workers. Every server is its own store with its own loaded map and
	session cache, and they all point at one datastore name. A server can stop where it stands and
	be rebuilt from the log alone.
	Safety runs with the faults on. Liveness then heals everything and asks whether it settles on its
	own. The seeded scheduler drives both, so a seed replays.

	Return type: A table with Run, Banker and DEFAULT. The types are Report and Options.
	Example usage:
		local Out = Simulator.Run(288, { Trace = true })
--]=]

local Auditor = require("./Auditor")
local Board = require("./Board")
local Catalogue = require("./Catalogue")
local Coverage = require("./Coverage")
local Disk = require("./Disk")
local Invariants = require("./Invariants")
local Limits = require("../src/Contract/Limits")

local Lib = require("./Lib")
local Say = require("../src/Util/Tools/Say")
local Liveness = require("./Liveness")
local Model = require("./Model")
local Scheduler = require("./Scheduler")
local Swarm = require("./Swarm")
local Time = require("./Time")
local Workload = require("./Workload")

local Ledger = Lib.Ledger

export type Report = {
	Seed: number,
	Rounds: number,
	Issued: number,
	Threw: { string },
	Broken: { string },
	Missed: { string },
	Silent: { string },
	Cover: Coverage.Cover,
	Books: Auditor.Auditor,
	Calls: number,
	Injected: number,
	Lost: number,
	Moved: { string },
	Journal: { string },
	Crashes: number,
	Steps: number,
	Seconds: number,
	Warnings: number,
	Said: { Say.Entry },
}

local ROUNDS_LEAST = 120
local ROUNDS_MOST = 400
local SERVERS_LEAST = 2
local SERVERS_MOST = 5
local KEYS_LEAST = 3
local KEYS_MOST = 12
local FUNDS = 5000

local SAFETY_EVERY = 0.25

local TRACE_KEEP = 60

local APART: { [string]: boolean } = {
	Destroy = true,
	CloseAll = true,
	Erase = true,
	Reset = true,
	Confirm = true,
}

local SIM_LIMITS = table.freeze({
	Value = 64 * 1024,
	State = 32 * 1024,
	Op = 16 * 1024,
	Log = 24 * 1024,
	Compact = 16 * 1024,
})

local DEFAULT: any = { Gold = 0, Touches = 0, Blobs = {} }

local function Banker(State: any, Op: any): any?
	if Op.Kind == "Fund" then
		return { Gold = State.Gold + Op.Amount, Touches = State.Touches, Blobs = State.Blobs }
	elseif Op.Kind == "Touch" then
		return { Gold = State.Gold, Touches = State.Touches + 1, Blobs = State.Blobs }
	elseif Op.Kind == "Give" then
		local Gold = State.Gold + Op.Amount
		if Gold < 0 then
			return nil
		end
		return { Gold = Gold, Touches = State.Touches, Blobs = State.Blobs }
	elseif Op.Kind == "Stash" then
		if type(Op.Blob) ~= "string" or type(Op.Slot) ~= "string" then
			return nil
		end
		local Blobs = table.clone(State.Blobs)
		Blobs[Op.Slot] = Op.Blob
		return { Gold = State.Gold, Touches = State.Touches, Blobs = Blobs }
	end
	return nil
end

local NODE = "v2simulation00"

Lib.Ident.Restart(NODE)

local Walker = Lib.Sweep()
Walker:Stop()

local Claimed = 0

local function Quicken(Wrapper: any)
	Wrapper.Attempts = 3
	Wrapper.Constant = 0
	Wrapper.Exponent = 0
	Wrapper.Jitter = 0
end

local function Build(Keys: string, Data: string, Marked: string, Steps: { any }?, Held: any?, Named: string?): any
	Claimed += 1
	local Built = Ledger.New({
		Name = `V2s{Claimed}`,
		Keys = Keys,
		Default = DEFAULT,
		Balance = "Gold",
		Reducer = Banker,
		Migrations = Steps,
	})

	Built.Wrapper = Lib.Wrapper.New(Data)
	Built.TxWrapper = Lib.Wrapper.New(Marked)
	Built.Books, Built.Shaped = nil, nil
	Quicken(Built.Wrapper)
	Quicken(Built.TxWrapper)

	if Held ~= nil then
		Built.Wrapper.Store = Board.Wrap(Held.Board, Disk.Open(Held.Disk, Data), Named)
		Built.TxWrapper.Store = Board.Wrap(Held.Board, Disk.Open(Held.Disk, Marked), Named)
	end
	return Built
end

local function Crash(Store: any)
	for UserId, Entry in Store.Loaded do
		Store.Loaded[UserId] = nil
		task.cancel(Entry.Ticker)
	end
	table.clear(Store.Loads)

	for UserId in Store.Waiters do
		Store:Wake(UserId, nil)
	end

	Lib.Sweep():Forget(Store)
	for Index, Known in Lib.Stores do
		if Known == Store then
			table.remove(Lib.Stores, Index)
			break
		end
	end
	Store.Closed = true
end

local function Opener(Store: any, Keys: string): (Key: any) -> any?
	if Keys == "Player" then
		return function(Key: any): any?
			local Held = Workload.Player(Key)
			Store:Load(Held)
			return Store:Get(Held)
		end
	end

	return function(Key: any): any?
		return (Lib.OpenSession(Store:Records(), Store:Format(), tostring(Key), Store.TxWrapper):Wait())
	end
end

local function Pool(Keys: string, Count: number, Seed: number): { any }
	local Held: { any } = table.create(Count) :: { any }
	for Index = 1, Count do
		Held[Index] = if Keys == "Player" then (Seed % 9000 + 1) * 100 + Index else `k{Seed}x{Index}`
	end
	return Held
end

local function Weighted(Rng: Random, Keys: string): Swarm.Weighted
	local Held: { Catalogue.Operation } = {}
	for _, Operation in Catalogue.Applicable(Keys :: any, true) do
		if not APART[Operation.Name] then
			table.insert(Held, Operation)
		end
	end
	return Catalogue.Weights(Rng, Held)
end

local FAT_SHARE = 4
local FAT_ROUNDS = 12

local CROWD_STEPS = 4096

local CRASH_CHANCE = 0.01

local MAX_SEED = 2 ^ 31 - 1

local function Fatten(Open: (Key: any) -> any?, Key: any, Cover: Coverage.Cover)
	local Active = Open(Key)
	if Active == nil then
		return
	end

	local Blob = string.rep("f", Limits.Op // FAT_SHARE)
	for Slot = 1, FAT_ROUNDS do
		local Ok, Why = Active:Apply("Stash", { Slot = `g{Slot}`, Blob = Blob })
		Cover:Note("Apply", Ok, Why)

		local Fine, Reason = Active:Commit("Stash", { Slot = `h{Slot}`, Blob = Blob }):Wait()
		Cover:Note("Commit", Fine, Reason)

		if Why ~= nil and Reason ~= nil then
			break
		end
	end

	Active.Released = true
end

local function Aged(Older: any, Keys: string, Data: string, Marked: string, Key: any, Rng: Random, Cover: Coverage.Cover, Threw: { string })
	local Newer = Build(Keys, Data, Marked, {
		function(State: any): any
			return State
		end,
	})

	local Stamped = pcall(function()
		Newer:Edit(Key, "Touch", {}):Wait()
		if Keys == "String" then
			Newer:Bump("tally1", "Gold", 1):Wait()
		end
	end)
	if not Stamped then
		table.insert(Threw, "the newer build could not stamp a floor, so nothing can be Behind")
	end

	local World = Workload.New(Older, { Key }, Rng, Keys, Opener(Older, Keys), function() end, function() end)
	table.insert(World.Bookings, { Key = Key, Rid = "aged", Handed = false, Amount = 0, Tried = false, To = nil, Moved = false })
	table.insert(World.Names, { Once = "aged", Key = Key })
	table.insert(World.Txids, "aged")
	table.insert(World.Transfers, { From = Key, To = Key, Tid = "aged" })
	table.insert(World.Versions, { Key = Key, Version = "1" })

	for _, Operation in Catalogue.Applicable(Keys :: any, true) do
		if Operation.Name == "Destroy" or Operation.Name == "CloseAll" then
			continue
		end
		local Ran, Answer = Workload.Issue(World, Operation.Name)
		if not Ran then
			Cover:Threw(Operation.Name)
			table.insert(Threw, `{Operation.Name} threw against a newer record: {Answer :: string}`)
			continue
		end
		local Outcome = Answer :: Workload.Outcome
		Cover:Note(Operation.Name, Outcome.Ok, Outcome.Why)
	end

	pcall(function()
		Newer:Destroy()
	end)
	return Newer
end

local function Crowd(Store: any, Keys: string, Key: any, Rng: Random, Cover: Coverage.Cover, CloseAll: () -> (), Plate: Disk.Disk, Seed: number): number
	local World = Workload.New(Store, { Key }, Rng, Keys, Opener(Store, Keys), function() end, function() end)
	table.insert(World.Bookings, { Key = Key, Rid = "crowd", Handed = false, Amount = 0, Tried = false, To = nil, Moved = false })
	table.insert(World.Names, { Once = "crowd", Key = Key })
	table.insert(World.Versions, { Key = Key, Version = "1" })

	local Wanted: { string } = {}
	for _, Operation in Catalogue.Applicable(Keys :: any, true) do
		local Named = Operation.Name
		if Named == "Destroy" or Named == "CloseAll" or Named == "Load" or Named == "Unload" then
			continue
		end
		table.insert(Wanted, Named)
	end

	local Turn = Scheduler.New(Seed)
	local Was = Plate.Turn
	Plate.Turn = Turn
	Time.Bind(Turn)

	for _, Named in Wanted do
		Turn:Spawn(function()
			local Ran, Answer = Workload.Issue(World, Named)
			if Ran then
				local Outcome = Answer :: Workload.Outcome
				Cover:Note(Named, Outcome.Ok, Outcome.Why)
			end
		end)
	end

	Turn:Spawn(function()
		pcall(CloseAll)
	end)

	local Took = Turn:Drain(CROWD_STEPS)

	Plate.Turn = Was
	Time.Bind(Was)
	return Took
end

local function Rebuilt(Raw: any): any
	if type(Raw) ~= "table" then
		return { Ops = {}, Seen = {} }
	end

	return {
		Snapshot = if type(Raw.Snapshot) == "table" then Raw.Snapshot else nil,
		Ops = if type(Raw.Ops) == "table" then Raw.Ops else {},
		Seen = if type(Raw.Seen) == "table" then Raw.Seen else {},
		Version = if type(Raw.Version) == "number" then Raw.Version else nil,
		Floor = if type(Raw.Floor) == "number" then Raw.Floor else nil,
	}
end

local function Each(Plate: any, Where: Invariants.Where, Format: any): { [string]: number }
	local Held: { [string]: number } = {}
	for Key, Name in Where do
		local State: any = Format:Fold(Rebuilt(Disk.Peek(Plate, Name, Key)))
		local Balance = if type(State.Gold) == "number" then State.Gold else 0
		local Escrow, Booked = 0, 0
		for _, Entry in if type(State._Held) == "table" then State._Held else {} do
			if type(Entry) == "table" and type(Entry.Amount) == "number" then
				Escrow += Entry.Amount
			end
		end
		for _, Entry in if type(State._Booked) == "table" then State._Booked else {} do
			if type(Entry) == "table" and type(Entry.Amount) == "number" then
				Booked += Entry.Amount
			end
		end
		Held[tostring(Key)] = Balance + Escrow + Booked
	end
	return Held
end

local function Moved(Before: { [string]: number }, After: { [string]: number }): string
	local Parts: { string } = {}
	for Key, Now in After do
		local Was = Before[Key] or 0
		if Now ~= Was then
			table.insert(Parts, `{Key} {if Now > Was then "+" else ""}{Now - Was}`)
		end
	end
	table.sort(Parts)
	return if #Parts == 0 then "nothing moved" else table.concat(Parts, ", ")
end

local function Judge(Books: Auditor.Auditor, Broken: { string }, Named: string, Outcome: Workload.Outcome, Facts: Auditor.Facts)
	local Verdict = Books:Observe(Named, Facts, Outcome.Ok, Outcome.Why)
	if Verdict == nil then
		return
	end
	table.insert(Broken, `{Verdict.Named} answered '{Verdict.Why}' and only [{table.concat(Verdict.Allowed, ", ")}] were allowed: {Verdict.Says}`)
end

export type Options = {
	Limits: Limits.Sizes?,
	Rounds: number?,
	Servers: number?,
	Faults: boolean?,
	Misdirect: boolean?,
	Throttled: boolean?,
	Players: number?,
	Trace: boolean?,
}

local function Run(Seed: number, Options: Options?): Report
	local Held: Options = Options or {}
	local Started = os.clock()
	local Rng = Random.new(Seed)
	local Splits = Random.new(Rng:NextInteger(1, MAX_SEED))

	local function Sub(): number
		return Splits:NextInteger(1, MAX_SEED)
	end

	local Rounds = Held.Rounds or Rng:NextInteger(ROUNDS_LEAST, ROUNDS_MOST)
	local Servers = Held.Servers or Rng:NextInteger(SERVERS_LEAST, SERVERS_MOST)
	local Faulting = Held.Faults ~= false
	local Count = Rng:NextInteger(KEYS_LEAST, KEYS_MOST)

	Say.Reset()
	Lib.Threads.Reset()
	Limits.Set(Held.Limits or SIM_LIMITS)

	Time.Restart()
	Ledger.UseClock(Time.Read, Time.Sleep)

	Walker:Stop()
	Walker.Passes = 0
	Walker.Resume = 1

	local Plate = Disk.New()
	Plate.MaxValue = Limits.Value
	Plate.Players = Held.Players or 20
	Plate.Throttled = Held.Throttled == true

	local Faulty = Board.New(Rng)
	Faulty.Keeping = Held.Trace == true
	if Held.Misdirect ~= true then
		Faulty.Faults.Misdirect = 0
	end
	if not Faulting then
		Board.Heal(Faulty)
	end
	Board.Install(Faulty, Lib.Wrapper, Plate)
	local Backing = { Board = Faulty, Disk = Plate }

	local Cover = Coverage.New()
	local Books = Auditor.New()
	local Threw: { string } = {}
	local Broken: { string } = {}
	local Built: { any } = {}
	local Issued = 0
	local Crashes = 0
	local Steps = 0

	local Fine, Raised = pcall(function()
		for _, Keys in { "Player", "String" } do
			local Data = `V2d{Seed}{Keys}`
			local Marked = `V2d{Seed}{Keys}Tx`
			local Names = Pool(Keys, Count, Seed)
			local Where = Invariants.Across(Names, Data)

			local Nodes: { string } = table.create(Servers) :: { string }
			for Index = 1, Servers do
				Nodes[Index] = `node{Index}`
			end
			local Fleet: { any } = {}
			for Index = 1, Servers do
				Fleet[Index] = Build(Keys, Data, Marked, nil, Backing, Nodes[Index])
				table.insert(Built, Fleet[Index])
			end

			local Format = Fleet[1]:Format()

			local Kept = Faulty.Faults
			Board.Heal(Faulty)
			local Funding = Scheduler.New(Sub())
			Plate.Turn = Funding
			Time.Bind(Funding)
			Funding:Spawn(function()
				for _, Key in Names do
					local Funded, Why = Fleet[1]:Edit(Key, "Fund", { Amount = FUNDS }):Wait()
					if not Funded then
						table.insert(Threw, `could not fund '{tostring(Key)}': {tostring(Why)}`)
					end
				end
			end)
			Funding:Run()
			Steps += Funding.Steps
			Plate.Turn = nil
			Time.Bind(nil)
			Faulty.Faults = Kept
			local Expected = FUNDS * Count
			local Stop = false
			local Ring: { string } = {}
			local Drift = 0
			local Shape: { [string]: number } = {}
			local Range = Model.New(Names, { Gold = FUNDS })
			local Shared: {
				Routes: { [string]: any },
				Legs: { [string]: number },
				Grants: { [string]: number },
				Pairs: { [string]: any },
				Fat: { Now: boolean },
				Model: Model.Model,
				Lied: { string },
				Bookings: { any },
			} =
				{ Routes = {}, Legs = {}, Grants = {}, Pairs = {}, Fat = { Now = false }, Model = Range, Lied = {}, Bookings = {} }

			local Turn = Scheduler.New(Sub())
			Plate.Turn = Turn
			Time.Bind(Turn)

			for Index = 1, Servers do
				local Store = Fleet[Index]
				local Own = Random.new(Sub())
				local Drawn = Weighted(Own, Keys)
				local World = Workload.New(Store, Names, Own, Keys, Opener(Store, Keys), Ledger.Sweep, Ledger.CloseAll, Shared)

				Turn:Spawn(function()
					for _ = 1, Rounds // Servers do
						if Stop then
							return
						end

						if Own:NextNumber() < CRASH_CHANCE then
							Crash(Store)
							Store = Build(Keys, Data, Marked, nil, Backing, Nodes[Index])
							Fleet[Index] = Store
							table.insert(Built, Store)
							World = Workload.New(Store, Names, Own, Keys, Opener(Store, Keys), Ledger.Sweep, Ledger.CloseAll, Shared)
							Crashes += 1
						end

						local Pick = Swarm.Pick(Own, Drawn)
						local Ran, Answer = Workload.Issue(World, Pick)
						Issued += 1

						if not Ran then
							Cover:Threw(Pick)
							table.insert(Threw, `{Pick} threw: {Answer :: string}`)
							continue
						end

						local Outcome = Answer :: Workload.Outcome
						Cover:Note(Pick, Outcome.Ok, Outcome.Why)

						Judge(Books, Broken, Pick, Outcome, {
							Faults = Faulting,
							Concurrent = Servers > 1,
							Shutting = false,
							Aged = false,
							Fat = Shared.Fat.Now,
							Junk = Outcome.Junk == true,
						})

						if Held.Trace == true then
							local Now = Each(Plate, Where, Format)
							local Total = 0
							for _, Amount in Now do
								Total += Amount
							end

							local Off = Total - Expected
							if Off ~= Drift and #Ring < TRACE_KEEP then
								table.insert(
									Ring,
									`op {Issued}: {Nodes[Index]} {Pick} -> {if Outcome.Ok then "Ok" else tostring(Outcome.Why)} took the books from {Drift} to {Off} ({Moved(Shape, Now)}) after {#Faulty.Journal} write(s)`
								)
							end
							Drift = Off
							Shape = Now
						end

						if Own:NextNumber() >= SAFETY_EVERY then
							continue
						end

						local Seen = Invariants.Safety(Plate, Where, Format, "Gold", nil)
						if #Seen.Broken > 0 then
							for _, Line in Seen.Broken do
								table.insert(Broken, `mid run: {Line}`)
							end
							Stop = true
							return
						end
					end
				end)
			end

			Turn:Run()
			Steps += Turn.Steps
			if Turn.GaveUp then
				table.insert(Threw, `the {Keys} fleet stalled with threads still running`)
			end

			local After = Scheduler.New(Sub())
			Plate.Turn = After
			Time.Bind(After)

			After:Spawn(function()
				Board.Heal(Faulty)
				local Alive = Liveness.Converge(Plate, Where, { Marked }, Format, Fleet[1], Names)
				if not Alive.Ok then
					table.insert(Broken, `liveness: {Alive.Says}`)
				end

				local Rest = Invariants.Settled(Plate, Where, Format, "Gold", Expected)
				for _, Line in Rest.Broken do
					table.insert(Broken, `settled: {Line}`)
				end

				for _, Line in Range:Check(Plate, Where, Format) do
					table.insert(Broken, `model: {Line}`)
				end

				for _, Line in Shared.Lied do
					table.insert(Broken, `read: {Line}`)
				end

				for _, Line in Invariants.Reads(Plate, Where, Format, Fleet[1], "Gold") do
					table.insert(Broken, `read: {Line}`)
				end

				if Keys == "String" then
					for _, Line in Invariants.Tallies(Plate, Data, { "tally1", "tally2" }, Format, Fleet[1], "Gold") do
						table.insert(Broken, `tally: {Line}`)
					end
				end
				if #Rest.Broken > 0 then
					for _, Line in Ring do
						table.insert(Broken, `  trail: {Line}`)
					end
				end

				for _, Line in Invariants.Transactions(Plate, Where, { Marked }, Format, Shared.Legs, true) do
					table.insert(Broken, `transaction: {Line}`)
				end

				for Mark, Count in Shared.Grants do
					if Count > 1 then
						table.insert(Broken, `once: '{Mark}' was accepted {Count} times, a Once name lands at most once on a key`)
					end
				end

				Fatten(Opener(Fleet[1], Keys), Names[1], Cover)
				table.insert(Built, Aged(Fleet[1], Keys, Data, Marked, Names[#Names], Rng, Cover, Threw))
				Steps += Crowd(Fleet[1], Keys, Names[1], Rng, Cover, Ledger.CloseAll, Plate, Sub())

				local Last = Workload.New(Fleet[1], Names, Rng, Keys, Opener(Fleet[1], Keys), Ledger.Sweep, Ledger.CloseAll)
				for _, Named in { "Reset", "Erase", "CloseAll" } do
					local Ran, Answer = Workload.Issue(Last, Named)
					if not Ran then
						table.insert(Threw, `{Named} threw: {Answer :: string}`)
						continue
					end
					local Outcome = Answer :: Workload.Outcome
					Cover:Note(Named, Outcome.Ok, Outcome.Why)
				end
			end)

			After:Run()
			Steps += After.Steps
			Plate.Turn = nil
			Time.Bind(nil)
			if After.GaveUp then
				table.insert(Threw, `the {Keys} tail stalled with threads still running`)
			end
		end
	end)

	local Closing = Scheduler.New(Sub())
	Plate.Turn = Closing
	Time.Bind(Closing)
	Closing:Spawn(function()
		for _, Store in Built do
			local Gone = pcall(function()
				Store:Destroy()
			end)
			Cover:Note("Destroy", Gone, nil)
		end
	end)
	Closing:Run()
	Steps += Closing.Steps
	Plate.Turn = nil
	Time.Bind(nil)
	Disk.Shut(Plate)

	Ledger.UseClock(nil, nil)
	Limits.Reset()

	if not Fine then
		table.insert(Threw, `the run itself threw: {tostring(Raised)}`)
	end

	return {
		Seed = Seed,
		Rounds = Rounds,
		Issued = Issued,
		Threw = Threw,
		Broken = Broken,
		Missed = Cover:Missed(),
		Silent = Cover:Silent(),
		Cover = Cover,
		Books = Books,
		Calls = Faulty.Calls,
		Injected = Faulty.Injected,
		Lost = Faulty.Lost,
		Moved = Faulty.Moved,
		Journal = Faulty.Journal,
		Crashes = Crashes,
		Steps = Steps,
		Seconds = os.clock() - Started,
		Warnings = Say.Total(),
		Said = Say.Records(),
	}
end

return table.freeze({
	Run = Run,
	Banker = Banker,
	DEFAULT = DEFAULT,
})
