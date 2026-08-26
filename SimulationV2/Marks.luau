--!strict
--!optimize 2

--[=[
	Marks: Counts which of the situations that Ledger describes a run reached.

	Ordinary coverage says a line ran. A mark says the situation the message exists to describe was
	reached. A mark nothing reaches is either a message to delete or a case to test.
	One line can hold more than one fragment, so the longest match counts.

	A message that carries ACCUSED is Ledger blaming itself.

	Return type: A table with New, FRAGMENTS and ACCUSED. The type is Marks.
	Example usage:
		local Sheet = Marks.New()
		Sheet:Note(Message)
--]=]

local Marks = {}
Marks.__index = Marks

export type Marks = typeof(setmetatable(
	{} :: {
		Counts: { [string]: number },
		Order: { string },
		Unknown: number,
	},
	Marks
))

export type Folded = {
	Counts: { [string]: number },
	Unknown: number,
}

local ACCUSED = "this is a bug in Ledger"

local FRAGMENTS: { { Name: string, Says: string } } = {
	{ Name = "LoadFailedHandled", Says = "said it handled" },
	{ Name = "LoadedTwice", Says = "already has a live session" },
	{ Name = "LoadingTwice", Says = "is already loading" },
	{ Name = "LoadRaced", Says = "was loaded twice concurrently" },
	{ Name = "AutosaveFailing", Says = "keeps failing, the datastore is probably down" },
	{ Name = "AutosaveStarved", Says = "autosave(s) skipped" },

	{ Name = "OpInvalid", Says = "rejected op" },
	{ Name = "CommitInvalid", Says = "rejected commit" },
	{ Name = "EditInvalid", Says = "Edit rejected op" },
	{ Name = "TxLegInvalid", Says = "Tx rejected leg" },
	{ Name = "SessionClosed", Says = "that session closed when the player left" },
	{ Name = "Backlogged", Says = "unsaved ops have hit the" },
	{ Name = "StateCapped", Says = "byte cap and the op would make it bigger" },
	{ Name = "ParkedRefusal", Says = "only holds if that transaction" },
	{ Name = "ManyParked", Says = "more than one transaction is parked" },

	{ Name = "CompactBlocked", Says = "cannot be compacted, its oldest op is a" },
	{ Name = "CompactKept", Says = "op(s) through compaction" },
	{ Name = "CompactUnstorable", Says = "your reducer built state a datastore cannot hold" },
	{ Name = "Swelling", Says = "ops it cannot compact away" },
	{ Name = "NearValueCap", Says = "saves will start failing if it keeps growing" },
	{ Name = "NearStateCap", Says = "take out what the game no longer reads" },

	{ Name = "TransferSpent", Says = "already went through for a different amount" },
	{ Name = "TransferAmountChanged", Says = "so that is what it pays out" },
	{ Name = "TransferOwnedByRecovery", Says = "recovery owns it now" },
	{ Name = "TransferStranded", Says = "took the money but could not hand it over" },
	{ Name = "RedeliverFailed", Says = "could not send transfer" },
	{ Name = "RefundFailed", Says = "could not give back transfer" },
	{ Name = "TransferWrittenOff", Says = "a refund could pay them twice" },
	{ Name = "TransfersBacklogged", Says = "unfinished transfers, so" },
	{ Name = "TransferOnBothKeys", Says = "was not settled, so the money is on both keys" },

	{ Name = "BookingLate", Says = "has run past its hold" },
	{ Name = "BookingNoTo", Says = "was not reserved with a To" },
	{ Name = "BookingHanding", Says = "is being handed to another key" },
	{ Name = "BookingElsewhere", Says = "that came from somewhere else" },
	{ Name = "BookingWrittenOff", Says = "giving it back could pay twice" },
	{ Name = "BookingsBacklogged", Says = "overdue reservations" },
	{ Name = "BookingsSettleFailed", Says = "overdue reservation(s) on" },
	{ Name = "BookingCheckFailed", Says = "before giving back booking" },

	{ Name = "TxSpent", Says = "could not get through and changed nothing" },
	{ Name = "TxMismatch", Says = "was already used for different keys" },
	{ Name = "TxSplit", Says = "only half remembered across its keys" },
	{ Name = "TxUnanswered", Says = "has no answer yet and might still go through" },
	{ Name = "TxLegFull", Says = "cannot put a leg on" },
	{ Name = "TxHomesFull", Says = "transaction homes" },

	{ Name = "Behind", Says = "finish the deploy" },
	{ Name = "SessionBehind", Says = "now needs a newer build than this server has" },
	{ Name = "ErasedWhileLive", Says = "was erased and something wrote to it anyway" },
	{ Name = "ErasedInServer", Says = "while they are still in this server" },
	{ Name = "ErasedBalance", Says = "destroyed" },
	{ Name = "ErasedInFlight", Says = "had not finished, so that money is gone for good" },
	{ Name = "SessionErased", Says = "was erased while this session was live" },
	{ Name = "SweepGaveUp", Says = "gave up retrying" },
	{ Name = "SweepFull", Says = "recovery sweep is already following" },
	{ Name = "NotDeterministic", Says = "is not deterministic" },
	{ Name = "ReducerWroteOwn", Says = "your reducer wrote its own" },
	{ Name = "OnMock", Says = "is on a fake datastore" },
	{ Name = "MockReused", Says = "UseMock was called again" },

	{ Name = "LoadFailed", Says = "could not load '" },
	{ Name = "SettleFoldSkipped", Says = "so this fold leaves it out" },
	{ Name = "SettleDuringWrite", Says = "during a write, so it stays pending" },
	{ Name = "CommitStuck", Says = "answered while a transaction was stuck" },
	{ Name = "FlushFailed", Says = "its ops stay pending and the next flush" },
	{ Name = "SessionCompactFailed", Says = "so its log just stays long for now" },
	{ Name = "ReleaseOnErased", Says = "wrote nothing, that key was erased" },
	{ Name = "ReleaseLost", Says = "unsaved op(s) die with this server" },
	{ Name = "CompactFailed", Says = "your write went through fine, the log just stays long" },
	{ Name = "TxLegFields", Says = "passed Id or Kind in its fields" },
	{ Name = "OpFields", Says = "passed Id, Kind or OnceAt in its fields" },
	{ Name = "ReapFailed", Says = "could not tidy up the transaction markers" },
	{ Name = "EraseUnread", Says = "but could not read back what was on it" },
	{ Name = "EraseUncheckedTransfers", Says = "for unfinished transfers before erasing it" },
	{ Name = "EraseHandoverFailed", Says = "before erasing it, they are counted below" },
	{ Name = "EraseRecheckFailed", Says = "again after finishing its transfers" },
	{ Name = "TransferBroke", Says = "broke inside Ledger: " },
	{ Name = "TxBroke", Says = "broke inside Ledger and its legs" },
	{ Name = "OnLoadFailedThrew", Says = "OnLoadFailed threw" },
	{ Name = "WriteFull", Says = "carrying more unsaved ops than it can hold" },
	{ Name = "WriteStateFull", Says = "byte state cap and this would make it bigger" },
	{ Name = "WriteUnreadable", Says = "could not read the record back to say what it folded to" },
	{ Name = "WriteUnsure", Says = "though it might still have gone through" },
	{ Name = "ClockUnits", Says = "the clock you gave reads" },

	{ Name = "RetryAttempt", Says = "RetryAsync attempt" },
	{ Name = "FutureThrew", Says = "Future callback errored" },
	{ Name = "ObserverThrew", Says = "Observer listener errored" },
	{ Name = "ObserverSlow", Says = "an Observer listener has run for" },
	{ Name = "IntervalThrew", Says = "SetInterval callback errored" },
	{ Name = "QueueTakenOver", Says = "ThreadQueue took over" },

	{ Name = "CouldNot", Says = "could not " },
}

