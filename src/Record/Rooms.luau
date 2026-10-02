--!strict
--!optimize 2

--[=[
	Rooms: Logic. The widths of the record's rooms, and the two steps that keep them in bounds.

	Spec: record 2.4; record 4, steps 7 and 8.

	Age drops what has outlived its window, and never this writer's entry. It raises the horizon over
	each writer entry and timed name it drops, and the cut horizon over each cut name. An untimed
	name leaves at its window and raises nothing. Evict frees such names first, oldest first, for an
	untimed op that meets a full room before Age has run. Fit drops the least stamp
	from the timed room until it fits, and raises the horizon each time. Items held ahead and this
	request's own names go last. Fit also trims the cut names to the build's count, oldest first.

	Return type: The Rooms module.
	Example usage:
		Rooms.Fit(Record, Build, Now, Writer, Written)
--]=]

local Book = require("./Book")
local Types = require("./Types")

type Book = Book.Book
type Build = Types.Build

type Candidate = {
	Far: boolean,
	Mine: boolean,
	Stamp: number,
	Writer: number?,
	Name: string?,
	Width: number,
}

local WorkForm = Book.WorkForm

local Rooms = {}

function Rooms.Timed(Record: Book, Now: number): number
	local Total = 0
	for _, Found in Record.Writers do
		Total += Book.EntryWidth(Found, Now)
	end
	for Name, Item in Record.Timed do
		Total += Book.NamedWidth(Name, Item, Now)
	end
	return Total
end

function Rooms.Untimed(Record: Book, Now: number): number
	local Total = 0
	for Name, Item in Record.Untimed do
		Total += Book.NamedWidth(Name, Item, Now)
	end
	return Total
end

function Rooms.Work(Record: Book, Now: number): number
	local Total = 0
	for Name, Item in Record.Work do
		Total += Book.WorkWidth(Name, Item, Now)
	end
	return Total
end

function Rooms.Count(Record: Book): (number, number)
	local Marked, Pinned = 0, 0
	for _, Item in Record.Work do
		if Item.Form == WorkForm.Pinned then
			Pinned += 1
		else
			Marked += 1
		end
	end
	return Marked, Pinned
end

local function Window(Build: Build, Kind: number): number
	return Build.Window[Kind] or Build.Minted
end

function Rooms.Evict(Record: Book, Build: Build, Now: number, Epoch: number, Need: number): number
	local Aged: { string } = {}
	for Name, Item in Record.Untimed do
		if Now - Item.Stamp >= Window(Build, Item.Kind) then
			table.insert(Aged, Name)
		end
	end
	table.sort(Aged, function(Left: string, Right: string): boolean
		local First, Second = Record.Untimed[Left].Stamp, Record.Untimed[Right].Stamp
		return if First ~= Second then First < Second else Left < Right
	end)
	local Freed = 0
	for _, Name in Aged do
		if Freed >= Need then
			break
		end
		Freed += Book.NamedWidth(Name, Record.Untimed[Name], Epoch)
		Record.Untimed[Name] = nil
	end
	return Freed
end

function Rooms.Age(Record: Book, Build: Build, Now: number, Writer: number): boolean
	local Horizon, CutHorizon = Record.Horizon, Record.CutHorizon
	local Dropped = false
	for Id, Found in Record.Writers do
		if Id ~= Writer and Now - Found.Stamp >= Build.Minted then
			Record.Writers[Id] = nil
			Horizon = math.max(Horizon, Found.Stamp)
			Dropped = true
		end
	end
	for Name, Item in Record.Timed do
		if Now - Item.Stamp >= Window(Build, Item.Kind) then
			Record.Timed[Name] = nil
			Horizon = math.max(Horizon, Item.Stamp)
			Dropped = true
		end
	end
	for Name, Item in Record.Cut do
		if Now - Item.Stamp >= Build.CutWindow then
			Record.Cut[Name] = nil
			CutHorizon = math.max(CutHorizon, Item.Stamp)
			Dropped = true
		end
	end
	for Name, Item in Record.Untimed do
		if Now - Item.Stamp >= Window(Build, Item.Kind) then
			Record.Untimed[Name] = nil
			Dropped = true
		end
	end
	Record.Horizon = Horizon
	Record.CutHorizon = CutHorizon
	return Dropped
end

local function Before(Left: Candidate, Right: Candidate): boolean
	if Left.Far ~= Right.Far then
		return not Left.Far
	elseif Left.Mine ~= Right.Mine then
		return not Left.Mine
	elseif Left.Stamp ~= Right.Stamp then
		return Left.Stamp < Right.Stamp
	elseif (Left.Writer == nil) ~= (Right.Writer == nil) then
		return Left.Writer ~= nil
	elseif Left.Writer and Right.Writer then
		return Left.Writer < Right.Writer
	end
	return (Left.Name :: string) < (Right.Name :: string)
end

function Rooms.Fit(Record: Book, Build: Build, Now: number, Writer: number, Written: { [string]: true })
	local Total = Rooms.Timed(Record, Now)
	if Total > Build.TimedRoom then
		local Candidates: { Candidate } = {}
		for Id, Found in Record.Writers do
			if Id ~= Writer then
				table.insert(Candidates, {
					Far = Found.Stamp > Now + Build.Hold,
					Mine = false,
					Stamp = Found.Stamp,
					Writer = Id,
					Width = Book.EntryWidth(Found, Now),
				})
			end
		end
		for Name, Item in Record.Timed do
			table.insert(Candidates, {
				Far = Item.Stamp > Now + Build.Hold,
				Mine = Written[Name] == true,
				Stamp = Item.Stamp,
				Name = Name,
				Width = Book.NamedWidth(Name, Item, Now),
			})
		end
		table.sort(Candidates, Before)
		for _, Drop in Candidates do
			if Total <= Build.TimedRoom then
				break
			end
			if Drop.Writer then
				Record.Writers[Drop.Writer] = nil
			else
				Record.Timed[Drop.Name :: string] = nil
			end
			Total -= Drop.Width
			Record.Horizon = math.max(Record.Horizon, Drop.Stamp)
		end
	end

	local Names: { string } = {}
	for Name in Record.Cut do
		table.insert(Names, Name)
	end
	if #Names <= Build.CutNames then
		return
	end
	table.sort(Names, function(Left: string, Right: string): boolean
		local LeftStamp, RightStamp = Record.Cut[Left].Stamp, Record.Cut[Right].Stamp
		return if LeftStamp ~= RightStamp then LeftStamp < RightStamp else Left < Right
	end)
	for Index = 1, #Names - Build.CutNames do
		local Name = Names[Index]
		Record.CutHorizon = math.max(Record.CutHorizon, Record.Cut[Name].Stamp)
		Record.Cut[Name] = nil
	end
end

return Rooms
