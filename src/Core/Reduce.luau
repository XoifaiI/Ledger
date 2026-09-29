--!strict
--!optimize 2
--!native

--[=[

	Reduce: Folds ops through a game's reducer.

	A reducer gives back the next state, or nil to refuse. A throw, a yield or a value that is not a
	table refuses too. A fold hands the reducer a frozen state first. A reducer that throws on it but
	takes the op on a copy writes, and its folds run on copies, rebuilt from the last frozen state
	after a refusal. A rebuild that disagrees warns that the reducer is not deterministic. Run makes
	one guarded call.

	Return type: A table with Start, Apply, Fold, Run, Copy and Snapshot.
	Example usage:
		local Took = Reduce.Apply(Reduce.Start(Base, Reducer), Op)
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

return {
	Start = Start,
	Apply = Apply,
	Fold = Fold,
	Run = Run,
	Copy = Copy,
	Snapshot = Snapshot,
}
