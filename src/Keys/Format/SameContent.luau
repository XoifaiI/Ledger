--!strict
--!optimize 2

--[=[
	SameContent: whether a decoded game state has the content of the key's candidate, the state this server last
	landed or loaded for it, so a write's transform can read the stored state as the candidate itself.

	Equal means the same keys, a number key never matching a string key, and the same values: strings by bytes,
	numbers by Json.SameValue, so -0 never matches 0 and NaN matches nothing. A decoded table with a
	metatable never matches. Matching checks that the candidate is vetted itself, whatever its caller kept: that is
	what makes the kept key counts true and keeps the walk within the candidate's depth.

	Return type: A table with Matching.
	Example usage:
		local Same = SameContent.Matching(Decoded, Candidate) --> the candidate when equal, else nil
--]=]

local Json = require("../Encoding/Json")
local Vetted = require("../Encoding/Vetted")

type Tree = { [unknown]: unknown }

local function SameContent(Decoded: unknown, Candidate: Tree): boolean
	if type(Decoded) ~= "table" or getmetatable(Decoded) ~= nil then
		return false
	end
	local Count = 0
	for Key, Inner in Decoded :: Tree do
		Count += 1
		local Other = Candidate[Key]
		if Inner == Other then
			if Inner == 0 and not Json.SameValue(Inner, Other) then
				return false
			end
			continue
		end
		if type(Inner) ~= "table" or type(Other) ~= "table" then
			return false
		end
		if not SameContent(Inner, Other :: Tree) then
			return false
		end
	end
	return Count == Vetted.CountOf(Candidate)
end

local function Matching(Decoded: unknown, Candidate: Tree?): Tree?
	if Candidate == nil or not Vetted.IsVetted(Candidate) then
		return nil
	end
	if not SameContent(Decoded, Candidate) then
		return nil
	end
	return Candidate
end

return {
	Matching = Matching,
}
