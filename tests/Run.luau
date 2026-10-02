--!strict

--[=[

	Run: Runs every suite under tests with Zune's test runner.

	Each suite adds its cases when it is required. Zune prints each case and the count, and exits
	non zero when any fails.

	Return type: Nothing.
	Example usage:
		zune test tests/Run.luau
--]=]

require("./Answer")
require("./Book")
require("./Build")
require("./Canon")
require("./Cuts")
require("./Dispatch")
require("./Encode")
require("./Errors")
require("./Future")
require("./Hash")
require("./Lru")
require("./Number")
require("./Observer")
require("./Ops")
require("./Reads")
require("./Queue")
require("./Reduce")
require("./Save")
require("./Session")
require("./Step")
require("./Terms")
require("./Totals")
require("./Copies")
require("./Parts")
require("./Walk")
require("./Split")
require("./Touch")
require("./Transaction")
require("./Unblock")
require("./Work")
require("./Value")
