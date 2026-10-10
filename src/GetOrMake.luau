--!strict
--!optimize 2

--[=[
	GetOrMake: the value a map holds at a key, made and kept by the caller's constructor when the key has none.

	Return type: A plain table with the one function.
	Example usage:
		local Views = GetOrMake.GetOrMake(State.Views, "Shop", NewScopes)
--]=]

local function GetOrMake<Key, Held>(Map: { [Key]: Held }, At: Key, New: () -> Held): Held
	local Known = Map[At]
	if Known ~= nil then
		return Known
	end
	local Made = New()
	Map[At] = Made
	return Made
end

return {
	GetOrMake = GetOrMake,
}
