--!strict
--!optimize 2

--[=[
	Answers: the core's Answer as each method's public returns (Answers.md 4 to 6), the one place they are made. A write
	gives Ok, its value or reason, and on a no a frozen Info; a read gives its value, or nil and the reason. Info.Key
	names a Tx or Take's deciding game key, elsewhere Missing's. GameValues makes the values.

	Return type: A plain table of functions.
	Example usage:
		local Ok, Result, Info = Answers.WriteAnswer(Runner.Call(Call):Wait())
--]=]

local Events = require("../Events")
local Fates = require("../Stored/Items/Fates")
local GameValues = require("./GameValues")
local Handles = require("./Handles")
local HotShapes = require("../Hot/Shapes")
local Names = require("../Encoding/Names")
local Reasons = require("../Constants/Reasons")
local Types = require("../Types")
local WritingAnswers = require("../Writing/Answers")

type Answer = Events.Answer
type FateEmission = WritingAnswers.FateEmission
type LossRecords = Types.LossRecords
type Closed = Types.Closed
type HoldHandle = HotShapes.HoldHandle
type QuantityDeclaration = HotShapes.QuantityDeclaration
type PartReason = Fates.PartReason
type Took = HotShapes.Took
type Applied = Types.Applied
type Cut = Types.Cut
type DidApplyInfo = Types.DidApplyInfo
type Fate = Types.Fate
type Identity = Types.Identity
type Info = Types.Info
type KeysMode = Types.KeysMode
type InfoKey = Types.InfoKey
type Name = Types.Name
type OpId = Types.OpId
type Reason = Types.Reason
type ShortReason = Types.ShortReason
type StoreKey = Names.StoreKey

type Outcome = Types.Future<boolean, Reason?>

type InfoFields = {
	State: unknown,
	Identity: Identity?,
	Key: InfoKey?,
	ShortReason: ShortReason?,
	Name: Name?,
	Outcome: Outcome?,
}

local DecidingReasons: { [Reason]: true } = {
	[Reasons.Refused] = true,
	[Reasons.Full] = true,
	[Reasons.Behind] = true,
	[Reasons.Missing] = true,
}

local RefusingReasons: { [Reason]: true } = {
	[Reasons.Refused] = true,
	[Reasons.Full] = true,
}

local NoInfo: Info = table.freeze({})
local NotQueued: DidApplyInfo = table.freeze({})
local Queued: DidApplyInfo = table.freeze({ IsQueued = true :: true })

local CopyForGame = GameValues.CopyForGame
local IdentityForGame = GameValues.IdentityForGame
local NameForGame = GameValues.NameForGame
local InfoKeyOf = GameValues.InfoKeyOf

local function InfoOf(Fields: InfoFields): Info
	return table.freeze(Fields)
end

local function DecidingKeyOf(Given: Answer, KeysByStore: { [string]: KeysMode }): InfoKey?
	if Given.Kind ~= "Failed" or not DecidingReasons[Given.Reason] then
		return nil
	end
	return InfoKeyOf(Given.Key, KeysByStore)
end

local function KeyOfMissing(Given: Answer, KeysByStore: { [string]: KeysMode }): InfoKey?
	if Given.Kind ~= "Failed" or Given.Reason ~= Reasons.Missing then
		return nil
	end
	return InfoKeyOf(Given.Key, KeysByStore)
end

local function RefusedStateOf(Given: Answer): unknown
	if Given.Kind ~= "Failed" or not RefusingReasons[Given.Reason] or not GameValues.IsGameKey(Given.Key) then
		return nil
	end
	return CopyForGame(Given.State)
end

local function ShortOf(Reason: Reason, Short: PartReason?): ShortReason?
	if Reason ~= Reasons.Short then
		return nil
	end
	return GameValues.ShortReasonOf(Short)
end

local function Plain(Given: Answer): (boolean, Reason?, Info?)
	if Given.Kind == "Succeeded" then
		return true, nil, nil
	end
	return false, Given.Reason, NoInfo
end

local function ReadAnswer(Given: Answer): (unknown, Reason?)
	if Given.Kind == "Succeeded" then
		return CopyForGame(Given.Value), nil
	end
	return nil, Given.Reason
