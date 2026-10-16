--!strict
--!optimize 2

--[=[
	Limits: a store's frozen Limits (record sheet 18.1) from the constants, its options and part build, or all defaults
	for a store-less server (BuildDefault). Each op kind the core can meet has a timed window: the game's, Bump with a
	total, part kinds with a quantity. Shards and parts hold no untimed item; shards no mark or loss.

	Return type: A plain table with Build and BuildDefault.
	Example usage:
		local Limits = Limits.Build(Settings, Setup.PartBuildOf(Settings), Platform.IsStudio())
--]=]

local Book = require("../Stored/Book")
local Cuts = require("../Constants/Cuts")
local Extras = require("../Constants/Extras")
local Hot = require("../Constants/Hot")
local Record = require("../Constants/Record")
local Settable = require("../Constants/Settable")
local Shapes = require("../Shapes")
local ShellSetup = require("./Setup")
local Transaction = require("../Constants/Transaction")

type Build = Shapes.Build
type Limits = Shapes.Limits
type Settings = ShellSetup.Settings

type Windows = { [string]: number }

type StoreTerms = {
	read TimedWindows: Windows,
	read UntimedWindows: Windows,
	read CutWindow: number,
	read OrphanAge: number,
	read SaveInterval: number,
	read IdleReadInterval: number,
}

local KeyKinds = Record.KeyKind

local NoRoom = 0

local NoWindows: Windows = {}
table.freeze(NoWindows)

local function RoomsByKind(Game: number, Shard: number, Part: number): { [string]: number }
	local Rooms: { [string]: number } = {
		[KeyKinds.Game] = Game,
		[KeyKinds.Shard] = Shard,
		[KeyKinds.Part] = Part,
	}
	return table.freeze(Rooms)
end

local function TimedWindowsOf(Settings: Settings, PartBuild: Build): Windows
	local Windows: Windows = {}
	if next(Settings.Totals) ~= nil then
		Windows[Extras.BumpOpKind] = Settable.TimedWindow.Default
	end
	if next(Settings.Quantities) ~= nil then
		for _, OpKind in Hot.PartOpKinds do
			Windows[OpKind] = Settable.TimedWindow.Default
		end
		for OpKind in PartBuild.BalanceOps do
			Windows[OpKind] = Settable.TimedWindow.Default
		end
	end
	for OpKind, Window in Settings.Windows do
		Windows[OpKind] = Window.Timed
	end
	return table.freeze(Windows)
end

local function UntimedWindowsOf(Settings: Settings): Windows
	local Windows: Windows = {}
	for OpKind, Window in Settings.Windows do
		Windows[OpKind] = Window.Untimed
	end
	return table.freeze(Windows)
end

local function LimitsOf(Terms: StoreTerms, IsStudio: boolean): Limits
	return table.freeze({
		FreezeInputs = IsStudio,
		ItemSize = Book.ItemSize,

		Sigma = Record.Sigma,
		Jump = Record.Jump,
		Ahead = Record.Ahead,
		Hold = Record.Hold,
		Ceiling = Record.Ceiling,
		StampMax = Record.StampMax,

		TimedRooms = RoomsByKind(Record.TimedRoom, Record.TimedRoom, Record.TimedRoom),
		UntimedRooms = RoomsByKind(Record.UntimedRoom, NoRoom, NoRoom),
		WorkRooms = RoomsByKind(Record.WorkRoom, NoRoom, Record.WorkRoom),
		LossRooms = RoomsByKind(Record.LossRoom, NoRoom, Record.LossRoom),
		CutNamesKept = Record.CutNamesKept,
		MarkCap = Record.MarkCap,
		OwedCap = Record.OwedCap,
		FatesMax = Record.FatesMax,
		PostCap = Record.PostCap,
		BookMax = Record.BookMax,
		StateCap = Record.StateCap,
		StateWarnBytes = Record.StateWarnBytes,

		MintedWindow = Record.MintedWindow,
		TimedWindows = Terms.TimedWindows,
		UntimedWindows = Terms.UntimedWindows,
		CutWindow = Terms.CutWindow,
		WindowUnit = Record.WindowUnit,
		KeepNamed = Cuts.KeepNamed,
		FoldSpan = Cuts.FoldSpan,
		SlotSpans = Cuts.SlotSpans,
		FoldSlotsMost = Cuts.FoldSlotsMost,
		SealAge = Cuts.SealAge,
		RemoveSend = Cuts.RemoveSend,
		OrphanAge = Terms.OrphanAge,
		PinEvictAge = Record.PinEvictAge,
		HoldSlack = Hot.HoldSlack,

		SequenceMax = Record.SequenceMax,
		HorizonCacheKeys = Record.HorizonCacheKeys,
		SentNamesKept = Record.SentNamesKept,
		ShownKeysMax = Record.ShownKeysMax,
		UnservedShowableKeys = Record.UnservedShowableKeys,
		ShownBitCount = Record.ShownBitCount,
		CounterKeyCount = Record.CounterKeyCount,

		OpBound = Record.OpBound,
		EraseBound = Cuts.EraseBound,
		ResetBound = Cuts.ResetBound,
		ShutdownSeconds = Record.ShutdownSeconds,
		ErrorsBeforeUnresolved = Record.ErrorsBeforeUnresolved,
		RetryGapFirst = Record.RetryGapFirst,
		RetryGapMost = Record.RetryGapMost,
		GapLeast = Extras.GapLeast,
		GapMost = Extras.GapMost,
		QueueOpsMax = Record.QueueOpsMax,
		QueueWait = Record.QueueWait,
		QueueRoomOps = Record.QueueRoomOps,
		QueueRoomBytes = Record.QueueRoomBytes,
		NewTimedBytesMax = Record.NewTimedBytesMax,
		SaveInterval = Terms.SaveInterval,
		IdleReadInterval = Terms.IdleReadInterval,

		SettleAge = Transaction.SettleAge,
		MaxAttempts = Transaction.MaxAttempts,
		RetryRounds = Transaction.RetryRounds,
		OwedRecordsVerified = Transaction.OwedRecordsVerified,
		GameOpMarksMost = Transaction.GameOpMarksMost,
		TouchLevels = Transaction.TouchLevels,
		TouchStep = Transaction.TouchStep,
		HoldDrop = Transaction.HoldDrop,
		FoldWindow = Transaction.FoldWindow,
	})
end

local function Build(Settings: Settings, PartBuild: Build, IsStudio: boolean): Limits
	return LimitsOf({
		TimedWindows = TimedWindowsOf(Settings, PartBuild),
		UntimedWindows = UntimedWindowsOf(Settings),
		CutWindow = Settings.CutWindow,
		OrphanAge = Settings.OrphanAge,
		SaveInterval = Settings.SaveInterval,
		IdleReadInterval = Settings.IdleReadInterval,
	}, IsStudio)
end

local function BuildDefault(IsStudio: boolean): Limits
	return LimitsOf({
		TimedWindows = NoWindows,
		UntimedWindows = NoWindows,
		CutWindow = Settable.CutWindow.Default,
		OrphanAge = Settable.OrphanAge.Default,
		SaveInterval = Settable.SaveInterval.Default,
		IdleReadInterval = Settable.IdleReadInterval.Default,
	}, IsStudio)
end

return {
	Build = Build,
	BuildDefault = BuildDefault,
}