local RANKED: { { Name: string, Says: string, At: number } } = {}
for Index, Held in FRAGMENTS do
	table.insert(RANKED, { Name = Held.Name, Says = Held.Says, At = Index })
end
table.sort(RANKED, function(Left: { Name: string, Says: string, At: number }, Right: { Name: string, Says: string, At: number }): boolean
	if #Left.Says ~= #Right.Says then
		return #Left.Says > #Right.Says
	end
	return Left.At < Right.At
end)

function Marks.New(): Marks
	local Counts: { [string]: number } = {}
	local Order: { string } = {}
	for _, Held in FRAGMENTS do
		Counts[Held.Name] = 0
		table.insert(Order, Held.Name)
	end

	return setmetatable({ Counts = Counts, Order = Order, Unknown = 0 }, Marks)
end

function Marks.Note(self: Marks, Message: string, Count: number?)
	if string.find(Message, "Ledger: ", 1, true) == nil then
		return
	end

	local Times = Count or 1
	for _, Held in RANKED do
		if string.find(Message, Held.Says, 1, true) ~= nil then
			self.Counts[Held.Name] += Times
			return
		end
	end

	self.Unknown += Times
end

function Marks.Missed(self: Marks): { string }
	local Held: { string } = {}
	for _, Name in self.Order do
		if self.Counts[Name] == 0 then
			table.insert(Held, Name)
		end
	end
	return Held
end

function Marks.Merge(self: Marks, Other: Folded)
	for Name, Count in Other.Counts do
		self.Counts[Name] = (self.Counts[Name] or 0) + Count
	end
	self.Unknown += Other.Unknown
end

function Marks.Report(self: Marks): string
	local Reached = 0
	for _, Name in self.Order do
		if self.Counts[Name] > 0 then
			Reached += 1
		end
	end
	return `{Reached}/{#self.Order} marks reached, {self.Unknown} warning(s) matched none of them`
end

table.freeze(Marks)

return table.freeze({
	New = Marks.New,
	FRAGMENTS = FRAGMENTS,
	ACCUSED = ACCUSED,
})
