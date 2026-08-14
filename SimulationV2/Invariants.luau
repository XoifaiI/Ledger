--!strict
--!optimize 2

--[=[
	Invariants: What has to be true of the books.

	The auditor asks whether an answer was legal. This asks whether the money is right, and the two
	catch different bugs. Safety holds at every moment. Settled holds only once everything is quiet,
	and it says the stronger thing. Every read goes at the stored record and folds it here.

	Return type: A table with Across, Safety, Settled, Transactions, Reads, Tallies and the reports.
	Example usage:
		local Report = Invariants.Settled(Plate, Where, Format, "Gold", 5000)
--]=]

local Lib = require("./Lib")
local Disk = require("./Disk")

local Entries = Lib.Entries
local Stamp = Lib.Stamp

type Disk = Disk.Disk

export type Report = {
	Ok: boolean,
	Broken: { string },
	Balance: number,
	Held: number,
	Booked: number,
	Keys: number
}

export type Where = { [string]: string }

local function Record(Raw: any): any
	if type(Raw) ~= "table" then
		return { Ops = {}, Seen = {} }
	end

	return {
		Snapshot = if type(Raw.Snapshot) == "table" then Raw.Snapshot else nil,
		Ops = if type(Raw.Ops) == "table" then Raw.Ops else {},
		Seen = if type(Raw.Seen) == "table" then Raw.Seen else {},
		Version = if type(Raw.Version) == "number" then Raw.Version else nil,
		Floor = if type(Raw.Floor) == "number" then Raw.Floor else nil
	}
end

local function Sum(Entries: any, Field: string): number
	if type(Entries) ~= "table" then
		return 0
	end

	local Total = 0
	for _, Held in Entries do
		if type(Held) == "table" and type(Held[Field]) == "number" then
			Total += Held[Field]
		end
	end
	return Total
end

local function Across(Keys: { string }, Name: string): Where
	local Held: Where = {}
	for _, Key in Keys do
		Held[Key] = Name
	end
	return Held
end

