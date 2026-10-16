--!strict
--!optimize 2
--!native

--[=[
	Pager: the pages Store:Keys and Store:Versions give, over ListKeysAsync and ListVersionsAsync on the store's own
	DataStore and scope. Next asks for one page a request and keeps no list. Keys leaves Ledger's own keys out, so a
	page can be empty. It answers nil, nil after the last page, nil, Unresolved on a failed fetch (retried, no page
	skipped), nil, Closed after CloseAll begins.

	Return type: The Pager class.
	Example usage:
		local Pages = Pager.Keys(Vault, Settings, "guild:")
		local Page, Why = Pages:Next()
--]=]

local Args = require("./Validate/Args")
local Keys = require("./Validate/Keys")
local Names = require("../Encoding/Names")
local Reasons = require("../Constants/Reasons")
local Runner = require("../Shell/Runner")
local Services = require("../Shell/Services")
local ShellSetup = require("../Shell/Setup")
local Stores = require("./Validate/Stores")
local Types = require("../Types")

type KeysMode = ShellSetup.KeysMode
type KeyVersion = Services.KeyVersion
type Page<Entry> = Services.Page<Entry>
type PageResult<Entry> = Services.PageResult<Entry>
type Reason = Types.Reason
type Settings = ShellSetup.Settings
type StoreKey = Names.StoreKey

type Listing<Entry, Item> = {
	read Where: string,
	read First: () -> PageResult<Entry>,
	read Read: (Pages: Pages) -> PageResult<Entry>,
	read Items: (Entries: { Entry }) -> { Item },
}

type PagerData<Entry, Item> = {
	read Store: unknown,
	read StoreName: string,
	read Listing: Listing<Entry, Item>,
	Latest: Page<Entry>?,
	IsAdvanced: boolean,
}

local KeysWhere = "KeyPages:Next"
local VersionsWhere = "VersionPages:Next"

local function GameKeysOf(Mode: KeysMode, Listed: { string }): { string | number }
	local GameKeys: { string | number } = {}
	for _, Name in Listed do
		local Key = Keys.ListedKeyOf(Mode, Name)
		if Key ~= nil then
			table.insert(GameKeys, Key)
		end
	end
	return GameKeys
end

local function SameVersions(Versions: { KeyVersion }): { KeyVersion }
	return Versions
end

local Pager = {}
Pager.__index = Pager

export type Pager<Entry, Item> = setmetatable<PagerData<Entry, Item>, typeof(Pager)>

local function NewPager<Entry, Item>(Store: unknown, Name: string, Listing: Listing<Entry, Item>): Pager<Entry, Item>
	local Data: PagerData<Entry, Item> =
		{ Store = Store, StoreName = Name, Listing = Listing, Latest = nil, IsAdvanced = false }
	return setmetatable(Data, Pager)
end

local function Settled<Entry, Item>(self: Pager<Entry, Item>, Fetched: PageResult<Entry>): ({ Item }?, Reason?)
	if Fetched.Kind == "Err" then
		return nil, Reasons.Unresolved
	end
	self.Latest = Fetched.Page
	self.IsAdvanced = false
	return self.Listing.Items(Fetched.Page.Entries), nil
end

function Pager.Keys(Store: unknown, Settings: Settings, Prefix: string?): Pager<string, string | number>
	local Listing: Listing<string, string | number> = {
		Where = KeysWhere,
		First = function(): PageResult<string>
			return Services.ListKeys(Settings.Name, ShellSetup.StoreScope, Prefix)
		end,
		Read = Services.ReadKeys,
		Items = function(Listed: { string }): { string | number }
			return GameKeysOf(Settings.Keys, Listed)
		end,
	}
	return NewPager(Store, Settings.Name, Listing)
end

function Pager.Versions(Store: unknown, Settings: Settings, Target: StoreKey): Pager<KeyVersion, KeyVersion>
	local Listing: Listing<KeyVersion, KeyVersion> = {
		Where = VersionsWhere,
		First = function(): PageResult<KeyVersion>
			return Services.ListVersions(Target)
		end,
		Read = Services.ReadVersions,
		Items = SameVersions,
	}
	return NewPager(Store, Settings.Name, Listing)
end

function Pager.Next<Entry, Item>(self: Pager<Entry, Item>): ({ Item }?, Reason?)
	local Listing = self.Listing
	Args.OutsideStep(Listing.Where)
	Stores.CheckLive(self.Store, self.StoreName)
	Args.OutsideListener(Listing.Where)
	if Runner.IsClosing() then
		return nil, Reasons.Closed
	end
	local Latest = self.Latest
	if Latest == nil then
		return Settled(self, Listing.First())
	end
	if Latest.IsLast then
		return nil, nil
	end
	if not self.IsAdvanced then
		if Services.AdvancePages(Latest.Pages).Kind ~= "Ok" then
			return nil, Reasons.Unresolved
		end
		self.IsAdvanced = true
	end
	return Settled(self, Listing.Read(Latest.Pages))
end

return Pager
