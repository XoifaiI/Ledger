--!strict
--!optimize 2

--[=[
	Keys: Object. The calls a store makes on one key: an edit, the reads, and what the key still
	holds.

	Every read runs Peek, so it goes through the shown table. What a read finds is passed on: the
	work room and the gate to this server's touches, and the key's incarnation to its queue. Reserved
	refuses a key under a prefix Ledger keeps for itself, the shards of totals and the parts of split
	quantities. A naming gives its amounts by the name of each money field. A field this build does
	not know is named # and its index. An Owner is what a feature needs of a store, and a Store is
	one.

	Return type: The Keys module, and the Owner and Naming types.
	Example usage:
		local State = Keys.Peek(Owner, "42")
--]=]

local Alphabet = require("../Encode/Alphabet")
local Answer = require("../Core/Answer")
local Book = require("../Record/Book")
local Clock = require("../Machine/Clock")
local DidApply = require("../Calls/DidApply")
local Errors = require("../Core/Errors")
local Limits = require("../Core/Constants/Limits")
local Parts = require("../Record/Parts")
local Peek = require("../Calls/Peek")
local Queue = require("../Record/Queue")
local Resettle = require("../Calls/Resettle")
local Runner = require("../Machine/Runner")
local Runtime = require("./Runtime")
local Shards = require("../Record/Shards")
local Types = require("../Record/Types")
local View = require("../Record/View")
local Windows = require("../Core/Constants/Windows")

type Answer = Answer.Answer
type Reply = Queue.Reply
type State = { [string]: any }

export type Owner = {
	read Name: string,
	read Build: Types.Build,
	read MustExist: boolean,
}

export type Naming = {
	read Cause: "Reset" | "Erase" | "Returned" | "Orphan" | "Folded",
	read Name: string?,
	read At: number,
	read Amounts: { [string]: number },
	read Count: number?,
	read Key: string?,
}

type Cause = "Reset" | "Erase" | "Returned" | "Orphan"

local CAUSES: { [number]: Cause } = {
	[Book.Cause.Reset] = "Reset",
	[Book.Cause.Erase] = "Erase",
	[Book.Cause.Returned] = "Returned",
	[Book.Cause.Orphan] = "Orphan",
}

local RESERVED = { Shards.PREFIX, Parts.PREFIX }

local Shared = Runtime.Shared

local function FieldName(Owner: Owner, Index: number): string
	return Owner.Build.Money[Index] or `#{Index}`
end

local Keys = {}

local function Show(Owner: Owner, Key: string | number, Machine: typeof(Peek.Cached)): State | Answer
	local Found = Keys.Read(Owner, Key, Machine)
	return if type(Found) == "table" then Found.State else Found
end

function Keys.Reserved(Key: string | number, Depth: number?)
	for _, Prefix in RESERVED do
		if type(Key) == "string" and string.sub(Key, 1, #Prefix) == Prefix then
			Errors.Misuse(`the key {Key} starts with {Prefix}, which Ledger keeps for itself`, 1 + (Depth or 0))
		end
	end
end

function Keys.Ref(Owner: Owner, Key: string | number): Book.Ref
	return { Store = Owner.Name, Key = tostring(Key) }
end

function Keys.Read(Owner: Owner, Key: string | number, Machine: typeof(Peek.Cached)): View.View | Answer
	local At = Keys.Ref(Owner, Key)
	local Found = Runner.Run(Machine, Peek.Context(At, Owner.Build, Shared.Shown), Shared.Places):Wait()
	if type(Found) == "table" then
		Shared:Touch(At, Found.Work, Found.Gate)
		Shared:Learn(At, Found.Id or "")
	elseif Found == Answer.Missing then
		Shared:Learn(At, false)
	end
	return Found or Answer.Unresolved
end

function Keys.Peek(Owner: Owner, Key: string | number): State | Answer
	return Show(Owner, Key, Peek.Cached)
end

function Keys.Fresh(Owner: Owner, Key: string | number): State | Answer
	return Show(Owner, Key, Peek.Fresh)
end

function Keys.Pending(Owner: Owner, Key: string | number): { [string]: Book.Work } | Answer
	local Found = Keys.Read(Owner, Key, Peek.Cached)
	return if type(Found) == "table" then Found.Work else Found
end

function Keys.Resettle(Owner: Owner, Key: string | number): Reply
	local Context = Resettle.Context(Keys.Ref(Owner, Key), Owner.Build, Shared.Shown, Clock.Now())
	return Runner.Run(Resettle.Machine, Context, Shared.Places):Wait() or Answer.Unresolved
end

function Keys.DidApply(Of: typeof(DidApply.Reading), Context: DidApply.Context): boolean | Answer
	local Said = Runner.Run(Of, Context, Shared.Places):Wait()
	return if Said == nil then Answer.Unresolved else Said
end

function Keys.Edit(Owner: Owner, Key: string | number, Asked: Queue.Asked): Reply
	return (Shared:Send(Shared:SaveFor(Keys.Ref(Owner, Key)), Asked))
end

function Keys.Namings(Owner: Owner, Events: { Book.Event }, Slots: { Book.Slot }): { Naming }
	local Found: { Naming } = {}
	for _, Event in Events do
		local Amounts: { [string]: number } = {}
		for Index, Amount in Event.Amounts do
			Amounts[FieldName(Owner, Index)] = Amount
		end
		local Other = Event.Ref
		table.insert(Found, {
			Cause = CAUSES[Event.Cause],
			Name = if string.sub(Event.Name, 1, 1) == Book.DRAWN then nil else Event.Name,
			At = Event.Stamp + Limits.EPOCH,
			Amounts = Amounts,
			Key = if Other then Book.Address(Other) else nil,
		})
	end
	for _, Slot in Slots do
		local Amounts: { [string]: number } = {}
		for Index, Sum in Slot.Sums do
			Amounts[FieldName(Owner, Index)] = Sum.High * Alphabet.LIMB + Sum.Low
		end
		local Folded: Naming = { Cause = "Folded", At = Slot.Period * Windows.FOLD_SPAN + Limits.EPOCH, Amounts = Amounts, Count = Slot.Count }
		table.insert(Found, Folded)
	end
	return Found
end

function Keys.Losses(Owner: Owner, Key: string | number): { Naming } | Answer
	local Found = Keys.Read(Owner, Key, Peek.Cached)
	if type(Found) ~= "table" then
		return Found
	end
	return Keys.Namings(Owner, Found.Events or {}, Found.Slots or {})
end

return Keys
