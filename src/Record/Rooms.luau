--!strict
--!optimize 2

--[=[

	Rooms: What the record's rooms take, and the two steps that keep them within their bounds.

	Timed and Untimed give the characters the timed room and the untimed room take, the timed room
	holding the writer entries as well as its named items. Age drops what has outlived its window:
	each writer entry but the one of this request's writer, each timed and untimed item, each cut
	name. It raises the horizon over every writer entry and timed item it drops, and the cut horizon
	over every cut name. An untimed drop raises nothing. Fit drops from the timed room until it fits,
	the least stamp first, keeping items stamped more than Hold ahead and items this request wrote
	for last, and names break a tie so every run drops the same item. It raises the horizon over each
	drop. It drops the least cut names past the cut room's count and raises the cut horizon.

	Return type: A table with Timed, Untimed, Age and Fit.
	Example usage:
		local Rooms = require("./Rooms")
		Rooms.Age(Record, Build, Now, Writer)
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

local function Timed(Record: Book, Now: number): number
	local Total = 0
	for _, Found in Record.Writers do
		Total += Book.EntryWidth(Found, Now)
	end
	for Name, Item in Record.Timed do
		Total += Book.NamedWidth(Name, Item, Now)
	end
	return Total
end

local function Untimed(Record: Book, Now: number): number
	local Total = 0
	for Name, Item in Record.Untimed do
		Total += Book.NamedWidth(Name, Item, Now)
	end
	return Total
end

local function Window(Build: Build, Kind: number): number
	return Build.Window[Kind] or Build.Minted
end

local function Age(Record: Book, Build: Build, Now: number, Writer: number)
	local Horizon, CutHorizon = Record.Horizon, Record.CutHorizon
	for Id, Found in Record.Writers do
		if Id ~= Writer and Now - Found.Stamp >= Build.Minted then
			Record.Writers[Id] = nil
			Horizon = math.max(Horizon, Found.Stamp)
		end
	end
	for Name, Item in Record.Timed do
		if Now - Item.Stamp >= Window(Build, Item.Kind) then
			Record.Timed[Name] = nil
			Horizon = math.max(Horizon, Item.Stamp)
		end
	end
	for Name, Item in Record.Untimed do
		if Now - Item.Stamp >= Window(Build, Item.Kind) then
			Record.Untimed[Name] = nil
		end
	end
	for Name, Item in Record.Cut do
		if Now - Item.Stamp >= Build.CutWindow then
			Record.Cut[Name] = nil
			CutHorizon = math.max(CutHorizon, Item.Stamp)
		end
	end
	Record.Horizon, Record.CutHorizon = Horizon, CutHorizon
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

local function Fit(Record: Book, Build: Build, Now: number, Writer: number, Written: { [string]: true })
	local Total = Timed(Record, Now)
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

return table.freeze({
	Timed = Timed,
	Untimed = Untimed,
	Age = Age,
	Fit = Fit,
})
