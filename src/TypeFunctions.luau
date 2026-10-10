--!strict
--!optimize 2

--[=[
	TypeFunctions: turns a game's op map into the types its ops are held against. OpUnion is the tagged union a reducer
	narrows on; OpOf names one kind; both take the naming fields, not a fixed Id. Overloads makes one call per OpUnion
	arm. OpsListed is the Ops a typed store must give. Frozen leaves only array and map slots writable. OpenAsAny types
	an open op any. NoInfer blocks inference.

	Return type: An empty table. The types are OpOf, ReadOnly, Frozen, OpenAsAny, OpUnion, Overloads, OpsListed,
	NoInfer, NumberKeys and SameKeys.
	Example usage:
		local TypeFunctions = require("./TypeFunctions")
		type Ops = TypeFunctions.OpUnion<{ Buy: { Item: string } }, { read Id: string? }>
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

export type function Frozen(Shape: type): type
	local function Deep(Held: type, Depth: number): type
		if Depth > 16 then
			return Held
		end
		if Held:is("union") or Held:is("intersection") then
			local Parts = {}
			for _, Part in Held:components() do
				table.insert(Parts, Deep(Part, Depth + 1))
			end
			return if Held:is("union")
				then types.unionof(table.unpack(Parts))
				else types.intersectionof(table.unpack(Parts))
		end
		if not Held:is("table") then
			return Held
		end

		local Out = types.newtable(nil, nil, Held:metatable())
		for Name, Field in Held:properties() do
			if Field.read ~= nil then
				Out:setreadproperty(Name, Deep(Field.read, Depth + 1))
			end
		end
		local Indexer = Held:readindexer()
		if Indexer ~= nil then
			Out:setindexer(Indexer.index, Deep(Indexer.result, Depth + 1))
		end
		return Out
	end

	return Deep(Shape, 0)
end

export type function OpenAsAny(Shape: type): type
	if not Shape:is("table") or Shape:readindexer() == nil then
		return Shape
	end
	for Name, Held in Shape:properties() do
		if Name:is("singleton") and Name:value() == "Kind" and Held.read == types.string then
			return types.any
		end
	end
	return Shape
end

export type OpOf<O, K, Naming> = Naming & { read Kind: K } & ReadOnly<index<O, K>>

export type function OpUnion(Map: type, Naming: type): type
	local function WithNaming(Arm: type): type
		for Field, Held in Naming:properties() do
			Arm:setreadproperty(Field, Held.read)
		end
		return Arm
	end

	if not Map:is("table") then
		local Open = types.newtable()
		Open:setproperty(types.singleton("Kind"), types.string)
		Open:setindexer(types.any, types.unknown)
		return WithNaming(Open)
	end

	local Arms = {}
	for Kind, Held in Map:properties() do
		local Fields = Held.read
		if Fields == nil then
			continue
		end
		if not Fields:is("table") then
			error(
				`op kind '{tostring(Kind)}' has to name the fields it carries, as a table, and it names {tostring(
					Fields
				)}`
			)
		end

		local Arm = types.copy(Fields)
		for Name in Fields:properties() do
			Arm:setwriteproperty(Name, nil)
		end
		Arm:setreadproperty(types.singleton("Kind"), Kind)
		table.insert(Arms, WithNaming(Arm))
	end

	if #Arms == 0 then
		return types.never
	end
	if #Arms == 1 then
		return Arms[1]
	end
	return types.unionof(table.unpack(Arms))
end

export type function Overloads(Union: type, Shape: type): type
	local Lead = Shape:parameters().head or {}
	local Gives = Shape:returns()
	local Arms = if Union:is("union") then Union:components() else { Union }

	local Calls = {}
	for _, Arm in Arms do
		local Takes = table.clone(Lead)
		table.insert(Takes, Arm)
		table.insert(Calls, types.newfunction({ head = Takes }, { head = Gives.head, tail = Gives.tail }))
	end

	if #Calls == 1 then
		return Calls[1]
	end
	return types.intersectionof(table.unpack(Calls))
end

export type function OpsListed(Map: type, Value: type): type
	if not Map:is("table") then
		return types.optional(Value)
	end

	local Listed = types.newtable()
	local Any = false
	for Kind in Map:properties() do
		Listed:setreadproperty(Kind, Value)
		Any = true
	end
	return if Any then Listed else types.optional(Value)
end

export type function NoInfer(Given: type): type
	return Given
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
		error(
			`the two views of a store have drifted apart: {table.concat(Apart, ", ")}. `
				.. "A method has to be on both or on neither"
		)
	end
	return types.boolean
end

return table.freeze({})
