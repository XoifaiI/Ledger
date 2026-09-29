--!strict
--!optimize 2
--!native

--[=[

	Reduce: Runs a game's reducer over ops, and lets the reducer change the state it is given.

	A reducer gives back the next state to take an op, and nil to refuse it. Its return is typed
	unknown, since a reducer typed to give back S? stops S being inferred at the call. It may give
	back a new table, or change the state it is given and give that back. A reducer that throws,
	yields or gives back something other than a table has refused, and Apply passes back what a refusal gave back
	other than nil as its reason. Every run gets its own copy of the op.

	Start begins a fold from a base that it never changes, and Apply runs one op on it. A fold hands
	the reducer a frozen state first, as Ledger always has, so a reducer that clones pays nothing more
	and a refusal leaves the state as it was. A run that throws is run again on a copy that can be
	changed. When that run takes the op, the reducer is one that writes: the fold goes on with the
	copy, and Reduce remembers the reducer so later folds skip the frozen try. A refused op may have
	changed that copy, so the fold rebuilds it from the last frozen state by running the ops taken
	since then again. A rebuild that refuses an op the first run took means the reducer is not
	deterministic, and the fold warns. Fold runs a whole batch.

	Snapshot gives a frozen copy of a state for a game to read. Run makes one guarded call of any
	function shaped like a reducer.

	Return type: A table with Start, Apply, Fold, Run, Copy and Snapshot.
	Example usage:
		local Reduce = require("./Reduce")
		local Folding = Reduce.Start(Base, Reducer)
		local Took = Reduce.Apply(Folding, Op)
		local State = Folding.State
--]=]

export type Reducer<S, O> = (State: S, Op: O) -> unknown

export type Fold<S, O> = {
	read Reducer: Reducer<S, O>,
	Apply: (Folding: Fold<S, O>, Op: O) -> (boolean, unknown),
	Clean: S,
	State: S,
	Since: { O },
}

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

local function Run<S, O>(Reducer: Reducer<S, O>, State: S, Op: O): (S?, boolean, unknown)
	local Thread = coroutine.create(Reducer)
	local Ok, Next = coroutine.resume(Thread, State, Copy(Op))
	if coroutine.status(Thread) ~= "dead" then
		coroutine.close(Thread)
		return nil, false, nil
	elseif not Ok then
		return nil, true, nil
	elseif type(Next) == "table" then
		return Next :: S, false, nil
	end
	return nil, false, Next
end

local function ApplyMutable<S, O>(Folding: Fold<S, O>, Op: O): (boolean, unknown)
	local Next, _, Reason = Run(Folding.Reducer, Folding.State, Op)
	if Next ~= nil then
		Folding.State = Next :: S
		table.insert(Folding.Since, Op)
		return true, nil
	end
	local State = Copy(Folding.Clean)
	for _, Done in Folding.Since do
		local Again = Run(Folding.Reducer, State, Done)
		if Again == nil then
			warn(
				"Ledger: the reducer took an op and refused it when run again on the same state, so it is not deterministic. read only the two arguments, and pass os.time or math.random in on the op instead"
			)
			continue
		end
		State = Again :: S
	end
	Folding.State = State
	return false, Reason
end

local function ApplyFrozen<S, O>(Folding: Fold<S, O>, Op: O): (boolean, unknown)
	local Next, Threw, Reason = Run(Folding.Reducer, Folding.State, Op)
	if Next ~= nil then
		Freeze(Next)
		Folding.State = Next :: S
		return true, nil
	end
	if not Threw or Run(Folding.Reducer, Copy(Folding.State), Op) == nil then
		return false, Reason
	end
	Writers[Folding.Reducer] = true
	Folding.Apply = ApplyMutable
	Folding.Clean = Folding.State
	Folding.State = Copy(Folding.State)
	return ApplyMutable(Folding, Op)
end

local function Start<S, O>(Base: S, Reducer: Reducer<S, O>): Fold<S, O>
	if Writers[Reducer] then
		return { Reducer = Reducer, Apply = ApplyMutable, Clean = Base, State = Copy(Base), Since = {} }
	end
	Freeze(Base)
	return { Reducer = Reducer, Apply = ApplyFrozen, Clean = Base, State = Base, Since = {} }
end

local function Apply<S, O>(Folding: Fold<S, O>, Op: O): (boolean, unknown)
	return Folding.Apply(Folding, Op)
end

local function Fold<S, O>(Base: S, Ops: { O }, Reducer: Reducer<S, O>): (S, { boolean })
	local Folding = Start(Base, Reducer)
	local Took: { boolean } = table.create(#Ops, false)
	for Index, Op in Ops do
		Took[Index] = (Apply(Folding, Op))
	end
	return Folding.State, Took
end

return table.freeze({
	Start = Start,
	Apply = Apply,
	Fold = Fold,
	Run = Run,
	Copy = Copy,
	Snapshot = Snapshot,
})
