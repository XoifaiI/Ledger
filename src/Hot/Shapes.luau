--!strict
--!optimize 2

--[=[
	Shapes: what split quantities add to calls, part ops and answers (sheet H1, H4, H7, H8). Part op terms
	carry the declaration's fingerprint. A hold's id is its walk's plain drawn name. A take's Legs join each step's
	Tx, a gather's Name follows the take's, and PartLegsMost is the transaction's leg measure. Took, HoldHandle,
	QuantityTotal and Closed are the answers.

	Return type: An empty table. The types are QuantityName, QuantityDeclaration, Serials, OpenTerms, TakeTerms,
	CreditTerms, CloseTerms, HoldTerms, ConfirmTerms, ReleaseTerms, TakeName, TakeCall, GatherCall, HoldCall,
	WalkCall, OpenCall, CloseCall, ConfirmCall, ReleaseCall, DepositTo, DepositCall, WithdrawTo, WithdrawCall,
	HotCall, Took, QuantityTotal, HoldHandle and Closed.
	Example usage:
		local HotShapes = require("./Hot/Shapes")
		type OpenTerms = HotShapes.OpenTerms
--]=]

local HashInputs = require("../Encoding/HashInputs")
local Hot = require("../Constants/Hot")
local Names = require("../Encoding/Names")
local TxShapes = require("../Tx/Shapes")

type Name = Names.Name
type TxLeg = TxShapes.TxLeg

export type Serials = HashInputs.SerialRunInput

export type QuantityName = {
	read Name: string,
	read Parts: number,
}

export type QuantityDeclaration = QuantityName & {
	read Mode: Hot.Mode,
	read Stock: number?,
	read Serials: Serials?,
	read Proceeds: { string },
}

export type OpenTerms = {
	read Fingerprint: number,
	read OpenedAt: number,
	read IsFinal: boolean,
	read Free: number,
	read Range: Serials?,
}

export type TakeTerms = {
	read Fingerprint: number,
	read Count: number,
	read Price: { [string]: unknown },
}

export type CreditTerms = { read Fingerprint: number, read Count: number }

export type CloseTerms = { read Fingerprint: number }

export type HoldTerms = {
	read Fingerprint: number,
	read Id: Name,
	read Count: number,
	read Duration: number,
}

export type ConfirmTerms = {
	read Fingerprint: number,
	read Id: Name,
	read Count: number,
	read Price: { [string]: unknown },
}

export type ReleaseTerms = { read Fingerprint: number, read Id: Name }

export type TakeName = { read Kind: "Game", read Text: string, read Stamp: number }

export type TakeCall = {
	read Kind: "Call",
	read Method: "Take",
	read IsGather: false,
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Quantity: QuantityDeclaration,
	read Count: number,
	read Price: { [string]: unknown },
	read Name: TakeName?,
	read Legs: { TxLeg },
	read Fraction: number,
}

export type GatherCall = {
	read Kind: "Call",
	read Method: "Take",
	read IsGather: true,
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Quantity: QuantityDeclaration,
	read Count: number,
	read Receiver: TxLeg,
	read PartLegsMost: number,
	read Name: TakeName?,
	read Fraction: number,
}

export type HoldCall = {
	read Kind: "Call",
	read Method: "Hold",
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Quantity: QuantityDeclaration,
	read Count: number,
	read Duration: number,
	read Fraction: number,
}

export type OpenCall = {
	read Kind: "Call",
	read Method: "Open",
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Quantity: QuantityDeclaration,
}

export type CloseCall = {
	read Kind: "Call",
	read Method: "Close",
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Quantity: QuantityDeclaration,
	read Fraction: number,
}

export type ConfirmCall = {
	read Kind: "Call",
	read Method: "Confirm",
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Quantity: QuantityDeclaration,
	read Hold: HoldHandle,
	read Price: { [string]: unknown },
	read Legs: { TxLeg },
	read Fraction: number,
}

export type ReleaseCall = {
	read Kind: "Call",
	read Method: "ReleaseHold",
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Quantity: QuantityDeclaration,
	read Hold: HoldHandle,
	read Fraction: number,
}

export type DepositTo = { read Kind: "Home" } | { read Kind: "Part", read Index: number }

type DepositFromCall = {
	read Kind: "Call",
	read Method: "Deposit",
	read IsMinted: false,
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Quantity: QuantityDeclaration,
	read Count: number,
	read To: DepositTo,
	read From: TxLeg,
}

type MintedDepositCall = {
	read Kind: "Call",
	read Method: "Deposit",
	read IsMinted: true,
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Quantity: QuantityDeclaration,
	read Count: number,
	read To: DepositTo,
	read Fraction: number,
}

export type DepositCall = DepositFromCall | MintedDepositCall

export type WithdrawTo = { read Kind: "Part", read Index: number } | { read Kind: "Key", read Credit: TxLeg }

export type WithdrawCall = {
	read Kind: "Call",
	read Method: "Withdraw",
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Quantity: QuantityDeclaration,
	read Part: number,
	read Field: string,
	read Amount: unknown,
	read To: WithdrawTo,
}

export type WalkCall = TakeCall | HoldCall

export type HotCall =
	WalkCall
	| GatherCall
	| OpenCall
	| CloseCall
	| ConfirmCall
	| ReleaseCall
	| DepositCall
	| WithdrawCall

export type Took = {
	read Part: number,
	read Value: number?,
}

export type QuantityTotal = {
	read Sold: number,
	read Free: number,
	read Held: number,
}

export type HoldHandle = {
	read Id: Name,
	read Part: number,
	read Count: number,
	read End: number,
	read Serials: Serials?,
}

export type Closed = {
	read Removed: { number },
	read Left: { number },
	read Missing: { number },
}

return {}
