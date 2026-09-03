--!strict
--!optimize 2

--[=[

	Buffers: One rule per promise Ledger makes about a buffer in state.

	A buffer survives a write and a read byte for byte, and lives through a compaction. It costs what
	the datastore charges for it. Ledger copies one rather than sharing it between keys.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau
--]=]

local Suite = require("../Suite")

local Json = require("../../src/Mock/Json")

local Measure = require("../../src/Encode/Measure")
local Storable = require("../../src/Encode/Storable")
local Reconcile = require("../../src/Record/Reconcile")
local TableUtil = require("../../src/Util/TableUtil")

type Case = Suite.Case
type Fixture = Suite.Fixture

local Cases = Suite.File("Buffers")

local function Bytes(Text: string): buffer
	return buffer.fromstring(Text)
end

local function Noise(Size: number): buffer
	local Held = buffer.create(Size)
	for Index = 0, Size - 1 do
		local Mixed = bit32.bxor(Index, bit32.rshift(Index, 16))
		Mixed = bit32.band(Mixed * 0x85EBCA6B, 0xFFFFFFFF)
		Mixed = bit32.bxor(Mixed, bit32.rshift(Mixed, 13))
		Mixed = bit32.band(Mixed * 0xC2B2AE35, 0xFFFFFFFF)
		buffer.writeu8(Held, Index, bit32.band(bit32.bxor(Mixed, bit32.rshift(Mixed, 16)), 255))
	end
	return Held
end

local function Keeps(State: any, Op: any): any?
	if Op.Kind ~= "Stash" then
		return nil
	end

	local Next = table.clone(State)
	Next.Blob = Op.Blob
	Next.Count = State.Count + 1
	return Next
end

local function Stashing(T: Case, Node: string?): Fixture
	return T:Store({ Default = { Count = 0 }, Reducer = Keeps, Node = Node })
end

Cases.Case("the disk holds a buffer the way the real store does", function(T: Case)
	local Store = T:Store({ Default = { Count = 0 }, Reducer = Keeps })

	local Blob = buffer.create(5)
	buffer.writeu8(Blob, 0, 0)
	buffer.writeu8(Blob, 1, 255)
	buffer.writeu8(Blob, 2, 34)
	buffer.writeu8(Blob, 3, 92)
	buffer.writeu8(Blob, 4, 65)

	local Wrote = (Store.Store:Edit("k", "Stash", { Blob = Blob }):Wait())
	local State: any = Store:State("k")
	local Read: { number } = {}
	if typeof(State.Blob) == "buffer" then
		for Index = 0, buffer.len(State.Blob) - 1 do
			table.insert(Read, buffer.readu8(State.Blob, Index))
		end
	end

	T:Is("an op carrying a buffer", Wrote, true)
	T:Is("what comes back out", typeof(State.Blob), "buffer")
	T:Is("bytes json could never carry raw", table.concat(Read, ","), "0,255,34,92,65")
end)

Cases.Case("a default buffer is copied rather than shared", function(T: Case)
	local Blob = Bytes("original")
	local Defaults = { Blob = Blob }

	local One = Reconcile(Defaults, {})
	local Two = Reconcile(Defaults, {})

	T:Is("two keys filled from one default share a buffer", rawequal(One.Blob, Two.Blob), false)
	T:Is("a key is handed the default's own buffer", rawequal(One.Blob, Blob), false)

	buffer.writestring(One.Blob, 0, "CHANGED!")

	T:Is("the default after one key writes into its buffer", buffer.tostring(Blob), "original")
	T:Is("the other key after one key writes into its buffer", buffer.tostring(Two.Blob), "original")
end)

Cases.Case("two fresh keys never share a default buffer", function(T: Case)
	local Store = T:Store({ Default = { Blob = Bytes("pristine"), Count = 0 }, Reducer = Keeps })

	local One: any = Store:State("a")
	local Two: any = Store:State("b")

	T:Is("a default holding a buffer builds", One ~= nil, true)
	T:Is("two unwritten keys share the buffer", rawequal(One.Blob, Two.Blob), false)

	buffer.writestring(One.Blob, 0, "XX")

	T:Is("the other key after one writes into its buffer", buffer.tostring(Two.Blob), "pristine")
	T:Is("a third key read afterwards", buffer.tostring((Store:State("c") :: any).Blob), "pristine")
end)

