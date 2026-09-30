--!strict

--[=[

	Types: The shapes Step, the writer and the rules share.

	An op carries the incarnation it was judged for, nil for any, or Create, the id for a key it
	makes. A note says by op index what fate an op has, or why it has none, and holds the value to
	write. A build's Level is its migration count, and its Floor the index of the last breaking one.

	Return type: A table with Form and Why. The types are Form, Op, Probe, Request, Why, Stored, Note
	and Build.
	Example usage:
		if Op.Form == Types.Form.Untimed then return Types.Why.NoRoom end
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

export type Probe = {
	read Name: string,
	read Stamp: number,
}

export type Request = {
	read Writer: number,
	read Ack: number,
	read MustExist: boolean,
	read Ops: { Op },
	read Fresh: boolean?,
	read Probe: Probe?,
}

export type Why = "Spent" | "Forgotten" | "Behind" | "Ahead" | "NoRoom" | "Missing" | "Undecided" | "Corrupt" | "Worn"

export type Stored = {
	s: { [string]: any },
	b: string,
}

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
	Stored: Stored?,
	Held: number?,
	Why: Why?,
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

return {
	Form = Form,
	Why = Why,
}
