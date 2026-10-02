--!strict
--!optimize 2

--[=[
	Ledger: Plumbing. Player data as a ledger, and not as a document.

	Ledger hooks nothing in the engine: the game calls Load when a player joins, Unload when they
	leave, and CloseAll from BindToClose. A client may require this to read Answer. A call that needs
	the server checks with Errors.OnServer.

	Return type: The Ledger module.
	Example usage:
		local Gold = Ledger.New({ Name = "Gold", Default = { Gold = 0 }, Reducer = Reducer })
		if Result == Ledger.Answer.Busy then return end
--]=]

local Answer = require("@self/Core/Answer")
local Store = require("@self/Store/Store")

export type Answer = Answer.Answer
export type Store = Store.Store
export type Leg = Store.Leg
export type Options = Store.Options
export type CutOptions = Store.CutOptions
export type BumpOptions = Store.BumpOptions
export type TakeOptions = Store.TakeOptions
export type CreditOptions = Store.CreditOptions
export type MoveOptions = Store.MoveOptions
export type Ticket = Store.Ticket
export type Taken = Store.Taken
export type Stock = Store.Stock
export type Naming = Store.Naming

return {
	Answer = Answer,
	New = Store.New,
	Tx = Store.Tx,
	CloseAll = Store.CloseAll,
}