Cases.Case("a state holding a buffer is storable", function(T: Case)
	local Ok, Why = Storable.Value({ Gold = 1, Blob = Bytes("payload") })
	local Fine = Storable.Op({ Id = "a", Kind = "Stash", Blob = Bytes("payload") })

	T:Is("a state holding a buffer", Ok, true)
	T:Is("with no complaint", Why, nil)
	T:Is("an op carrying one", Fine, true)
end)

Cases.Case("a buffer costs what the datastore charges for it", function(T: Case)
	local Small = Measure(Bytes(string.rep("x", 30)))
	local Large = Measure(Bytes(string.rep("x", 3000)))

	T:Is("a 30 byte buffer is not free", Small > 30, true)
	T:Is("a 3000 byte buffer costs about four thirds of it", Large > 4000 and Large < 4100, true)
	T:Is("a bigger buffer costs more", Large > Small, true)
end)

Cases.Case("copying state copies the buffer rather than sharing it", function(T: Case)
	local Blob = Bytes("original")
	local Copy = TableUtil.DeepCopy({ Blob = Blob })

	buffer.writeu8(Copy.Blob, 0, 88)

	T:Is("the copy is a different buffer", Copy.Blob ~= Blob, true)
	T:Is("writing to the copy left the original alone", buffer.tostring(Blob), "original")
	T:Is("and the copy carries the same bytes it started with", buffer.len(Copy.Blob), 8)
end)

Cases.Case("a buffer survives a write and a read", function(T: Case)
	local Store = Stashing(T)
	local Payload = string.rep("packed bytes ", 40)

	local Ok, Why = Store.Store:Edit("k", "Stash", { Blob = Bytes(Payload) }):Wait()
	local State: any = Store:State("k")

	T:Is("the write", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("what came back", typeof(State.Blob), "buffer")
	T:Is("byte for byte", buffer.tostring(State.Blob), Payload)
	T:Is("the reducer ran", State.Count, 1)
end)

Cases.Case("a buffer folds the same on every server", function(T: Case)
	local First = Stashing(T, "node1")
	local Second = Stashing(T, "node2")
	local Payload = "shared bytes"

	First.Store:Edit("k", "Stash", { Blob = Bytes(Payload) }):Wait()

	local Here: any = First:State("k")
	local There: any = Second:State("k")

	T:Is("the writing server reads it", buffer.tostring(Here.Blob), Payload)
	T:Is("so does another one", buffer.tostring(There.Blob), Payload)
	T:Is("and they agree on the count", Here.Count, There.Count)
end)

Cases.Case("a buffer on a record survives compaction", function(T: Case)
	local Store = Stashing(T)

	for Index = 1, 40 do
		Store.Store:Edit("k", "Stash", { Blob = Bytes(`payload {Index}`) }):Wait()
	end
	Store:Log():Compact("k", Store:Format())

	local State: any = Store:State("k")

	T:Is("ops left after compaction", #Store:Record("k").Ops, 0)
	T:Is("the buffer is in the snapshot", typeof(State.Blob), "buffer")
	T:Is("holding the last thing written", buffer.tostring(State.Blob), "payload 40")
	T:Is("and the count survived", State.Count, 40)
end)

Cases.Case("a compressible buffer is charged what it compresses to", function(T: Case)
	local Store = Stashing(T)
	local Flat = Bytes(string.rep("x", 1024 * 1024))

	local Ok = Store.Store:Edit("k", "Stash", { Blob = Flat }):Wait()
	local State: any = Store:State("k")

	T:Is("a megabyte zstd crushes is charged nothing like its raw size", Measure(Flat) < 4096, true)
	T:Is("so the write the raw size would have refused goes through", Ok, true)
	T:Is("and the bytes come back whole", buffer.len(State.Blob), 1024 * 1024)
end)

Cases.Case("a buffer past the op cap is still refused", function(T: Case)
	local Store = Stashing(T)
	local Fat = Noise(1536 * 1024)

	local Ok = Store.Store:Edit("k", "Stash", { Blob = Fat }):Wait()

	T:Is("an op whose buffer is past the per op cap", Ok, false)
	T:Warns("it said why", "per op limit")
end)

Cases.Case("the fake datastore compresses a buffer the way a real one charges for it", function(T: Case)
	local Size = 64 * 1024
	local Held = buffer.create(Size)
	for Index = 0, Size - 1 do
		buffer.writeu8(Held, Index, 97)
	end

	local Stored = #Json.Encode({ b = Held })

	T:Is("the stored value is far smaller than the raw bytes", Stored < Size // 100, true)
	T:Is("and it still reads back as the buffer that went in", buffer.len(Json.Decode(Json.Encode({ b = Held })).b), Size)
end)

return Cases