local function Safety(Board: Disk, Where: Where, Format: any, Field: string, Expected: number?, Drift: number?): Report
	local Broken: { string } = {}
	local Balance, Held, Booked, Counted = 0, 0, 0, 0
	local Delivered: { [string]: string } = {}

	for Key, Name in Where do
		Counted += 1
		local State: any = Format:Fold(Record(Disk.Peek(Board, Name, Key)))

		local Amount = State[Field]
		if type(Amount) ~= "number" then
			table.insert(Broken, `{Key} holds a {typeof(Amount)} where its balance should be`)
		else
			if Amount < 0 then
				table.insert(Broken, `{Key} went negative at {Amount}`)
			end
			Balance += Amount
		end

		local Holds = State._Held
		if type(Holds) == "table" then
			for Tid, Entry in Holds do
				if type(Entry) ~= "table" or type(Entry.Amount) ~= "number" or Entry.Amount <= 0 then
					table.insert(Broken, `{Key} holds a malformed escrow for {tostring(Tid)}`)
				end
			end
			Held += Sum(Holds, "Amount")
		end
		Booked += Sum(State._Booked, "Amount")

		local Received = State._Received
		if type(Received) == "table" then
			for Id in Received do
				if type(Id) ~= "string" or string.sub(Id, 1, #Entries.TRANSFER) ~= Entries.TRANSFER then
					continue
				end
				local Already = Delivered[Id]
				if Already ~= nil then
					table.insert(Broken, `{Id} was delivered to both {Already} and {Key}`)
				end
				Delivered[Id] = Key
			end
		end
	end

	local Slack = Drift or 0
	local Total = Balance + Held + Booked
	if Expected == nil then
		return { Ok = #Broken == 0, Broken = Broken, Balance = Balance, Held = Held, Booked = Booked, Keys = Counted }
	end

	if Total < Expected - Slack then
		table.insert(Broken, `money fell to {Total} of {Expected}, further than the {Slack} that can be unfinished`)
	elseif Total > Expected + Slack then
		table.insert(Broken, `money rose to {Total} of {Expected}, further than the {Slack} that can be unfinished`)
	end

	return { Ok = #Broken == 0, Broken = Broken, Balance = Balance, Held = Held, Booked = Booked, Keys = Counted }
end

local function Settled(Board: Disk, Where: Where, Format: any, Field: string, Expected: number): Report
	local Held = Safety(Board, Where, Format, Field, Expected)

	if Held.Balance + Held.Held + Held.Booked ~= Expected then
		table.insert(
			Held.Broken,
			`money settled at {Held.Balance + Held.Held + Held.Booked} and should be {Expected}, balance {Held.Balance} plus held {Held.Held} plus booked {Held.Booked}`
		)

		for Key, Name in Where do
			local State: any = Format:Fold(Record(Disk.Peek(Board, Name, Key)))
			local Balance = if type(State[Field]) == "number" then State[Field] else 0
			local Escrow = Sum(State._Held, "Amount")
			local Booked = Sum(State._Booked, "Amount")

			local Names: { string } = {}
			if type(State._Booked) == "table" then
				for Rid, Entry in State._Booked do
					local Amount = if type(Entry) == "table" then Entry.Amount else "?"
					local To = if type(Entry) == "table" and Entry.To ~= nil then tostring(Entry.To) else "nobody"
					table.insert(Names, `{tostring(Rid)}={tostring(Amount)} for {To}`)
				end
			end

			table.insert(
				Held.Broken,
				`  {Key}: balance {Balance}, escrow {Escrow}, booked {Booked}{if #Names > 0 then ` [{table.concat(Names, ", ")}]` else ""}`
			)
		end
	end

	for Key, Name in Where do
		local Stored = Record(Disk.Peek(Board, Name, Key))
		if Stamp.HasPending(Stored) then
			table.insert(Held.Broken, `{Key} still has a transaction leg parked on it`)
		end

		local State: any = Format:Fold(Stored)
		if type(State._Held) == "table" and next(State._Held) ~= nil then
			table.insert(Held.Broken, `{Key} still holds escrow after everything went quiet`)
		end
	end

	Held.Ok = #Held.Broken == 0
	return Held
end

local function Transactions(Board: Disk, Where: Where, Marks: { string }, Format: any, Legs: { [string]: number }, Quiet: boolean): { string }
	local Broken: { string } = {}
	local Applied: { [string]: number } = {}
	local Waiting: { [string]: number } = {}

	for Key, Name in Where do
		local Stored = Record(Disk.Peek(Board, Name, Key))
		local State: any = Format:Fold(Stored)

		for Txid in Legs do
			if Entries.Has(State._Received, Entries.TX, Txid) then
				Applied[Txid] = (Applied[Txid] or 0) + 1
			end
		end
		for Txid in Stamp.PendingTx(Stored) do
			Waiting[Txid] = (Waiting[Txid] or 0) + 1
		end
	end

	for Txid, Count in Legs do
		local Landed = Applied[Txid] or 0
		if Landed ~= 0 and Landed ~= Count then
			table.insert(Broken, `{Txid} applied to {Landed} of its {Count} keys`)
		end
		if Quiet and (Waiting[Txid] or 0) > 0 then
			table.insert(Broken, `{Txid} still has {Waiting[Txid]} pending leg(s) after everything went quiet`)
		end
	end

	if Quiet then
		for _, Table in Marks do
			for _, Txid in Disk.Keys(Board, Table) do
				if Legs[Txid] ~= nil then
					table.insert(Broken, `{Txid} left its marker behind in {Table}`)
				end
			end
		end
	end

	return Broken
end

local function Unfinished(Board: Disk, Where: Where, Marks: { string }, Format: any): { string }
	local Left: { string } = {}

	for _, Table in Marks do
		for _, Txid in Disk.Keys(Board, Table) do
			table.insert(Left, `marker '{Txid}' is still in {Table}`)
		end
	end

	for Key, Name in Where do
		local Stored = Record(Disk.Peek(Board, Name, Key))
		for Txid in Stamp.PendingTx(Stored) do
			table.insert(Left, `'{Key}' still has a leg parked for '{Txid}'`)
		end

		local State: any = Format:Fold(Stored)
		if type(State._Held) == "table" then
			for Tid, Entry in State._Held do
				local Amount = if type(Entry) == "table" then Entry.Amount else "?"
				local To = if type(Entry) == "table" then Entry.To else "?"
				table.insert(Left, `'{Key}' still holds {tostring(Amount)} in escrow for '{tostring(Tid)}' bound for '{tostring(To)}'`)
			end
		end
	end

	return Left
end

local function Reads(Board: Disk, Where: Where, Format: any, Store: any, Field: string): { string }
	local Broken: { string } = {}

	for Key, Name in Where do
		local Stored: any = Format:Fold(Record(Disk.Peek(Board, Name, Key)))
		local Ok, Live = pcall(function(): any
			return (Store:Peek(Key):Wait())
		end)

		if not Ok or type(Live) ~= "table" then
			table.insert(Broken, `Peek on {Key} gave back {if Ok then typeof(Live) else "an error"} and the record is there to read`)
			continue
		end

		if Live[Field] ~= Stored[Field] then
			table.insert(Broken, `Peek on {Key} says {Field} is {tostring(Live[Field])} and the stored record folds to {tostring(Stored[Field])}`)
		end
		if Sum(Live._Held, "Amount") ~= Sum(Stored._Held, "Amount") then
			table.insert(Broken, `Peek on {Key} disagrees with the record about the money set aside`)
		end
		if Sum(Live._Booked, "Amount") ~= Sum(Stored._Booked, "Amount") then
			table.insert(Broken, `Peek on {Key} disagrees with the record about the units set aside`)
		end
	end

	return Broken
end

local function Tallies(Board: Disk, Name: string, Named: { string }, Format: any, Store: any, Field: string): { string }
	local Broken: { string } = {}

	for _, Tally in Named do
		local Front = `{Tally}#`
		local Total = 0
		local Shards = 0

		for _, Key in Disk.Keys(Board, Name) do
			if string.sub(Key, 1, #Front) ~= Front then
				continue
			end

			local State: any = Format:Fold(Record(Disk.Peek(Board, Name, Key)))
			Total += if type(State[Field]) == "number" then State[Field] else 0
			Shards += 1
		end

		local Ok, Said = pcall(function(): any
			return (Store:Total(Tally, Field):Wait())
		end)
		if not Ok or type(Said) ~= "number" then
			table.insert(Broken, `Total for '{Tally}' gave back {if Ok then typeof(Said) else "an error"} across {Shards} shard(s)`)
			continue
		end
		if Said ~= Total then
			table.insert(Broken, `Total for '{Tally}' says {Said} and its {Shards} shard(s) hold {Total}`)
		end
	end

	return Broken
end

local function Markers(Board: Disk, Marks: { string }, Horizon: number, Now: number): { string }
	local Said: { string } = {}

	for _, Table in Marks do
		for _, Txid in Disk.Keys(Board, Table) do
			local Held = Disk.Peek(Board, Table, Txid)
			if type(Held) ~= "table" then
				continue
			end

			local Adopted = 0
			for _ in if type(Held.Adopted) == "table" then Held.Adopted else {} do
				Adopted += 1
			end

			local Named: { string } = {}
			local Packed = if type(Held.Keys) == "string" then Held.Keys else ""
			for _, Framed in Lib.Mark.Unpack(Packed) do
				local Name, Key = Lib.Mark.Split(Framed)
				if Name == nil or Key == nil then
					table.insert(Named, `a mark that does not split into a store and a key`)
					continue
				end

				local Carries = false
				for _, Op in Record(Disk.Peek(Board, Name, Key)).Ops do
					if Op.Tx == Txid then
						Carries = true
						break
					end
				end
				table.insert(Named, `{Key} {if Carries then "still carries its leg" else "has forgotten it"}`)
			end

			local Written = Disk.Stamp(Board, Table, Txid)
			local Age = if Written ~= nil then `{Now - Written}s old and the reaper wants {Horizon}s` else "never written"

			table.insert(
				Said,
				`'{Txid}' in {Table} is {tostring(Held.Status)}, {Adopted} of {tostring(Held.Total)} leg(s) adopted, {Age}, keys [{table.concat(Named, ", ")}]`
			)
		end
	end

	return Said
end

local function Unsettled(Board: Disk, Where: Where, Marks: { string }, Format: any): number
	return #Unfinished(Board, Where, Marks, Format)
end

return table.freeze({
	Across = Across,
	Safety = Safety,
	Reads = Reads,
	Tallies = Tallies,
	Settled = Settled,
	Transactions = Transactions,
	Markers = Markers,
	Unsettled = Unsettled,
	Unfinished = Unfinished
})
