--!strict
--!optimize 2

--[=[
	Model: What each key must hold once nothing is in flight.

	The auditor asks whether an answer was legal and the invariants ask whether the money adds up.
	Neither asks whether this key holds what the operations that ran should have left on it.
	It writes down what was asked for, then reads the record to see what landed. One unit off fails.

	Return type: A table with New, TRANSFER, TX and GRANT. The types are Bounds and Model.
	Example usage:
		local Books = Model.New(Keys, { Gold = 5000 })
		Books:Note(Model.TRANSFER, "tid3", "k1", "k2", 25)
--]=]

local Disk = require("./Disk")
local Lib = require("./Lib")

local Entries = Lib.Entries

type Disk = Disk.Disk

export type Bounds = { [string]: number }

type Asked = {
	Tag: string,
	Id: string,
	From: string,
	To: string,
	Amount: number
}

type ModelImpl = {
	__index: ModelImpl,

	Note: (self: Model, Tag: string, Id: string, From: any, To: any, Amount: number) -> (),
	Booked: (self: Model, Rid: string, From: any, To: any, Amount: number) -> (),
	Blur: (self: Model, Key: any) -> (),
	Spend: (self: Model, Key: any, Field: string, Amount: number) -> (),
	Check: (self: Model, Board: Disk, Where: { [string]: string }, Format: any) -> { string }
}

export type Model = setmetatable<{
	Start: Bounds,
	Keys: { [string]: boolean },
	Asked: { Asked },
	Seen: { [string]: boolean },
	Books: { [string]: { Asked } },
	Blurred: { [string]: boolean },
	Spent: { [string]: number },
	Field: string
}, ModelImpl>

local TRANSFER = Entries.TRANSFER
local TX = Entries.TX
local GRANT = Entries.GRANT

local Model = {} :: ModelImpl
Model.__index = Model

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

local function Money(State: any, Field: string): number
	local Total = if type(State[Field]) == "number" then State[Field] else 0
	for _, Entry in if type(State._Booked) == "table" then State._Booked else {} do
		if type(Entry) == "table" and Entry.Field == Field and type(Entry.Amount) == "number" then
			Total += Entry.Amount
		end
	end
	for _, Entry in if type(State._Held) == "table" then State._Held else {} do
		if type(Entry) == "table" and type(Entry.Amount) == "number" then
			Total += Entry.Amount
		end
	end
	return Total
end

local function New(Keys: { any }, Start: Bounds): Model
	local Named: { [string]: boolean } = {}
	local Field = next(Start) :: string

	for _, Key in Keys do
		Named[tostring(Key)] = true
	end

	return setmetatable({
		Start = table.clone(Start),
		Keys = Named,
		Asked = {},
		Seen = {},
		Books = {},
		Blurred = {},
		Spent = {},
		Field = Field
	}, Model) :: any
end

function Model.Note(self: Model, Tag: string, Id: string, From: any, To: any, Amount: number)
	local Mark = `{Tag}{Id}`
	if self.Seen[Mark] then
		return
	end

	local Left, Right = tostring(From), tostring(To)
	if not self.Keys[Left] or not self.Keys[Right] then
		return
	end

	self.Seen[Mark] = true
	table.insert(self.Asked, { Tag = Tag, Id = Id, From = Left, To = Right, Amount = Amount })
end

function Model.Booked(self: Model, Rid: string, From: any, To: any, Amount: number)
	local Held = self.Books[Rid]
	if Held == nil then
		Held = {}
		self.Books[Rid] = Held
	end
	table.insert(Held, { Tag = GRANT, Id = Rid, From = tostring(From), To = tostring(To), Amount = Amount })
end

function Model.Blur(self: Model, Key: any)
	self.Blurred[tostring(Key)] = true
end

function Model.Spend(self: Model, Key: any, Field: string, Amount: number)
	local Named = tostring(Key)
	self.Spent[Named] = (self.Spent[Named] or 0) + Amount
end

function Model.Check(self: Model, Board: Disk, Where: { [string]: string }, Format: any): { string }
	local Field = self.Field
	local Live: { [string]: any } = {}
	local Wanted: { [string]: number } = {}

	for Key, Name in Where do
		local Named = tostring(Key)
		Live[Named] = Format:Fold(Record(Disk.Peek(Board, Name, Key)))
		Wanted[Named] = self.Start[Field] - (self.Spent[Named] or 0)
	end

	for _, Held in self.Asked do
		local Landed: any = Live[Held.To]
		if Landed == nil or Wanted[Held.From] == nil then
			continue
		end
		if not Entries.Has(Landed._Received, Held.Tag, Held.Id) then
			continue
		end

		Wanted[Held.From] -= Held.Amount
		Wanted[Held.To] += Held.Amount
	end

	for Rid, Held in self.Books do
		local Landed: { Asked } = {}
		for _, One in Held do
			local Arrived: any = Live[One.To]
			if Arrived ~= nil and Entries.Has(Arrived._Received, GRANT, Rid) then
				table.insert(Landed, One)
			end
		end

		if #Landed == 1 and Wanted[Landed[1].From] ~= nil then
			Wanted[Landed[1].From] -= Landed[1].Amount
			Wanted[Landed[1].To] += Landed[1].Amount
			continue
		end
		for _, One in Landed do
			self.Blurred[One.From] = true
			self.Blurred[One.To] = true
		end
	end

	local Broken: { string } = {}
	for Key, Should in Wanted do
		if self.Blurred[Key] then
			continue
		end

		local Has = Money(Live[Key], Field)
		if Has ~= Should then
			table.insert(
				Broken,
				`{Key}.{Field} holds {Has} and the {#self.Asked} move(s) that ran make it {Should}, off by {Has - Should}`
			)
		end
	end
	return Broken
end

table.freeze(Model)

return table.freeze({
	New = New,

	TRANSFER = TRANSFER,
	TX = TX,
	GRANT = GRANT
})
