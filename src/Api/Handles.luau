--!strict
--!optimize 2

--[=[
	Handles: the frozen handles Ledger gives the game, OpId, Applied and a hold's handle. Each is kept weakly, so a
	look-alike table is refused; an Applied one with its key, a hold's with its quantity. A drawn name the core hands
	back becomes an OpId kept as handed back, a game name its text; AskedOf gives back the core's name.

	Return type: A plain table of functions.
	Example usage:
		local OpId = Handles.OpIdOf(Drawn)
		local Asked = Handles.AskedOf(OpId)
--]=]

local Events = require("../Events")
local Guards = require("../Judging/Guards")
local HotShapes = require("../Hot/Shapes")
local Names = require("../Encoding/Names")
local Shapes = require("../Shapes")
local Types = require("../Types")

type AskedName = Shapes.AskedName
type GivenName = Events.GivenName
type HoldHandle = HotShapes.HoldHandle
type QuantityDeclaration = HotShapes.QuantityDeclaration
type StoreKey = Names.StoreKey
type Applied = Types.Applied
type Name = Types.Name
type OpId = Types.OpId

type Handed = { read Name: AskedName }

local Made: { [unknown]: true } = {}
setmetatable(Made, { __mode = "k" })
local AppliedKeys: { [unknown]: StoreKey } = {}
setmetatable(AppliedKeys, { __mode = "k" })
local HoldQuantities: { [unknown]: QuantityDeclaration } = {}
setmetatable(HoldQuantities, { __mode = "k" })
local HandedBack: { [unknown]: true } = {}
setmetatable(HandedBack, { __mode = "k" })

local function Registered<Handle>(Handle: Handle): Handle
	Made[Handle] = true
	Guards.DeepFreeze(Handle)
	return Handle
end

local function OpIdOf(Name: AskedName): OpId
	local Handle: Handed = { Name = Name }
	return Registered(Handle)
end

local function AppliedOf(Name: AskedName, CallId: number, Key: StoreKey): Applied
	local Handle: Applied = { Name = Name, CallId = CallId, Key = table.clone(Key) }
	AppliedKeys[Handle] = table.clone(Key)
	return Registered(Handle)
end

local function HoldOf(Handle: HoldHandle, Quantity: QuantityDeclaration): HoldHandle
	HoldQuantities[Handle] = Quantity
	return Handle
end

local function PublicNameOf(Given: GivenName): Name
	if Given.Kind == "Game" then
		return Given.Text
	end
	local Handle = OpIdOf(Given)
	HandedBack[Handle] = true
	return Handle
end

local function AppliedKeyOf(Value: unknown): StoreKey?
	return AppliedKeys[Value]
end

local function IsHandle(Value: unknown): boolean
	return Made[Value] == true
end

local function IsHandedBack(Value: unknown): boolean
	return HandedBack[Value] == true
end

local function IsHoldHandle(Value: unknown): boolean
	return HoldQuantities[Value] ~= nil
end

local function HoldQuantityOf(Value: unknown): QuantityDeclaration?
	return HoldQuantities[Value]
end

local function AskedOf(Handle: OpId | Applied): AskedName
	local Held = Handle :: Handed
	return Held.Name
end

return {
	OpIdOf = OpIdOf,
	AppliedOf = AppliedOf,
	HoldOf = HoldOf,
	PublicNameOf = PublicNameOf,
	AppliedKeyOf = AppliedKeyOf,
	IsHandle = IsHandle,
	IsHandedBack = IsHandedBack,
	IsHoldHandle = IsHoldHandle,
	HoldQuantityOf = HoldQuantityOf,
	AskedOf = AskedOf,
}