end

local function PeekAnswer(Given: Answer): (unknown, Reason?, Info?)
	if Given.Kind == "Succeeded" then
		return CopyForGame(Given.Value), nil, nil
	end
	return nil, Given.Reason, InfoOf({ State = CopyForGame(Given.State) })
end

local function IdAnswer(Given: Answer): (OpId?, Reason?)
	if Given.Kind ~= "Succeeded" then
		return nil, Given.Reason
	end
	return Handles.OpIdOf(GameValues.DrawnOf(Given.Value)), nil
end

local function DidApplyAnswer(Given: Answer): (unknown, Reason?, DidApplyInfo?)
	if Given.Kind == "Succeeded" then
		return CopyForGame(Given.Value), nil, nil
	end
	return nil, Given.Reason, NotQueued
end

local function QueuedAnswer(): (nil, Reason, DidApplyInfo)
	return nil, Reasons.Unresolved, Queued
end

local function WriteAnswer(Given: Answer): (boolean, Reason?, Info?)
	if Given.Kind == "Succeeded" then
		return true, nil, nil
	end
	return false, Given.Reason, InfoOf({ State = CopyForGame(Given.State), Identity = IdentityForGame(Given.Identity) })
end

local function CommitAnswer(Given: Answer): (boolean, unknown, Info?)
	if Given.Kind == "Succeeded" then
		return true, CopyForGame(Given.Value), nil
	end
	return WriteAnswer(Given)
end

local function ApplyAnswer(Given: Answer, CallId: number, Key: StoreKey): (boolean, Applied | Reason, Info?)
	if Given.Kind ~= "Succeeded" then
		return false, Given.Reason, NoInfo
	end
	return true, Handles.AppliedOf(GameValues.ApplyNameOf(Given.Value), CallId, Key), nil
end

local function CutAnswer(Given: Answer): (boolean, Cut | Reason, Info?)
	if Given.Kind == "Succeeded" then
		local Done = GameValues.CutValueOf(Given.Value)
		local Losses = Done.Namings
		local Made: Cut = {
			Name = Handles.PublicNameOf(Done.Name),
			Losses = if Losses == nil then nil else GameValues.RecordsForGame(Losses),
		}
		return true, table.freeze(Made), nil
	end
	return false, Given.Reason, InfoOf({ Name = NameForGame(Given.Name), Identity = IdentityForGame(Given.Identity) })
end

local function LossesAnswer(Given: Answer): (LossRecords?, Reason?)
	if Given.Kind == "Succeeded" then
		return GameValues.RecordsForGame(Given.Value), nil
	end
	return nil, Given.Reason
end

local function TxAnswer(Given: Answer, KeysByStore: { [string]: KeysMode }): (boolean, Reason?, Info?)
	if Given.Kind == "Succeeded" then
		return true, nil, nil
	end
	return false,
		Given.Reason,
		InfoOf({
			State = RefusedStateOf(Given),
			Identity = IdentityForGame(Given.Identity),
			Key = DecidingKeyOf(Given, KeysByStore),
			Name = NameForGame(Given.Name),
		})
end

local function MoveAnswer(Given: Answer, KeysByStore: { [string]: KeysMode }): (boolean, Reason?, Info?)
	if Given.Kind == "Succeeded" then
		return true, nil, nil
	end
	return false,
		Given.Reason,
		InfoOf({
			Identity = IdentityForGame(Given.Identity),
			Key = KeyOfMissing(Given, KeysByStore),
			Name = NameForGame(Given.Name),
		})
end

local function DepositAnswer(Given: Answer, KeysByStore: { [string]: KeysMode }): (boolean, Reason?, Info?)
	if Given.Kind == "Succeeded" then
		return true, nil, nil
	end
	return false,
		Given.Reason,
		InfoOf({
			State = CopyForGame(Given.State),
			Identity = IdentityForGame(Given.Identity),
			Key = KeyOfMissing(Given, KeysByStore),
			Name = NameForGame(Given.Name),
		})
end

