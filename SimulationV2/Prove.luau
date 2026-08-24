--!strict
--!optimize 2

--[=[
	Prove: Walks a small space whole, with Exhaustive.

	A sweep says a bug did not show up in the seeds it tried. This says it is not there at all, for
	every sequence the bounds allow. The walk is short because the space multiplies. Each sequence
	gets the same questions the sweep asks, or the walk would prove the wrong thing.

	Return type: A table with Run and its bounds. The type is Report.
	Example usage:
		local Walked = Prove.Run()
--]=]

local Disk = require("./Disk")
local Exhaustive = require("./Exhaustive")
local Invariants = require("./Invariants")
local Model = require("./Model")
local Lib = require("./Lib")
local Scheduler = require("./Scheduler")
local Time = require("./Time")

local Ledger = Lib.Ledger

export type Report = {
	Ok: boolean,
	Walked: number,
	Broken: { string },
	Seconds: number,
}

local DEPTH = 4
local KEYS = 2
local FUNDS = 100
local AMOUNT = 25

local WALK_LIMIT = 24576
local BREATHE = 4

local KINDS: { string } = { "Edit", "Transfer", "Reserve" }

local DATA = "V2prove"

local DEFAULT: any = { Gold = 0, Touches = 0 }

local function Banker(State: any, Op: any): any?
	if Op.Kind == "Fund" then
		return { Gold = State.Gold + Op.Amount, Touches = State.Touches }
	elseif Op.Kind == "Touch" then
		return { Gold = State.Gold, Touches = State.Touches + 1 }
	end
	return nil
end

local Claimed = 0

local function Once(Walk: Exhaustive.Walk, Store: any, Plate: Disk.Disk, Names: { string }): { string }
	for _, Key in Names do
		Store:Edit(Key, "Fund", { Amount = FUNDS }):Wait()
	end

	local Books = Model.New(Names, { Gold = FUNDS })

	for Step = 1, DEPTH do
		local Kind = KINDS[Walk:Index(KINDS)]
		local From = Names[Walk:Index(Names)]
		local To = Names[Walk:Index(Names)]

		if Kind == "Edit" then
			Store:Edit(From, "Touch", { Note = Step }):Wait()
		elseif Kind == "Transfer" and From ~= To then
			Books:Note(Model.TRANSFER, `p{Step}`, From, To, AMOUNT)
			Store:Transfer(From, To, AMOUNT, `p{Step}`):Wait()
		elseif Kind == "Reserve" then
			Store:Reserve(From, "Gold", AMOUNT, `r{Step}`):Wait()
		end
	end

	local Where = Invariants.Across(Names, DATA)
	local Format = Store:Format()

	local Broken = Invariants.Safety(Plate, Where, Format, "Gold", FUNDS * #Names).Broken
	for _, Line in Books:Check(Plate, Where, Format) do
		table.insert(Broken, `model: {Line}`)
	end
	for _, Line in Invariants.Reads(Plate, Where, Format, Store, "Gold") do
		table.insert(Broken, `read: {Line}`)
	end
	return Broken
end

local function Run(): Report
	local Started = os.clock()
	local Walk = Exhaustive.New()
	local Broken: { string } = {}
	local Walked = 0

	local Names: { string } = table.create(KEYS) :: { string }
	for Index = 1, KEYS do
		Names[Index] = `p{Index}`
	end

	Claimed += 1
	local Store = Ledger.New({
		Name = `V2prove{Claimed}`,
		Keys = "String",
		Default = DEFAULT,
		Balance = "Gold",
		Reducer = Banker,
	})
	Store.Wrapper = Lib.Wrapper.New(DATA)
	Store.TxWrapper = Lib.Wrapper.New(`{DATA}Tx`)
	Store.Books, Store.Shaped = nil, nil
	Store.Wrapper.Attempts, Store.Wrapper.Constant, Store.Wrapper.Exponent, Store.Wrapper.Jitter = 3, 0, 0, 0
	Store.TxWrapper.Attempts, Store.TxWrapper.Constant, Store.TxWrapper.Exponent, Store.TxWrapper.Jitter = 3, 0, 0, 0

	Ledger.UseClock(Time.Read, Time.Sleep)

	local Breathed = os.clock()

	while not Walk:Done() and Walked < WALK_LIMIT do
		Walked += 1

		Time.Restart()
		Lib.Ident.Restart("v2prove000000")

		local Plate = Disk.New()
		Store.Wrapper.Store = Disk.Open(Plate, DATA) :: any
		Store.TxWrapper.Store = Disk.Open(Plate, `{DATA}Tx`) :: any

		local Turn = Scheduler.New(Walked)
		Plate.Turn = Turn
		Time.Bind(Turn)

		local Held: { string } = {}
		Turn:Spawn(function()
			local Fine, Raised = pcall(Once, Walk, Store, Plate, Names)
			if not Fine then
				table.insert(Held, `threw: {tostring(Raised)}`)
				return
			end
			for _, Line in Raised :: { string } do
				table.insert(Held, Line)
			end
		end)
		Turn:Run()

		Plate.Turn = nil
		Time.Bind(nil)

		for _, Line in Held do
			table.insert(Broken, `sequence {Walked}: {Line}`)
		end

		if #Broken > 16 then
			break
		end

		-- a run gives its turns to the scheduler and never to the engine, so the walk has to stop on
		-- its own or it runs longer than a script is allowed to. a stop costs a frame, and between
		-- sequences is the one place where nothing is part way through
		if os.clock() - Breathed >= BREATHE then
			task.wait()
			Breathed = os.clock()
		end
	end

	pcall(function()
		Store:Destroy()
	end)
	Ledger.UseClock(nil, nil)

	return { Ok = #Broken == 0, Walked = Walked, Broken = Broken, Seconds = os.clock() - Started }
end

return table.freeze({
	Run = Run,
	DEPTH = DEPTH,
	KEYS = KEYS,
	KINDS = KINDS,
	WALK_LIMIT = WALK_LIMIT,
})
