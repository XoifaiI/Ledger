--!strict
--!optimize 2

--[=[
	KeyPages: the pager Store:Keys gives, over ListKeysAsync on the store's own DataStore and scope. Next asks for one
	page a request and keeps no list. Ledger's own keys are left out, so a page can be empty. It answers nil, nil after
	the last page, nil, Unresolved on a failed fetch (retried, no page skipped), nil, Closed after CloseAll begins.

	Return type: The KeyPages class.
	Example usage:
		local Pages = Vault:Keys()
		local Page, Why = Pages:Next()
--]=]

local Args = require("./Validate/Args")
local Keys = require("./Validate/Keys")
local Reasons = require("../Constants/Reasons")
local Runner = require("../Shell/Runner")
local Services = require("../Shell/Services")
local ShellSetup = require("../Shell/Setup")
local Stores = require("./Validate/Stores")
local Types = require("../Types")

type KeysPage = Services.KeysPage
type KeysResult = Services.KeysResult
type KeysMode = ShellSetup.KeysMode
type Reason = Types.Reason
type Settings = ShellSetup.Settings

type KeyPagesData = {
	read Store: unknown,
	read Settings: Settings,
	Latest: KeysPage?,
	IsAdvanced: boolean,
}

local NextWhere = "KeyPages:Next"

local function GameKeysOf(Mode: KeysMode, Names: { string }): { string | number }
	local Listed: { string | number } = {}
	for _, Name in Names do
		local Key = Keys.ListedKeyOf(Mode, Name)
		if Key ~= nil then
			table.insert(Listed, Key)
		end
	end
	return Listed
end

local KeyPages = {}
KeyPages.__index = KeyPages

export type KeyPages = setmetatable<KeyPagesData, typeof(KeyPages)>

function KeyPages.New(Store: unknown, Settings: Settings): KeyPages
	local Data: KeyPagesData = { Store = Store, Settings = Settings, Latest = nil, IsAdvanced = false }
	return setmetatable(Data, KeyPages)
end

local function Settled(self: KeyPages, Fetched: KeysResult): ({ string | number }?, Reason?)
	if Fetched.Kind == "Err" then
		return nil, Reasons.Unresolved
	end
	self.Latest = Fetched.Page
	self.IsAdvanced = false
	return GameKeysOf(self.Settings.Keys, Fetched.Page.Names), nil
end

function KeyPages.Next(self: KeyPages): ({ string | number }?, Reason?)
	Args.OutsideStep(NextWhere)
	local Settings = self.Settings
	Stores.CheckLive(self.Store, Settings.Name)
	Args.OutsideListener(NextWhere)
	if Runner.IsClosing() then
		return nil, Reasons.Closed
	end
	local Latest = self.Latest
	if Latest == nil then
		return Settled(self, Services.ListKeys(Settings.Name, ShellSetup.StoreScope))
	end
	if Latest.IsLast then
		return nil, nil
	end
	if not self.IsAdvanced then
		if Services.AdvanceKeys(Latest.Pages).Kind ~= "Ok" then
			return nil, Reasons.Unresolved
		end
		self.IsAdvanced = true
	end
	return Settled(self, Services.ReadKeys(Latest.Pages))
end

return KeyPages
