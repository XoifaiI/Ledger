--!strict

local HttpService = game:GetService("HttpService")

local DataStoreWrapper = require("../src/Util/DataStoreWrapper")
local Fold = require("../src/Fold")
local Log = require("../src/Log")
local Transfer = require("../src/Transfer")

local STORE = "LedgerChaos_v1"
local SEED = 20260714
local RNG = Random.new(SEED)

local function Print(Msg: string)
	print("[Tests] " .. Msg)
end

local function Store(): DataStoreWrapper.DataStoreWrapper
	return DataStoreWrapper.New(STORE, 30, 0.15, 1.1)
end

local function Key(Prefix: string): string
	return Prefix .. "_" .. HttpService:GenerateGUID(false)
end

local function Reducer(State: any, Op: any): any?
	if Op.Kind == "Add" then
		return { Gold = State.Gold + Op.Amount, N = State.N + 1 }
	elseif Op.Kind == "Spend" then
		if Op.Amount > State.Gold then
			return nil
		end
		return { Gold = State.Gold - Op.Amount, N = State.N + 1 }
	end
	return nil
end

local INIT: any = { Gold = 0, N = 0 }

local TR = Transfer.Wrap(Reducer, "Gold")

local MigDefault: any = { Gold = 0, N = 0, Settings = { Volume = 5 } }

local function MigReducer(State: any, Op: any): any?
	if Op.Kind == "Add" then
		return { Gold = State.Gold + Op.Amount, N = State.N + 1, Settings = State.Settings }
	elseif Op.Kind == "SetVol" then
		local Next = table.clone(State)
		Next.Settings = table.clone(State.Settings)
		Next.Settings.Volume = Op.Amount
		return Next
	end
	return nil
end

local RunTag = os.time() % 1000000
local NextUid = 0
local function Uid(): number
	NextUid += 1
	return RunTag * 1000 + NextUid
end

local function FoldRecord(Key: string, With: any?): any
	local Rec = Log.Read(Store(), Key)
	local Base: any = if Rec.Snapshot == nil then INIT else Rec.Snapshot
	return Fold(Base, Rec.Ops, if With == nil then Reducer else With)
end

local function GrantOp(Pid: string, Amount: number, IdPrefix: string?): any
	return { Id = (IdPrefix or "prd:") .. Pid, Kind = "Add", Amount = Amount, PurchaseId = Pid }
end

local function HeldSum(State: any): number
	local Sum = 0
	if type(State._Held) == "table" then
		for _, Entry in State._Held do
			Sum += Entry.Amount
		end
	end
	return Sum
end

local function ChaosAppend(Wrapper: any, K: string, Ops: any): boolean
	return (pcall(function()
		if RNG:NextNumber() < 0.3 then
			task.wait(RNG:NextNumber() * 0.03)
		end
		Log.Append(Wrapper, K, Ops)
		if RNG:NextNumber() < 0.15 then
			Log.Append(Wrapper, K, Ops)
		end
	end))
end

local function Race(Label: string, Thunks: { () -> () }): number
	Print(Label .. ": firing " .. #Thunks .. " concurrent actors")
	local Done = 0
	for _, Thunk in Thunks do
		task.spawn(function()
			Thunk()
			Done += 1
		end)
	end
	local Start = os.clock()
	while Done < #Thunks do
		task.wait()
		if os.clock() - Start > 180 then
			break
		end
	end
	Print(Label .. ": " .. Done .. "/" .. #Thunks .. " finished in " .. string.format("%.1fs", os.clock() - Start))
	return Done
end

return table.freeze({
	STORE = STORE,
	SEED = SEED,
	RNG = RNG,

	Print = Print,
	Store = Store,
	Key = Key,
	Uid = Uid,
	Race = Race,
	ChaosAppend = ChaosAppend,

	Reducer = Reducer,
	INIT = INIT,
	TR = TR,
	MigDefault = MigDefault,
	MigReducer = MigReducer,

	FoldRecord = FoldRecord,
	GrantOp = GrantOp,
	HeldSum = HeldSum,
})
