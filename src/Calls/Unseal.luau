--!strict
--!optimize 2

--[=[
	Unseal: Machine. Takes off a seal an erase left on a key.

	The machine sends a seal stamp. Step lands it only on a seal past Windows.SEAL_AGE, or on one
	this server stamped, carrying that rt. When it lands, this server is the one sealer of the new
	rt. The machine then sends the key's one RemoveAsync, and only while the clock reads at most
	Windows.REMOVE_SEND past that rt. It answers true once its removal went out, and false when it
	sent none.

	Return type: The Unseal module, and the Context type.
	Example usage:
		local Removed = Runner.Run(Unseal.Machine, Unseal.Context(Ref, Server, nil), Places):Wait()
--]=]

local Asks = require("../Machine/Asks")
local Book = require("../Record/Book")
local Machine = require("../Machine/Machine")
local Requests = require("../Record/Requests")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

export type Context = {
	read Ref: Book.Ref,
	read Server: number,
	read Rt: number?,
	Seal: Book.Seal?,
}

type Call = Machine.Call<Context, boolean>

local STATE = {
	Stamping = "Stamping" :: "Stamping",
	Removing = "Removing" :: "Removing",
	Done = "Done" :: "Done",
}

local WORD = {
	Due = "Due" :: "Due",
}

local Unseal = {}

local function Answered(Removed: boolean): (Call: Call) -> string
	return function(Call: Call): string
		Machine.Answer(Call, Removed)
		return STATE.Done
	end
end

local function Stamp(Call: Call)
	local Context = Call.Context
	Machine.Ask(Call, Asks.Send(Context.Ref, Requests.Stamp({ Server = Context.Server, Rt = Context.Rt })))
end

local function Stamped(Call: Call): string
	local Note = Machine.Reply(Call).Note
	local Seal = if Note and Note.Report == Types.Report.Stamped then Note.Seal else nil
	if Seal == nil or Seal.Server ~= Call.Context.Server or Call.Now - Seal.Rt > Windows.REMOVE_SEND then
		return Asks.SAID.Done
	end
	Call.Context.Seal = Seal
	return WORD.Due
end

local function Remove(Call: Call)
	Machine.Ask(Call, Asks.Remove(Call.Context.Ref))
end

local STATES: { [string]: Machine.State<Context, boolean> } = {
	[STATE.Stamping] = {
		Enter = Stamp,
		Hear = Stamped,
		On = {
			{ Said = WORD.Due, Go = STATE.Removing },
		},
		Else = Answered(false),
	},
	[STATE.Removing] = {
		Enter = Remove,
		Else = Answered(true),
	},
	[STATE.Done] = {},
}

function Unseal.Context(Ref: Book.Ref, Server: number, Rt: number?): Context
	return { Ref = Ref, Server = Server, Rt = Rt }
end

Unseal.Machine = Machine.Define({ Name = "Unseal", Initial = STATE.Stamping, States = STATES })

return Unseal
