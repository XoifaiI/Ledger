--!strict
--!optimize 2

-- every answer Ledger gives when a write does not go through, named in one place so it cant drift from what the code returns

local Types = require("./Types")

type Reason = Types.Reason

return table.freeze({
	Refused = "Refused" :: Reason,
	Busy = "Busy" :: Reason,
	Spent = "Spent" :: Reason,
	Unresolved = "Unresolved" :: Reason,
	Closed = "Closed" :: Reason,
	Backlog = "Backlog" :: Reason,
	Full = "Full" :: Reason,
	Invalid = "Invalid" :: Reason,
	Behind = "Behind" :: Reason,
	Held = "Held" :: Reason
})
