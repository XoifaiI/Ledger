--!strict
--!optimize 2

--[=[
	GameValues: the values in what the core says, as the game is handed them (Answers.md 4 to 6): frozen deep copies,
	public name handles, a Short's reason and a key in the game's form. Table answers and a Short's reason are
	checked for their promised shape; any other throws. An Identity that is not a table reads as none.

	Return type: A plain table of functions.
	Example usage:
		local Shown = GameValues.CopyForGame(Given.State)
--]=]

local Cache = require("../Reading/Cache")
local CutShapes = require("../Cuts/Shapes")
local Events = require("../Events")
local Fates = require("../Stored/Items/Fates")
local Guards = require("../Judging/Guards")
local Handles = require("./Handles")
local HotShapes = require("../Hot/Shapes")
local Keys = require("./Validate/Keys")
local Names = require("../Encoding/Names")
local Record = require("../Constants/Record")
local Shapes = require("../Shapes")
local Types = require("../Types")
local Value = require("../Stored/Value")
local WritingAnswers = require("../Writing/Answers")

type AskedName = Shapes.AskedName
type CutAnswer = CutShapes.CutAnswer
type Emitted = WritingAnswers.Emitted
type FateOp = Types.FateOp
type LossRecords = Types.LossRecords
type Fields = Value.Fields
type GivenName = Events.GivenName
type Closed = Types.Closed
type HoldHandle = HotShapes.HoldHandle
type QuantityDeclaration = HotShapes.QuantityDeclaration
type PartReason = Fates.PartReason
type Took = HotShapes.Took
type Identity = Types.Identity
type InfoKey = Types.InfoKey
type KeysMode = Types.KeysMode
type Name = Types.Name
type ShortReason = Types.ShortReason
type StoreKey = Names.StoreKey

local ApplyNotATable = "GameValues: the core answered Apply true with a value that is not a table. "
	.. "An Apply's true must carry its name"
local CutNotATable = "GameValues: the core answered a cut true with a value that is not a table. "
	.. "A cut's true must carry its name"
local FateNotATable = "GameValues: the core emitted a fate that is not a table. A fate must be a table"
local FateOpNotATable = "GameValues: the core emitted a fate whose op terms are not a table. "
	.. "A fate's op must be a table"
local NotALegStore =
	"GameValues: a Tx answer names a key of a store that none of its legs is in. The core names a leg's key"
local LossesNotATable = "GameValues: the core answered Losses with a value that is not a table. "
	.. "Losses must answer the key's loss records"
local TookNotATable = "GameValues: the core answered a Take true with a value that is not a table. "
	.. "A Take's true must carry the part it took from"
local HoldNotATable = "GameValues: the core answered a Hold true with a value that is not a table. "
	.. "A Hold's true must carry its handle"
local ClosedNotATable = "GameValues: the core answered a Close true with a value that is not a table. "
	.. "A Close's true must carry the parts removed, left and missing"
local ConfirmNotATable = "GameValues: the core answered a Confirm true with a value that is not a table. "
	.. "A Confirm's true must carry the part it took from"
local IdNotATable = "GameValues: the core answered Id with a name that is not a table. Id must answer a drawn name"

local ShortReasons = Fates.ShortReason

local ShortReasonOfPart: { [PartReason]: ShortReason } = {
	[ShortReasons.Free] = ShortReasons.Free,
	[ShortReasons.Held] = ShortReasons.Held,
	[ShortReasons.Holds] = ShortReasons.Holds,
	[ShortReasons.Gone] = ShortReasons.Gone,
}

local function NotAShortReason(Reason: PartReason?): string
	return `GameValues: the core answered Short with the reason {Reason}, which no Short gives. `
		.. "A Short's reason is Free, Held, Holds or Gone"
end

local function CopyForGame(Value: unknown): unknown
	if type(Value) ~= "table" then
		return Value
	end
	local Copy = Guards.DeepCopy(Value :: Fields)
	Guards.DeepFreeze(Copy)
	return Copy
end

