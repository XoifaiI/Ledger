--!strict
--!optimize 2

--[=[

	Diff: Logic. The changes a game op made to a state, as data any build can apply.

	Spec: transaction 2 and 3.4.

	Make walks two states and gives back one change for each path whose value differs: k is the path
	and v the new value, with no v for a value taken out. It walks into a table only when both sides
	hold one, and compares buffers by their bytes. Apply gives back a new state with the changes laid
	on it. It copies each table on a changed path and leaves the state it was given alone.

	Return type: A table with Make and Apply. The type is Change.
	Example usage:
		local Changes = Diff.Make(State, Next)
		local After = Diff.Apply(State, Changes)
--]=]

local Reduce = require("../Core/Reduce")

type State = { [any]: any }

export type Change = {
	k: { any },
	v: any,
}

local Diff = {}

local function Same(Old: unknown, New: unknown): boolean
	if Old == New then
		return true
	elseif type(Old) == "buffer" and type(New) == "buffer" then
		return buffer.tostring(Old) == buffer.tostring(New)
	end
	return false
end

local function Walk(Before: State, After: State, Path: { any }, Out: { Change })
	for Key, New in After do
		local Old = Before[Key]
		if Same(Old, New) then
			continue
		end
		local Here = table.clone(Path)
		table.insert(Here, Key)
		if type(Old) == "table" and type(New) == "table" then
			Walk(Old, New, Here, Out)
		else
			table.insert(Out, { k = Here, v = Reduce.Copy(New) })
		end
	end
	for Key in Before do
		if After[Key] == nil then
			local Here = table.clone(Path)
			table.insert(Here, Key)
			table.insert(Out, { k = Here, v = nil })
		end
	end
end

function Diff.Make(Before: State, After: State): { Change }
	local Out: { Change } = {}
	Walk(Before, After, {}, Out)
	return Out
end

function Diff.Apply(Base: State, Changes: { Change }): State
	local Root = table.clone(Base)
	local Copied: { [State]: true } = { [Root] = true }
	for _, Each in Changes do
		local Path = Each.k
		local Parent = Root
		for Index = 1, #Path - 1 do
			local Key = Path[Index]
			local Child = Parent[Key]
			if type(Child) ~= "table" then
				Child = {}
			elseif not Copied[Child] then
				Child = table.clone(Child)
			end
			Copied[Child] = true
			Parent[Key] = Child
			Parent = Child
		end
		Parent[Path[#Path]] = Reduce.Copy(Each.v)
	end
	return Root
end

return Diff
