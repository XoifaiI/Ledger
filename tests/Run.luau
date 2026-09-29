--!strict

--[=[

	Run: Runs every suite under tests with Zune's test runner.

	Each suite adds its cases when it is required. Zune prints each case and the count, and exits
	non zero when any fails.

	Return type: Nothing.
	Example usage:
		zune test tests/Run.luau
--]=]

require("./Adapters")
require("./Answer")
require("./Canon")
require("./Encode")
require("./Errors")
require("./Future")
require("./Lru")
require("./Machine")
require("./Observer")
require("./Queue")
require("./Value")
