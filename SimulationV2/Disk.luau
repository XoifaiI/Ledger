--!strict
--!optimize 2

--[=[
	Disk: The datastore that a run reads and writes.

	It copies what a real datastore does. One key is one atomic unit, a transform sees what is there
	now, and a value must survive one trip through json. It gives up its turn through the seeded
	scheduler and counts its budget in simulated seconds, so a run can replay.
	A run ends while work it started is still in flight. Shut parks that work where it next gives up
	its turn, so it cannot carry on against the next run's clock and answer for the wrong seed.

	Return type: A table with New, Open, Peek, Stamp, Keys, Pause, Shut and the caps.
	Example usage:
		local Plate = Disk.New()
		local Store = Disk.Open(Plate, "Players")
--]=]

local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")

local NoYield = require("../src/Util/Work/NoYield")
local Scheduler = require("./Scheduler")
local Time = require("./Time")

type Turn = Scheduler.Scheduler

export type Version = {
	Text: string?,
	Value: any,
	Written: number,
	Deleted: boolean,
	Label: string,
}

export type Slot = {
	Live: string?,
	Versions: { Version },
}

export type Info = {
	read Version: string,
	read CreatedTime: number,
	read UpdatedTime: number,
	read GetUserIds: (self: Info) -> { number },
	read GetMetadata: (self: Info) -> { [string]: any },
}

export type Disk = {
	Slots: { [string]: Slot },
	Turn: Turn?,
	Ticket: number,
	Reads: number,
	Writes: number,
	Conflicts: number,
	Spent: { [string]: number },
	Filled: number,
	Players: number,
	Throttled: boolean,
	Blobbed: boolean,
	MaxValue: number,
	Closed: boolean,
}

local MAX_KEY = 50
local MAX_VALUE = 4 * 1024 * 1024
local KEEP_VERSIONS = 30
local CONFLICT_LIMIT = 32

local REFILL_WINDOW = 60
local STANDARD = { Base = 60, Per = 40 }
local LISTING = { Base = 5, Per = 2 }

local function NoIds(_: Info): { number }
	return {}
end

local function NoMeta(_: Info): { [string]: any }
	return {}
end

local function Stamped(Label: string, Written: number): Info
	return table.freeze({
		Version = Label,
		CreatedTime = Written * 1000,
		UpdatedTime = Written * 1000,
		GetUserIds = NoIds,
		GetMetadata = NoMeta,
	})
end

local function New(): Disk
	return {
		Slots = {},
		Turn = nil,
		Ticket = 0,
		Reads = 0,
		Writes = 0,
		Conflicts = 0,
		Spent = {},
		Filled = Time.Read(),
		Players = 0,
		Throttled = false,
		Blobbed = false,
		MaxValue = MAX_VALUE,
		Closed = false,
	}
end

local function Pause(self: Disk)
	if self.Closed then
		coroutine.yield()
		return
	end

	local Turn = self.Turn
	if Turn ~= nil then
		Turn:Wait()
		return
	end
	task.wait()
end

local function Shut(self: Disk)
	self.Closed = true
	self.Turn = nil
end

local function Checked(Key: string)
	if type(Key) ~= "string" or #Key == 0 then
		error("SimulationV2 disk: a key has to be a non empty string", 0)
	end
	if #Key > MAX_KEY then
		error(`SimulationV2 disk: a key is at most {MAX_KEY} characters`, 0)
	end
end

local SPLIT = string.char(0)

local function Named(Name: string, Key: string): string
	return Name .. SPLIT .. Key
end

local function Slot(self: Disk, Key: string): Slot
	local Held = self.Slots[Key]
	if Held ~= nil then
		return Held
	end

	local Fresh: Slot = { Live = nil, Versions = {} }
	self.Slots[Key] = Fresh
	return Fresh
end

local function Cap(self: Disk, Kind: Enum.DataStoreRequestType): number
	local Allow = if Kind == Enum.DataStoreRequestType.ListAsync then LISTING else STANDARD
	return Allow.Base + Allow.Per * self.Players
end

local function Spend(self: Disk, Kind: Enum.DataStoreRequestType)
	if not self.Throttled then
		return
	end

	local Now = Time.Read()
	if Now - self.Filled >= REFILL_WINDOW then
		self.Filled = Now
		table.clear(self.Spent)
	end

	local Named = Kind.Name
	local Used = (self.Spent[Named] or 0) + 1
	if Used > Cap(self, Kind) then
		error("SimulationV2 disk: request dropped, this server is out of budget", 0)
	end
	self.Spent[Named] = Used
end

local BLOB = "__Buffer"

local function Packed(Value: any): any
	if type(Value) == "buffer" then
		return { [BLOB] = buffer.tostring(EncodingService:Base64Encode(Value)) }
	end
	if type(Value) ~= "table" then
		return Value
	end

	local Out: { [any]: any } = {}
	for Key, Inner in Value do
		Out[Key] = Packed(Inner)
	end
	return Out
