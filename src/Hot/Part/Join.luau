--!strict
--!optimize 2

--[=[
	Join: a quantity call's writer op joins its part's writer, which a call's Fraction makes paced (hot keys sheet
	H1, E3). A part is never a shard, so its writer takes the part's pacing. It says whether the op joined or was
	shed.

	Return type: A plain table with JoinPartOp.
	Example usage:
		Join.JoinPartOp(State, Key, Op, Call.Fraction, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Composed = require("../../Composed")
local Durable = require("../../Writing/Durable")
local Events = require("../../Events")
local Names = require("../../Encoding/Names")
local Shapes = require("../../Shapes")

type Command = Events.Command
type StoreKey = Names.StoreKey
type WaitingOp = Shapes.WaitingOp
type State = Composed.State

local IsShardWriter = false

local function JoinPartOp(
	State: State,
	Key: StoreKey,
	Op: WaitingOp,
	Fraction: number,
	Clock: number,
	Commands: { Command }
): boolean
	local Setup = Cache.StoreOf(State.Server, Key).Setup
	return Durable.JoinPaced(State, Key, Op, Setup, IsShardWriter, Fraction, Clock, Commands)
end

return {
	JoinPartOp = JoinPartOp,
}
