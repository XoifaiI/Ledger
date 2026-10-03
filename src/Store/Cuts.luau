--!strict
--!optimize 2

--[=[
	Cuts: Object. A Reset or an Erase of one key, as a store runs it.

	A cut with no name has one drawn, and drawn once more when the first expires before anything was
	written. A named cut's print covers its kind and the state it is given, so the name under other
	terms answers Spent. An Erase that answers true takes the key's copy off, and tells the key's
	queue that the key is gone. Its namings are what the seal held, and Ledger keeps them nowhere
	else. Once and Given throw at the game's call.

	Return type: The Cuts module, and the Options type.
	Example usage:
		local Reply, Namings = Cuts.Erase(Owner, "42", nil, nil)
--]=]

local Answer = require("../Core/Answer")
local Book = require("../Record/Book")
local Clock = require("../Machine/Clock")
local Copies = require("../Record/Copies")
local Copy = require("../Calls/Copy")
local Cut = require("../Calls/Cut")
local Errors = require("../Core/Errors")
local Guard = require("../Record/Guard")
local Keys = require("./Keys")
local Ops = require("./Ops")
local Queue = require("../Record/Queue")
local Requests = require("../Record/Requests")
local Runner = require("../Machine/Runner")
local Runtime = require("./Runtime")
local Sizes = require("../Core/Constants/Sizes")
local Value = require("../Encode/Value")

type Naming = Keys.Naming
type Owner = Keys.Owner
type Reply = Queue.Reply
type State = { [string]: any }

export type Options = {
	read Once: string?,
	read OnceAt: number?,
	read State: State?,
}

local Shared = Runtime.Shared

local function Cutting(Owner: Owner, Key: string | number, Kind: number, Name: string?, Stamp: number?, Given: State?): (Reply, { Naming }?)
	local At = Keys.Ref(Owner, Key)
	local Mark = Book.Address(At)
	local Erasable = Owner.Build.Erasable
	local Print = if Name then Ops.Print({ Kind = Kind, State = Given }) else nil
	local Number = Shared:Server()
	for _ = 1, if Name then 1 else Runtime.DRAWS do
		local Asked: Requests.Cut = { Name = Name or Shared:Draw(), Stamp = Stamp or Clock.Now(), Kind = Kind, Print = Print, Helper = false, Server = Number, State = Given }
		local Context = Cut.Context(At, Asked, Erasable)
		Context.Seen = if Erasable then Shared.Ids:Get(Mark) else nil
		local Result = Runner.Run(Cut.Machine, Context, Shared.Places):Wait()
		local Seen = Context.Seen
		if Seen then
			Shared:Learn(At, Seen)
		end
		if Result == nil then
			return Answer.Unresolved, nil
		elseif Result.Reply ~= Answer.Expired then
			local Seal = Result.Seal
			if Kind == Book.Cause.Erase and Result.Reply == true then
				Shared:Learn(At, false)
				Runner.Run(Copy.Clear, Copies.New(At), Shared.Places):Wait()
			end
			return Result.Reply, if Seal then Keys.Namings(Owner, Seal.Events, Seal.Slots) else nil
		end
	end
	return Answer.Expired, nil
end

local Cuts = {}

function Cuts.Once(Options: Options?): (string?, number?)
	local Asked: Options = Options or {}
	local Name = if Asked.Once == nil then nil else Ops.Name(Asked.Once)
	if Name and Asked.OnceAt == nil then
		Errors.Misuse("a cut named with Once needs OnceAt, the unix time it was first sent", 1)
	end
	return Name, if Name then Ops.Stamp(Asked.OnceAt) else nil
end

function Cuts.Given(Owner: Owner, State: unknown): State?
	if State == nil then
		return nil
	end
	local Bytes = if type(State) == "table" then Value.Check(State) else nil
	if type(State) ~= "table" or Bytes == nil or Bytes > math.min(Owner.Build.StateCap, Sizes.RESET_MAX) then
		Errors.Misuse(`the State of a Reset of {Owner.Name} is not a table a datastore can hold within {Sizes.RESET_MAX} bytes`, 1)
	elseif not Guard.Admits(Owner.Build, {}, State :: State) then
		Errors.Misuse(`the State of a Reset of {Owner.Name} holds a field the store does not declare, or a money field that is not a whole number`, 1)
	end
	return State :: State
end

function Cuts.Reset(Owner: Owner, Key: string | number, Name: string?, Stamp: number?, Given: State?): Reply
	return (Cutting(Owner, Key, Book.Cause.Reset, Name, Stamp, Given))
end

function Cuts.Erase(Owner: Owner, Key: string | number, Name: string?, Stamp: number?): (Reply, { Naming }?)
	return Cutting(Owner, Key, Book.Cause.Erase, Name, Stamp, nil)
end

return Cuts