end

local function Unpacked(Value: any): any
	if type(Value) ~= "table" then
		return Value
	end

	local Blob = Value[BLOB]
	if type(Blob) == "string" and next(Value, next(Value) :: any) == nil then
		return EncodingService:Base64Decode(buffer.fromstring(Blob))
	end

	local Out: { [any]: any } = {}
	for Key, Inner in Value do
		Out[Key] = Unpacked(Inner)
	end
	return Out
end

local function Encode(self: Disk, Raw: any): string
	local Fine, Text = pcall(HttpService.JSONEncode, HttpService, Raw)
	if not Fine or type(Text) ~= "string" then
		local Again, Held = pcall(HttpService.JSONEncode, HttpService, Packed(Raw))
		Fine, Text = Again, Held
		self.Blobbed = Again
	end
	if not Fine or type(Text) ~= "string" then
		error("SimulationV2 disk: value cannot be stored, a datastore only holds json", 0)
	end
	if #Text > self.MaxValue then
		error(`SimulationV2 disk: value is larger than the {self.MaxValue} byte limit`, 0)
	end
	return Text
end

local function Decode(self: Disk, Text: string?): any
	if Text == nil then
		return nil
	end

	local Fine, Value = pcall(HttpService.JSONDecode, HttpService, Text :: string)
	if not Fine then
		return nil
	end
	if not self.Blobbed or string.find(Text :: string, BLOB, 1, true) == nil then
		return Value
	end
	return Unpacked(Value)
end

local function Clone(Value: any): any
	if type(Value) == "buffer" then
		local Fresh = buffer.create(buffer.len(Value))
		buffer.copy(Fresh, 0, Value)
		return Fresh
	end
	if type(Value) ~= "table" then
		return Value
	end

	local Out: { [any]: any } = {}
	for Key, Inner in Value do
		Out[Key] = Clone(Inner)
	end
	return Out
end

