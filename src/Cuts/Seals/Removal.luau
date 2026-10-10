--!strict
--!optimize 2

--[=[
	Removal: a stamper's one RemoveAsync per seal it stamped, within RemoveSend of rt (cuts sheet 8.5, 8.2 sealed,
	transaction sheet 18.4). A removal sent is kept by key, rt and seal name (an erase's seal and a proof's apart) until
	SealAge old, so no helper stamp follows, and dropped at a later removal or when a write lands a seal of the same
	name and rt again (a new seal is owed its removal). Nothing goes past the close deadline.

	Return type: A plain table with SealText, IsWithinRemoveSend, WasSent, ForgetSent, SendRemoval, RemoveProofSeals
	and OnRemoved.
	Example usage:
		Removal.SendRemoval(State, Key, Sealed.Name, Sealed.RemovalStamp, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local CutState = require("../State")
local DueTimes = require("../../DueTimes")
local Events = require("../../Events")
local Format = require("../../Encoding/Format")
local Names = require("../../Encoding/Names")
local Shapes = require("../../Shapes")
local Sorted = require("../../Sorted")
local Transaction = require("../../Constants/Transaction")
local TxState = require("../../Tx/State")

type Command = Events.Command
type Name = Names.Name
type StoreKey = Names.StoreKey
type Limits = Shapes.Limits
type State = Composed.State
type Purpose = CutState.Purpose
type Verify = TxState.Verify

local NameStartBytes = 64
local StampSeparator = ":"

local ProofSealName: Name = {
	Kind = "Drawn",
	Server = Transaction.ProveName.Server,
	Counter = Transaction.ProveName.Counter,
}

local function SealText(Key: StoreKey, SealName: Name, RemovalStamp: number): string
	local Out = Format.NewWriter(NameStartBytes)
	Names.WriteName(Out, SealName)
	return Names.KeyText(Key) .. Format.ToString(Out) .. StampSeparator .. tostring(RemovalStamp)
end

local function IsWithinRemoveSend(RemovalStamp: number, Clock: number, Limits: Limits): boolean
	return Clock - RemovalStamp <= Limits.RemoveSend
end

local function ForgetOld(State: State, Clock: number, Limits: Limits)
	local Cuts = State.Cuts
	for _, Sent in DueTimes.TakeDue(Cuts.RemovedTimes, Clock - Limits.SealAge) do
		if Cuts.Removed[Sent.Text] ~= Sent.RemovalStamp then
			continue
		end
		if Clock - Sent.RemovalStamp > Limits.SealAge then
			Cuts.Removed[Sent.Text] = nil
		else
			DueTimes.Add(Cuts.RemovedTimes, Sent, Sent.RemovalStamp)
		end
	end
end

local function WasSent(State: State, Key: StoreKey, SealName: Name, RemovalStamp: number): boolean
	return State.Cuts.Removed[SealText(Key, SealName, RemovalStamp)] ~= nil
end

local function ForgetSent(State: State, Key: StoreKey, SealName: Name, RemovalStamp: number)
	State.Cuts.Removed[SealText(Key, SealName, RemovalStamp)] = nil
end

local function SendRemoval(
	State: State,
	Key: StoreKey,
	SealName: Name,
	RemovalStamp: number,
	Clock: number,
	Commands: { Command }
)
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Text = SealText(Key, SealName, RemovalStamp)
	local Limits = Cache.StoreOf(State.Server, Key).Setup.Limits
	ForgetOld(State, Clock, Limits)
	if State.Cuts.Removed[Text] ~= nil or not IsWithinRemoveSend(RemovalStamp, Clock, Limits) then
		return
	end
	State.Cuts.Removed[Text] = RemovalStamp
	DueTimes.Add(State.Cuts.RemovedTimes, { Text = Text, RemovalStamp = RemovalStamp }, RemovalStamp)
	local Purpose: Purpose = { Kind = "Removal", Key = Key, RemovalStamp = RemovalStamp }
	local Remove: Command =
		{ Kind = "Remove", RequestId = CutState.NewRequest(State.Server, State.Cuts, Purpose), Target = Key }
	table.insert(Commands, Remove)
end

local function RemoveProofSeals(State: State, Verification: Verify, Clock: number, Commands: { Command })
	for _, Text in Sorted.SortedTexts(Verification.Seals) do
		local Landed = Verification.Seals[Text]
		SendRemoval(State, Landed.Key, ProofSealName, Landed.RemovalStamp, Clock, Commands)
	end
end

local function OnRemoved(State: State, RequestId: number, IsOk: boolean, Clock: number): StoreKey?
	local Heard = State.Cuts.Purposes[RequestId]
	State.Cuts.Purposes[RequestId] = nil
	if Heard == nil then
		return nil
	end
	ForgetOld(State, Clock, Cache.StoreOf(State.Server, Heard.Key).Setup.Limits)
	if not IsOk or Heard.Kind ~= "Removal" or Closing.IsPastDeadline(State.Sessions, Clock) then
		return nil
	end
	return Heard.Key
end

return {
	SealText = SealText,
	IsWithinRemoveSend = IsWithinRemoveSend,
	WasSent = WasSent,
	ForgetSent = ForgetSent,
	SendRemoval = SendRemoval,
	RemoveProofSeals = RemoveProofSeals,
	OnRemoved = OnRemoved,
}