local function IdentityForGame(Held: Identity?): Identity?
	local Copy = CopyForGame(Held)
	if type(Copy) ~= "table" then
		return nil
	end
	return Copy :: Identity
end

local function EmittedForGame(Fate: Emitted): Emitted
	local Copy = CopyForGame(Fate)
	if type(Copy) ~= "table" then
		error(FateNotATable, 0)
	end
	return Copy :: Emitted
end

local function FateOpForGame(OpKind: string, Terms: unknown): FateOp
	if type(Terms) ~= "table" then
		error(FateOpNotATable, 0)
	end
	local Copy = Guards.DeepCopy(Terms :: Fields)
	Copy.Kind = OpKind
	Guards.DeepFreeze(Copy)
	return Copy :: FateOp
end

local function NameForGame(Given: GivenName?): Name?
	if Given == nil then
		return nil
	end
	return Handles.PublicNameOf(Given)
end

local function RecordsForGame(Value: unknown): LossRecords
	local Copy = CopyForGame(Value)
	if type(Copy) ~= "table" then
		error(LossesNotATable, 0)
	end
	return Copy :: LossRecords
end

local function CutValueOf(Value: unknown): CutAnswer
	if type(Value) ~= "table" then
		error(CutNotATable, 0)
	end
	return Value :: CutAnswer
end

local function ApplyNameOf(Value: unknown): AskedName
	if type(Value) ~= "table" then
		error(ApplyNotATable, 0)
	end
	return Value :: AskedName
end

local function DrawnOf(Value: unknown): AskedName
	if type(Value) ~= "table" then
		error(IdNotATable, 0)
	end
	return Value :: AskedName
end

local function IsGameKey(Key: StoreKey?): boolean
	return Key ~= nil and Cache.KindOfKey(Key) == Record.KeyKind.Game
end

local function InfoKeyOf(Key: StoreKey?, KeysByStore: { [string]: KeysMode }): InfoKey?
	if Key == nil or not IsGameKey(Key) then
		return nil
	end
	local Mode = KeysByStore[Key.Store]
	if Mode == nil then
		error(NotALegStore, 0)
	end
	local Made: InfoKey = { Store = Key.Store, Key = Keys.GameKeyOf(Mode, Key) }
	return table.freeze(Made)
end

local function TookForGame(Value: unknown): Took
	local Copy = CopyForGame(Value)
	if type(Copy) ~= "table" then
		error(TookNotATable, 0)
	end
	return Copy :: Took
end

local function HoldHandleOf(Value: unknown, Quantity: QuantityDeclaration): HoldHandle
	local Copy = CopyForGame(Value)
	if type(Copy) ~= "table" then
		error(HoldNotATable, 0)
	end
	return Handles.HoldOf(Copy :: HoldHandle, Quantity)
end

local function ClosedForGame(Value: unknown): Closed
	local Copy = CopyForGame(Value)
	if type(Copy) ~= "table" then
		error(ClosedNotATable, 0)
	end
	return Copy :: Closed
end

local function ConfirmedOf(Value: unknown): Took
	if type(Value) ~= "table" then
		error(ConfirmNotATable, 0)
	end
	return Value :: Took
end

local function ShortReasonOf(Reason: PartReason?): ShortReason
	local Short = if Reason == nil then nil else ShortReasonOfPart[Reason]
	if Short == nil then
		error(NotAShortReason(Reason), 0)
	end
	return Short
end

return {
	CopyForGame = CopyForGame,
	IdentityForGame = IdentityForGame,
	EmittedForGame = EmittedForGame,
	FateOpForGame = FateOpForGame,
	NameForGame = NameForGame,
	RecordsForGame = RecordsForGame,
	CutValueOf = CutValueOf,
	ApplyNameOf = ApplyNameOf,
	DrawnOf = DrawnOf,
	IsGameKey = IsGameKey,
	InfoKeyOf = InfoKeyOf,
	TookForGame = TookForGame,
	HoldHandleOf = HoldHandleOf,
	ClosedForGame = ClosedForGame,
	ConfirmedOf = ConfirmedOf,
	ShortReasonOf = ShortReasonOf,
}
