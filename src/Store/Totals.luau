--!strict
--!optimize 2

--[=[
	Totals: Object. The totals a store declares, a bump of one, and its sum.

	Each total's shards are a place of their own, a store whose build is the shard build. A bump with
	no name is minted and goes to this server's home shard. A named bump is timed and goes to the
	shard its name hashes to, so every server sends it to the same key. Every landing on a shard this
	server bumps is taken as that shard's pair, so this server's own bumps show in its next sum with
	no read. Sums gives the sum of every value of a kind's pairs, and a split quantity's stock reads
	it too.

	Return type: The Totals module, and the Declared type.
	Example usage:
		local Reply = Totals.Bump(Held, 5, nil, nil)
--]=]

local Answer = require("../Core/Answer")
local DataStore = require("../Adapters/DataStore")
local Follows = require("./Follows")
local Ops = require("./Ops")
local Queue = require("../Record/Queue")
local Requests = require("../Record/Requests")
local Runner = require("../Machine/Runner")
local Runtime = require("./Runtime")
local Shards = require("../Record/Shards")
local Total = require("../Calls/Total")
local Types = require("../Record/Types")

type Answer = Answer.Answer
type Reply = Queue.Reply

export type Declared = { [string]: Shards.Held }

local Shared = Runtime.Shared
local Hooked: { [Queue.Queue]: true } = setmetatable({}, { __mode = "k" }) :: any

local Totals = {}

function Totals.Declare(Declared: Declared, Store: string, Data: DataStore.Store, Made: Types.Build, Counts: { [string]: number })
	for Name, Count in Counts do
		local Held = Shards.New(Store, Name, Count)
		Declared[Name] = Held
		Shared.Places[Held.Place] = { Store = Data, Build = Shards.Build(Count, Made) }
	end
end

function Totals.Bump(Held: Shards.Held, Amount: number, Name: string?, Stamp: number?): Reply
	local Index = if Name then Shards.Named(Name, Held.Shards) else Shards.Home(Held.Name, Shared:First(), Held.Shards)
	local Kept = Shared:SaveFor({ Store = Held.Place, Key = Shards.Key(Held.Name, Held.Shards, Index) })
	if not Hooked[Kept] then
		Hooked[Kept] = true
		Shared:Landed(Kept):Subscribe(function(Note: Types.Note)
			Shards.Take(Held, Index, Shards.Noted(Note, Held.Kind))
		end)
	end
	local Body = { Add = Amount }
	local Asked: Queue.Asked = if Name
		then {
			Form = Requests.Form.Timed,
			Kind = 0,
			Name = Name,
			Print = Ops.Print({ Total = Held.Name, Amount = Amount }),
			Stamp = Stamp,
			MustExist = false,
			Body = Body,
		}
		else { Form = Requests.Form.Minted, Kind = 0, MustExist = false, Body = Body }
	return (Shared:Send(Kept, Asked))
end

function Totals.Sums(Held: Shards.Held, MaxAge: number): { number } | Answer
	local Found = Runner.Run(Total.Machine, Total.Context(Held, MaxAge, Shared:Server(), Follows.Lapse()), Shared.Places):Wait()
	return if Found == nil then Answer.Unresolved else Found
end

function Totals.Total(Held: Shards.Held, MaxAge: number): number | Answer
	local Found = Totals.Sums(Held, MaxAge)
	return if type(Found) == "table" then Found[1] else Found
end

return Totals
