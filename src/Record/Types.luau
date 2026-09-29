--!strict

--[=[

	Types: The shapes Step, a key's writer and the rules share.

	An op carries its number in its writer's queue, its stamp, its kind, and for a named op its name
	and the fingerprint of a game's name. It carries the incarnation it was judged for, nil meaning
	any, or Create, the id to make the key with when it was judged for no key. A request is one
	writer's ops in number order. A note says, by op index, the fate an op has, or why it has none.
	A build is what one build of the game gives Step. Its Level is the number of its migrations and
	its Floor is the index of the last breaking one. Form and Why name each form and reason once, so
	a misspelt one is a type error.

	Return type: A table with Form and Why. The types are Form, Op, Request, Why, Note and Build.
	Example usage:
		local Types = require("./Types")
		if Op.Form == Types.Form.Untimed then
			return Types.Why.NoRoom
		end
--]=]

export type Form = "Minted" | "Hopeful" | "Timed" | "Untimed"

export type Op = {
	read Form: Form,
	read Seq: number,
	read Stamp: number,
	read Kind: number,
	read Name: string?,
	read Print: number?,
	read View: number?,
	read Id: string?,
	read Create: string?,
	read Body: unknown,
}

export type Request = {
	read Writer: number,
	read Ack: number,
	read MustExist: boolean,
	read Ops: { Op },
	read Fresh: boolean?,
}

export type Why = "Spent" | "Forgotten" | "Behind" | "Ahead" | "NoRoom" | "Missing" | "Undecided" | "Corrupt" | "Worn"

export type Note = {
	Fates: { [number]: number },
	Whys: { [number]: Why },
	Decided: { number },
	Writes: number,
	Cuts: number,
	Horizon: number,
	CutHorizon: number,
	Id: string?,
	State: unknown,
}

export type Build = {
	read Reducer: (State: any, Op: any) -> unknown,
	read Migrations: { (State: any) -> unknown },
	read Default: { [string]: any },
	read Level: number,
	read Floor: number,
	read Money: { string },
	read Fields: { [string]: true },
	read Window: { [number]: number },
	read Minted: number,
	read CutWindow: number,
	read TimedRoom: number,
	read UntimedRoom: number,
	read CutNames: number,
	read StateCap: number,
	read Ahead: number,
	read Hold: number,
}

local Form: {
	read Minted: "Minted",
	read Hopeful: "Hopeful",
	read Timed: "Timed",
	read Untimed: "Untimed",
} = {
	Minted = "Minted",
	Hopeful = "Hopeful",
	Timed = "Timed",
	Untimed = "Untimed",
}

local Why: {
	read Spent: "Spent",
	read Forgotten: "Forgotten",
	read Behind: "Behind",
	read Ahead: "Ahead",
	read NoRoom: "NoRoom",
	read Missing: "Missing",
	read Undecided: "Undecided",
	read Corrupt: "Corrupt",
	read Worn: "Worn",
} =
	{
		Spent = "Spent",
		Forgotten = "Forgotten",
		Behind = "Behind",
		Ahead = "Ahead",
		NoRoom = "NoRoom",
		Missing = "Missing",
		Undecided = "Undecided",
		Corrupt = "Corrupt",
		Worn = "Worn",
	}

table.freeze(Form)
table.freeze(Why)

return table.freeze({
	Form = Form,
	Why = Why,
})
