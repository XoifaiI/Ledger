--!strict
--!optimize 2

--[=[
	Fence: the requests a walk sends besides its steps (hot keys sheet H5 P6, P7, H9). A fence on a part is an end
	only request, Fence(x.p, 1, final), kept on the walk; a resend keeps the first send time. A read is one Get of a
	part the view lacks, joined while younger than B_op.

	Return type: A plain table with SendFence, ResendFence and ReadLackingParts.
	Example usage:
		Fence.SendFence(State, Walking, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Ends = require("../../Tx/Legs/Ends")
local Events = require("../../Events")
local HotShapes = require("../Shapes")
local HotState = require("../State")
local Names = require("../../Encoding/Names")
local TxShapes = require("../../Tx/Shapes")
local View = require("./View")

type Command = Events.Command
type FenceEnd = TxShapes.FenceEnd
type QuantityDeclaration = HotShapes.QuantityDeclaration
type HotPurpose = HotState.Purpose
type HotWalk = HotState.Walk
type State = Composed.State

type ReadingCall = {
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Quantity: QuantityDeclaration,
	read Fraction: number,
}

local FirstAttempt = 1

local ModuleName = "Fence"
local NoFenceOut = `{ModuleName}: this call is never made. A fence is resent only while the walk has one out.`

local function IssueFence(State: State, Walking: HotWalk, Commands: { Command }): number
	local Fence: FenceEnd = {
		Kind = "Fence",
		Name = Names.WithPart(Walking.Name, HotState.CurrentPart(Walking)),
		Stamp = Walking.Stamp,
		Attempt = FirstAttempt,
		IsFinal = true,
	}
	local Purpose: HotPurpose = { Kind = "Fence", CallId = Walking.Call.CallId }
	local RequestId = HotState.NewRequest(State.Server, State.Hot, Purpose)
	local Update: Command = {
		Kind = "Update",
		RequestId = RequestId,
		Target = HotState.CurrentKey(Walking),
		Request = Ends.EndsRequest({ Fence }),
	}
	table.insert(Commands, Update)
	return RequestId
end

local function SendFence(State: State, Walking: HotWalk, Clock: number, Commands: { Command })
	Walking.Fence = { RequestId = IssueFence(State, Walking, Commands), SentAt = Clock, Errors = 0, RetryAt = nil }
end

local function ResendFence(State: State, Walking: HotWalk, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Fence = Walking.Fence
	if Fence == nil then
		error(NoFenceOut)
	end
	Fence.RequestId = IssueFence(State, Walking, Commands)
	Fence.RetryAt = nil
end

local function ReadLackingParts(State: State, Call: ReadingCall, Clock: number, Commands: { Command })
	local Known = HotState.ViewOf(State.Hot, Call.Store, Call.Scope, Call.Quantity)
	local Bound = Cache.StoreNamed(State.Server, Call.Store).Setup.Limits.OpBound
	for _, Index in View.Lacking(Known, Call.Quantity.Parts) do
		local Out = Known.ReadOut[Index]
		if Out ~= nil and Clock < Out.SentAt + Bound then
			continue
		end
		local Purpose: HotPurpose = {
			Kind = "PartRead",
			Store = Call.Store,
			Scope = Call.Scope,
			Quantity = Call.Quantity,
			Index = Index,
			CallId = Call.CallId,
			Fraction = Call.Fraction,
		}
		local RequestId = HotState.NewRequest(State.Server, State.Hot, Purpose)
		Known.ReadOut[Index] = { RequestId = RequestId, SentAt = Clock }
		local Get: Command = { Kind = "Get", RequestId = RequestId, Target = HotState.PartKeyOf(Call, Index) }
		table.insert(Commands, Get)
	end
end

return {
	SendFence = SendFence,
	ResendFence = ResendFence,
	ReadLackingParts = ReadLackingParts,
}