local function Newest(Held: Slot): Version?
	return Held.Versions[#Held.Versions]
end

local function Commit(self: Disk, Key: string, Text: string?, Stored: any, Deleted: boolean): Version
	local Held = Slot(self, Key)
	self.Ticket += 1

	local Fresh: Version = {
		Text = Text,
		Value = Stored,
		Written = Time.Read(),
		Deleted = Deleted,
		Label = tostring(self.Ticket),
	}
	Held.Live = Text
	table.insert(Held.Versions, Fresh)

	local Spare = #Held.Versions - KEEP_VERSIONS
	if Spare > 0 then
		Held.Versions = table.move(Held.Versions, Spare + 1, #Held.Versions, 1, {})
	end

	self.Writes += 1
	return Fresh
end

local function Save(self: Disk, Key: string, Value: any): Version
	local Text = Encode(self, Value)
	return Commit(self, Key, Text, Decode(self, Text), false)
end

local function Current(self: Disk, Key: string): (any, Info?)
	local Held = Slot(self, Key)
	local Mark = Newest(Held)
	if Held.Live == nil or Mark == nil then
		return nil, nil
	end
	return Clone(Mark.Value), Stamped(Mark.Label, Mark.Written)
end

local PAGE_LIMIT = 100

local function Paged(Rows: { any }, Size: number, Field: string?): any
	local Held = math.clamp(Size, 1, PAGE_LIMIT)
	local Book = { At = 1, IsFinished = true, Cursor = "" }

	local function Edge()
		Book.IsFinished = Book.At + Held > #Rows

		if Field == nil then
			Book.Cursor = ""
			return
		end
		local Row = Rows[math.min(Book.At + Held - 1, #Rows)]
		local Mark = if type(Row) == "table" then (Row :: { [string]: any })[Field] else nil
		Book.Cursor = if type(Mark) == "string" then Mark else ""
	end

	function Book.GetCurrentPage(_: any): { any }
		return table.move(Rows, Book.At, math.min(Book.At + Held - 1, #Rows), 1, {})
	end

	function Book.AdvanceToNextPageAsync(_: any)
		if Book.IsFinished then
			error("SimulationV2 disk: there are no pages left to advance to", 0)
		end
		Book.At += Held
		Edge()
	end

	Edge()
	return Book
end

local function Open(self: Disk, Name: string): any
	local Store = {}
	local function At(Key: string): string
		return Named(Name, Key)
	end

	function Store.GetAsync(_: any, Key: string): (any, Info?)
		Checked(Key)
		Spend(self, Enum.DataStoreRequestType.GetAsync)
		Pause(self)
		self.Reads += 1
		return Current(self, At(Key))
	end

	function Store.UpdateAsync(_: any, Key: string, Transform: (any, Info?) -> any): (any, Info?)
		Checked(Key)
		Spend(self, Enum.DataStoreRequestType.UpdateAsync)
		Pause(self)

		for _ = 1, CONFLICT_LIMIT do
			local Before = Newest(Slot(self, At(Key)))
			local Was, Info = Current(self, At(Key))

			local Ran, Next = NoYield.Try(Transform, Was, Info)
			if not Ran then
				return nil, nil
			end
			if Next == nil then
				return nil, nil
			end

			local After = Newest(Slot(self, At(Key)))
			if After ~= Before then
				self.Conflicts += 1
				Pause(self)
				continue
			end

			local Fresh = Save(self, At(Key), Next)
			return Clone(Fresh.Value), Stamped(Fresh.Label, Fresh.Written)
		end

		error(`SimulationV2 disk: UpdateAsync on '{Key}' could not settle, too many conflicting writes`, 0)
	end

	function Store.RemoveAsync(_: any, Key: string): (any, Info?)
		Checked(Key)
		Spend(self, Enum.DataStoreRequestType.SetIncrementAsync)
		Pause(self)

		local Was, Info = Current(self, At(Key))
		if Info == nil then
			return nil, nil
		end
		Commit(self, At(Key), nil, nil, true)
		return Was, Info
	end

	function Store.GetVersionAsync(_: any, Key: string, Version: string): (any, Info?)
		Checked(Key)
		Spend(self, Enum.DataStoreRequestType.GetVersionAsync)
		Pause(self)

		for _, Mark in Slot(self, At(Key)).Versions do
			if Mark.Label == Version then
				return Clone(Mark.Value), Stamped(Mark.Label, Mark.Written)
			end
		end
		error(`SimulationV2 disk: no version '{Version}' for key '{Key}'`, 0)
	end

	function Store.ListVersionsAsync(_: any, Key: string, Direction: Enum.SortDirection?, _Least: number?, _Most: number?, Size: number?): any
		Checked(Key)
		Spend(self, Enum.DataStoreRequestType.ListAsync)
		Pause(self)

		local Rows: { any } = {}
		for _, Mark in Slot(self, At(Key)).Versions do
			table.insert(Rows, { Version = Mark.Label, CreatedTime = Mark.Written * 1000, IsDeleted = Mark.Deleted })
		end
		if Direction ~= Enum.SortDirection.Ascending then
			local Flipped: { any } = {}
			for Index = #Rows, 1, -1 do
				table.insert(Flipped, Rows[Index])
			end
			Rows = Flipped
		end

		return Paged(Rows, Size or 25, nil)
	end

	function Store.ListKeysAsync(_: any, Prefix: string?, Size: number?, Cursor: string?, Hiding: boolean?): any
		Spend(self, Enum.DataStoreRequestType.ListAsync)
		Pause(self)

		local Wanted = Prefix or ""
		local After = if type(Cursor) == "string" then Cursor else ""
		local Front = Name .. SPLIT
		local Listed: { string } = {}
		for Held, Slot in self.Slots do
			if string.sub(Held, 1, #Front) ~= Front then
				continue
			end
			local Key = string.sub(Held, #Front + 1)
			if Slot.Live == nil and Hiding == true then
				continue
			end
			if Wanted ~= "" and string.sub(Key, 1, #Wanted) ~= Wanted then
				continue
			end
			if After ~= "" and Key <= After then
				continue
			end
			table.insert(Listed, Key)
		end
		table.sort(Listed)

		local Rows: { any } = {}
		for _, Key in Listed do
			table.insert(Rows, { KeyName = Key })
		end
		return Paged(Rows, Size or 50, "KeyName")
	end

	return Store
end

local function Peek(self: Disk, Name: string, Key: string): any
	local Held = Slot(self, Named(Name, Key))
	local Mark = Newest(Held)
	if Held.Live == nil or Mark == nil then
		return nil
	end
	return Clone(Mark.Value)
end

local function Stamp(self: Disk, Name: string, Key: string): number?
	local Held = Slot(self, Named(Name, Key))
	local Mark = Newest(Held)
	if Held.Live == nil or Mark == nil then
		return nil
	end
	return Mark.Written
end

local function Keys(self: Disk, Name: string): { string }
	local Front = Name .. SPLIT
	local Found: { string } = {}
	for Held, Slot in self.Slots do
		if Slot.Live ~= nil and string.sub(Held, 1, #Front) == Front then
			table.insert(Found, string.sub(Held, #Front + 1))
		end
	end
	table.sort(Found)
	return Found
end

return table.freeze({
	New = New,
	Open = Open,
	Peek = Peek,
	Stamp = Stamp,
	Keys = Keys,
	Pause = Pause,
	Shut = Shut,
	MAX_KEY = MAX_KEY,
	MAX_VALUE = MAX_VALUE,
	KEEP_VERSIONS = KEEP_VERSIONS,
})
