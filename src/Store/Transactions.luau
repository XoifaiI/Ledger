--!strict
--!optimize 2

--[=[
	Transactions: Object. A game's legs made into the legs Terms checks, and one transaction run
	under a drawn or a game name.

	Spec: transaction 3 and 3.1.

	A leg names its store by the object Ledger.New gave back, and Add records each one, so Gather
	refuses any other value. Gather throws at the game's call, and Depth counts the helpers between
	Gather and that call. A leg with no MustExist takes its store's. A transaction with no name has
	one drawn, and drawn once more when the first expires before anything was written. A named one
	runs Tx.Retry, which reads the decider first. Each run hands Tx the incarnation this server last
	saw of every erasable leg key, and learns what Tx saw.

	Return type: The Transactions module, and the Asked type.
	Example usage:
		local Reply = Transactions.Run(Terms.Make(Transactions.Gather(Legs, 0, false), nil, nil), nil, nil)
--]=]

local Answer = require("../Core/Answer")
local Book = require("../Record/Book")
local Clock = require("../Machine/Clock")
local Errors = require("../Core/Errors")
local Keys = require("./Keys")
local Queue = require("../Record/Queue")
local Runner = require("../Machine/Runner")
local Runtime = require("./Runtime")
local Terms = require("./Terms")
local Tx = require("../Calls/Tx")

type Owner = Keys.Owner
type Reply = Queue.Reply

export type Asked = {
	read Store: unknown,
	read Key: string | number,
	read Field: string?,
	read Amount: number?,
	read Kind: string?,
	read Fields: { [string]: any }?,
	read MustExist: boolean?,
	read Slot: { string }?,
}

local Shared = Runtime.Shared
local Stores: { [unknown]: Owner } = {}

local Transactions = {}

function Transactions.Add(Owner: Owner)
	Stores[Owner] = Owner
end

function Transactions.Gather(Legs: { read [number]: Asked }, Depth: number, Serial: boolean): { Terms.Given }
	local Given: { Terms.Given } = {}
	for Index, Leg in Legs do
		local Owner: Owner = Stores[Leg.Store] or Errors.Misuse(`leg {Index} needs Store, a store from Ledger.New`, 1 + Depth)
		local Slot = Leg.Slot
		if Slot ~= nil and not Serial then
			Errors.Misuse(`leg {Index} names a Slot, which only a take of a quantity with serials fills`, 1 + Depth)
		elseif Slot ~= nil and (type(Slot) ~= "table" or Slot[1] == nil or Leg.Kind == nil or not Owner.Build.Fields[Slot[1]]) then
			Errors.Misuse(`the Slot of leg {Index} has to be a path of keys from a declared field, on a game op leg`, 1 + Depth)
		end
		Keys.Reserved(Leg.Key, 1 + Depth)
		Given[Index] = {
			Ref = Keys.Ref(Owner, Leg.Key),
			Place = Shared.Places[Owner.Name],
			MustExist = if Leg.MustExist == nil then Owner.MustExist else Leg.MustExist == true,
			Field = Leg.Field,
			Amount = Leg.Amount,
			Kind = Leg.Kind,
			Fields = Leg.Fields,
			Slot = Slot,
		}
	end
	return Given
end

function Transactions.Run(Made: Terms.Made, Name: string?, Stamp: number?): (Reply, Tx.Context?)
	local Number = Shared:Server()
	local Context: Tx.Context? = nil
	for _ = 1, if Name then 1 else Runtime.DRAWS do
		local Use: Tx.Use = { Name = Name or Shared:Draw(), Stamp = Stamp or Clock.Now(), Print = Made.Print }
		local Of = if Name then Tx.Retry else Tx.Run
		local Ids: { [number]: string | false } = {}
		for Index, Leg in Made.Legs do
			local Seen = if Leg.Erasable then Shared.Ids:Get(Book.Address(Leg.Ref)) else nil
			if Seen ~= nil then
				Ids[Index] = Seen
			end
		end
		local Running = Tx.Context(Use, Made.Legs, Made.Decider, Number, Ids, Shared:Mint())
		local Reply = Runner.Run(Of, Running, Shared.Places):Wait()
		Context = Running
		for Index, Seen in Running.Ids do
			if Seen then
				Shared:Learn(Made.Legs[Index].Ref, Seen)
			end
		end
		if Reply ~= Answer.Expired then
			return Reply or Answer.Unresolved, Context
		end
	end
	return Answer.Expired, Context
end

return Transactions
