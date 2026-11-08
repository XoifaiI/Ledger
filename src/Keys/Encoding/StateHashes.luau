--!strict
--!optimize 2

--[=[
	StateHashes: what this server knows of the texts of a vetted state it wrote or read, kept as a length and BLAKE3
	digests and never as the text, so a transform can tell a stored buffer is that state's without decoding it.

	Canonical is the digest of CanonicalJson(State), kept for a state this server wrote. Read is the digest of a text
	JSONDecode reads as exactly State's content: a decoded text by construction, or a written one whose leaves all
	read back (Json). Equal digests and lengths stand for equal bytes: BLAKE3 collisions are taken as never seen, and
	a digest never leaves the server. Only a vetted state keeps a record, and a record ends with its state.

	Return type: A table with KeepWritten, KeepRead and Match.
	Example usage:
		local Held, IsCanonical = StateHashes.Match(Candidates, buffer.len(Stored), Encoding.Blake3(Stored))
--]=]

local Vetted = require("./Vetted")

type Tree = { [unknown]: unknown }

type Hashes = {
	read Bytes: number,
	read Canonical: string?,
	read Read: string?,
}

local Kept = setmetatable({} :: { [Tree]: Hashes }, { __mode = "k" })

local function KeepWritten(State: Tree, Bytes: number, Digest: string, ReadsBack: boolean): ()
	if not Vetted.IsVetted(State) then
		return
	end
	Kept[State] = { Bytes = Bytes, Canonical = Digest, Read = if ReadsBack then Digest else nil }
end

local function KeepRead(State: Tree, Bytes: number, Digest: string): ()
	if not Vetted.IsVetted(State) then
		return
	end
	Kept[State] = { Bytes = Bytes, Canonical = nil, Read = Digest }
end

local function Match(Candidates: { Tree }?, Bytes: number, Digest: string): (Tree?, boolean)
	if Candidates == nil then
		return nil, false
	end
	for _, Candidate in Candidates do
		local Hashes = Kept[Candidate]
		if Hashes ~= nil and Hashes.Bytes == Bytes and Hashes.Read == Digest then
			return Candidate, Hashes.Canonical == Digest
		end
	end
	return nil, false
end

return {
	KeepWritten = KeepWritten,
	KeepRead = KeepRead,
	Match = Match,
}
