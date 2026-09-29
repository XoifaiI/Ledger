--!strict
--!optimize 2
--!native

--[=[

	Reduce: Runs a game's reducer over a batch of ops, and lets the reducer change the state it is given.

	A reducer gives back the next state to take an op, and nil to refuse it. Its return is typed
	unknown, since a reducer typed to give back S? stops S being inferred at the call. It may give back a new
	table, or change the state it is given and give that back. A reducer that throws, yields or gives
	back something other than a table has refused. Every run gets its own copy of the op.

	Fold hands the reducer a frozen state first, as Ledger always has, so a reducer that clones pays
	nothing more and a refusal leaves the state as it was. A run that throws is run again on a copy
	that can be changed. When that run takes the op, the reducer is one that writes: Fold remembers it
	and folds the rest of the batch on the copy, skipping the frozen try from then on. A refused op may
	have changed that copy, so Fold rebuilds it from the last frozen state by running the ops taken
	since then again. A rebuild that refuses an op the first run took means the reducer is not
	deterministic, and Fold warns.

	Snapshot gives a frozen copy of a state for a game to read.

	Return type: A table with Fold, Copy and Snapshot.
	Example usage:
		local Reduce = require("./Reduce")
		local State, Took = Reduce.Fold(Base, Ops, Reducer)
--]=]

export type Reducer<S, O> = (State: S, Op: O) -> unknown

local Writers: { [any]: true } = setmetatable({}, { __mode = "k" }) :: any

local function Copy<T>(Value: T): T
	if type(Value) == "buffer" then
		local Bytes = buffer.create(buffer.len(Value))
		buffer.copy(Bytes, 0, Value)
		return Bytes :: any
	end
	if type(Value) ~= "table" then
		return Value :: any
	end
	local Fresh = table.clone(Value :: any)
	for Key, Inner in Fresh do
		if type(Inner) == "table" or type(Inner) == "buffer" then
			Fresh[Key] = Copy(Inner)
		end
	end
	return Fresh
end

local function Freeze(Value: unknown)
	if type(Value) ~= "table" or table.isfrozen(Value :: any) then
		return
	end
	table.freeze(Value :: any)
	for _, Inner in Value :: any do
		Freeze(Inner)
	end
end

local function Snapshot<T>(Value: T): T
	local Fresh = Copy(Value)
	Freeze(Fresh)
	return Fresh
end

local function Run<S, O>(Reducer: Reducer<S, O>, State: S, Op: O): (S?, boolean)
	local Thread = coroutine.create(Reducer)
	local Ok, Next = coroutine.resume(Thread, State, Copy(Op))
	if coroutine.status(Thread) ~= "dead" then
		coroutine.close(Thread)
		return nil, false
	end
	return if Ok and type(Next) == "table" then Next :: S else nil, not Ok
end

local function Mutable<S, O>(Clean: S, Ops: { O }, From: number, Reducer: Reducer<S, O>, Took: { boolean }): S
	local Since: { O } = {}
	local State = Copy(Clean)
	for Index = From, #Ops do
		local Op = Ops[Index]
		local Next = Run(Reducer, State, Op)
		if Next ~= nil then
			State = Next :: S
			Took[Index] = true
			table.insert(Since, Op)
			continue
		end
		State = Copy(Clean)
		for _, Done in Since do
			local Again = Run(Reducer, State, Done)
			if Again == nil then
				warn(
					"Ledger: the reducer took an op and refused it when run again on the same state, so it is not deterministic. read only the two arguments, and pass os.time or math.random in on the op instead"
				)
				continue
			end
			State = Again :: S
		end
	end
	return State
end

local function Fold<S, O>(Base: S, Ops: { O }, Reducer: Reducer<S, O>): (S, { boolean })
	local Took: { boolean } = table.create(#Ops, false)
	if Writers[Reducer] then
		return Mutable(Base, Ops, 1, Reducer, Took), Took
	end
	Freeze(Base)
	local State = Base
	for Index, Op in Ops do
		local Next, Threw = Run(Reducer, State, Op)
		if Next ~= nil then
			Freeze(Next)
			State = Next :: S
			Took[Index] = true
		elseif Threw and Run(Reducer, Copy(State), Op) ~= nil then
			Writers[Reducer] = true
			return Mutable(State, Ops, Index, Reducer, Took), Took
		end
	end
	return State, Took
end

return table.freeze({
	Fold = Fold,
	Copy = Copy,
	Snapshot = Snapshot,
})
