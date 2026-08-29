--!strict
--!optimize 2

--[=[
	TypeFunctions: Turns a game's map of op kinds into the types a write is held against.

	A game names its ops one time, as a map of the kind to the fields it carries. OpUnion turns that
	into one tagged union so a reducer narrows on Op.Kind, Overloads turns it into one call shape per
	kind, OpOf names a single kind, and NumberKeys names the number fields of a state.
	Overloads builds plain function types on purpose. A method carrying a generic cannot be compared
	against a separate copy of itself, so a store whose writes were generic could be built and then
	never named in a type.
	An arm reads its fields and does not write them, and OpOf clears the same way through ReadOnly,
	since a type function cannot call the one beside it. The open op an untyped store hands out is
	left alone, and is what a map that is not a table gives back, so these can be asked about a store
	held as any. SameKeys holds the two views of a store against each other, since one is built
	through a cast.

	Return type: An empty table. The types are OpOf, ReadOnly, OpUnion, Overloads, NumberKeys and SameKeys.
	Example usage:
		local TypeFunctions = require("./TypeFunctions")
		type Ops = TypeFunctions.OpUnion<{ Buy: { Item: string } }>
--]=]

export type function ReadOnly(Shape: type): type
	if not Shape:is("table") then
		return Shape
	end

	local Held = types.copy(Shape)
	for Name in Shape:properties() do
		Held:setwriteproperty(Name, nil)
	end
	return Held
end

export type OpOf<O, K> = { read Id: string, read Kind: K } & ReadOnly<index<O, K>>

export type function OpUnion(Map: type): type
	if not Map:is("table") then
		local Open = types.newtable()
		Open:setproperty(types.singleton("Id"), types.string)
		Open:setproperty(types.singleton("Kind"), types.string)
		Open:setindexer(types.any, types.unknown)
		return Open
	end

	local Arms = {}
	for Kind, Held in Map:properties() do
		local Fields = Held.read
		if Fields == nil then
			continue
		end
		if not Fields:is("table") then
			error(`op kind '{tostring(Kind)}' has to name the fields it carries, as a table, and it names {tostring(Fields)}`)
		end

		local Arm = types.copy(Fields)
		for Name in Fields:properties() do
			Arm:setwriteproperty(Name, nil)
		end
		Arm:setreadproperty(types.singleton("Kind"), Kind)
		Arm:setreadproperty(types.singleton("Id"), types.string)
		table.insert(Arms, Arm)
	end

	if #Arms == 0 then
		return types.never
	end
	if #Arms == 1 then
		return Arms[1]
	end
	return types.unionof(table.unpack(Arms))
end

export type function Overloads(Map: type, Shape: type): type
	if not Map:is("table") then
		return Shape
	end

	local Lead = Shape:parameters().head or {}
	local Gives = Shape:returns()

	local Calls = {}
	for Kind, Held in Map:properties() do
		local Fields = Held.read
		if Fields == nil then
			continue
		end
		if not Fields:is("table") then
			error(`op kind '{tostring(Kind)}' has to name the fields it carries, as a table, and it names {tostring(Fields)}`)
		end

		local Takes = {}
		for _, Param in Lead do
			table.insert(Takes, Param)
		end
		table.insert(Takes, Kind)
		table.insert(Takes, Fields)
		table.insert(Calls, types.newfunction({ head = Takes }, { head = Gives.head, tail = Gives.tail }))
	end

	if #Calls == 0 then
		return Shape
	end
	if #Calls == 1 then
		return Calls[1]
	end
	return types.intersectionof(table.unpack(Calls))
end

export type function NumberKeys(Shape: type): type
	if not Shape:is("table") then
		return types.string
	end

	local Named = {}
	for Field, Held in Shape:properties() do
		if Held.read == types.number then
			table.insert(Named, Field)
		end
	end

	if #Named == 0 then
		return types.never
	end
	if #Named == 1 then
		return Named[1]
	end
	return types.unionof(table.unpack(Named))
end

export type function SameKeys(Open: type, Named: type): type
	local function Names(Held: type): { [string]: boolean }
		local Into: { [string]: boolean } = {}
		if Held:is("singleton") then
			Into[tostring(Held:value())] = true
			return Into
		end
		if not Held:is("union") then
			error(`a set of method names has to be singletons, and this one is {tostring(Held)}`)
		end

		for _, Part in Held:components() do
			if Part:is("singleton") then
				Into[tostring(Part:value())] = true
			end
		end
		return Into
	end

	local Ours = Names(Open)
	local Theirs = Names(Named)

	local Apart: { string } = {}
	for Name in Ours do
		if not Theirs[Name] then
			table.insert(Apart, `the typed view has no '{Name}'`)
		end
	end
	for Name in Theirs do
		if not Ours[Name] then
			table.insert(Apart, `the open view has no '{Name}'`)
		end
	end

	if #Apart > 0 then
		table.sort(Apart)
		error(`the two views of a store have drifted apart: {table.concat(Apart, ", ")}. a method has to be on both or on neither`)
	end
	return types.boolean
end

return table.freeze({})