local function TakeAnswer(Given: Answer, KeysByStore: { [string]: KeysMode }): (boolean, Took | Reason, Info?)
	if Given.Kind == "Succeeded" then
		return true, GameValues.TookForGame(Given.Value), nil
	end
	return false,
		Given.Reason,
		InfoOf({
			State = RefusedStateOf(Given),
			ShortReason = ShortOf(Given.Reason, Given.ShortReason),
			Key = DecidingKeyOf(Given, KeysByStore),
			Identity = IdentityForGame(Given.Identity),
			Name = NameForGame(Given.Name),
		})
end

local function HoldAnswer(Given: Answer, Quantity: QuantityDeclaration): (boolean, HoldHandle | Reason, Info?)
	if Given.Kind == "Succeeded" then
		return true, GameValues.HoldHandleOf(Given.Value, Quantity), nil
	end
	return false, Given.Reason, InfoOf({ ShortReason = ShortOf(Given.Reason, Given.ShortReason) })
end

local function GatherAnswer(Given: Answer, KeysByStore: { [string]: KeysMode }): (boolean, Reason?, Info?)
	if Given.Kind == "Succeeded" then
		return true, nil, nil
	end
	return false,
		Given.Reason,
		InfoOf({
			ShortReason = ShortOf(Given.Reason, Given.ShortReason),
			Key = KeyOfMissing(Given, KeysByStore),
			Identity = IdentityForGame(Given.Identity),
			Name = NameForGame(Given.Name),
		})
end

local function ConfirmAnswer(Given: Answer, KeysByStore: { [string]: KeysMode }): (boolean, (number | Reason)?, Info?)
	if Given.Kind == "Succeeded" then
		return true, GameValues.ConfirmedOf(Given.Value).Value, nil
	end
	return false,
		Given.Reason,
		InfoOf({
			ShortReason = ShortOf(Given.Reason, Given.ShortReason),
			Key = KeyOfMissing(Given, KeysByStore),
			Identity = IdentityForGame(Given.Identity),
		})
end

local function CloseAnswer(Given: Answer): (boolean, Closed | Reason, Info?)
	if Given.Kind == "Succeeded" then
		return true, GameValues.ClosedForGame(Given.Value), nil
	end
	return false, Given.Reason, NoInfo
end

local function FateOf(Emission: FateEmission, Handle: Applied): Fate
	local Made: Fate = {
		Applied = Handle,
		Fate = GameValues.EmittedForGame(Emission.Fate),
		Op = GameValues.FateOpForGame(Emission.OpKind, Emission.Terms),
	}
	return table.freeze(Made)
end

local function WithOutcome(Given: Info?, Outcome: Outcome?): Info?
	if Given == nil or Outcome == nil then
		return Given
	end
	local Fields: InfoFields = {
		State = Given.State,
		Identity = Given.Identity,
		Key = Given.Key,
		ShortReason = Given.ShortReason,
		Name = Given.Name,
		Outcome = Outcome,
	}
	return InfoOf(Fields)
end

local function FollowValue(Given: Answer): unknown
	if Given.Kind == "Succeeded" then
		return CopyForGame(Given.Value)
	end
	return Given.Reason
end

return {
	Plain = Plain,
	ReadAnswer = ReadAnswer,
	PeekAnswer = PeekAnswer,
	IdAnswer = IdAnswer,
	DidApplyAnswer = DidApplyAnswer,
	QueuedAnswer = QueuedAnswer,
	WriteAnswer = WriteAnswer,
	CommitAnswer = CommitAnswer,
	ApplyAnswer = ApplyAnswer,
	CutAnswer = CutAnswer,
	LossesAnswer = LossesAnswer,
	TxAnswer = TxAnswer,
	MoveAnswer = MoveAnswer,
	DepositAnswer = DepositAnswer,
	TakeAnswer = TakeAnswer,
	HoldAnswer = HoldAnswer,
	GatherAnswer = GatherAnswer,
	ConfirmAnswer = ConfirmAnswer,
	CloseAnswer = CloseAnswer,
	FateOf = FateOf,
	WithOutcome = WithOutcome,
	FollowValue = FollowValue,
}
