--!strict
--!optimize 2

--[=[
	Record: the numbers and texts of the record that have a meaning. Seconds unless a name says bytes or a
	count. The map from each name to the design's is the record sheet's section 1.

	Return type: A frozen table of the constants, and the KeyKind type.
	Example usage:
		local Record = require("./Constants/Record")
		local Cap = Record.StateCap
--]=]

local SecondsPerMinute = 60
local SecondsPerHour = 60 * SecondsPerMinute
local SecondsPerDay = 24 * SecondsPerHour
local BytesPerKiB = 1024
local BytesPerMiB = 1024 * BytesPerKiB
local BitsPerByte = 8

local Late = 60
local Delay = 15
local Sigma = 30
local SkewSigmas = 2
local Ceiling = 30 * SecondsPerDay

local Ahead = SkewSigmas * Sigma

local Hold = Ahead + SkewSigmas * Sigma

local Jump = 5
local ShutdownSeconds = 30

local StampMax = 2 ^ 40
local DrawnNumberLimit = 2 ^ 40
local StampEpoch = 1767225600

local Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local WindowUnit = SecondsPerMinute

local VarintDigitBase = 32
local VarintLimit = 2 ^ 53

local TimedRoom = 12288
local UntimedRoom = 4096
local WorkRoom = 8192

local LossRoom = 4096

local CutNamesKept = 8

local EntryMax = 300
local ItemMax = 96
local MarkMax = 512
local PostCap = 4096
local GateMax = 90

local FatesMax = 64
local MarkCap = 16
local OwedCap = 16
local MoneyMax = 64

local EventFixedBytes = 79
local EventBytesPerField = 13
local SlotFixedBytes = 14
local SlotBytesPerField = 20
local EventMax = EventFixedBytes + EventBytesPerField * MoneyMax
local SlotMax = SlotFixedBytes + SlotBytesPerField * MoneyMax

local ValueFramingBytes = 144
local PostFramingBytes = 8
local BookMax = ValueFramingBytes
	+ TimedRoom
	+ LossRoom
	+ CutNamesKept * ItemMax
	+ UntimedRoom
	+ WorkRoom
	+ GateMax
	+ (PostCap + PostFramingBytes)

local DataStoreValueMax = 4 * BytesPerMiB
local StateCap = DataStoreValueMax - BookMax

local NameMax = 64

local StateWarnBytes = 2 * BytesPerMiB

local CounterKeyCount = 16

local KeyKind = {
	Game = "Game" :: "Game",
	Shard = "Shard" :: "Shard",
	Part = "Part" :: "Part",
}

export type KeyKind = keyof<typeof(KeyKind)>

local SequenceMax = 32767
local FirstSequence = 1
local MigrationsMax = 2 ^ 20
local HorizonCacheKeys = 4096
local SentNamesKept = 4096
local ShownKeysMax = 4096
local ShownBitCount = 65536
local UnservedShowableKeys = 256

local TimedWindowLeast = Late + Delay + SkewSigmas * Sigma + 1
local UntimedWindowLeast = SkewSigmas * Sigma + Delay + 1

local MintedWindow = 180

local OpBound = 30
local ErrorsBeforeUnresolved = 3

local PinEvictAge = OpBound + SkewSigmas * Sigma

local RetryGapFirst = 2
local RetryGapMost = 16

local QueueOpsMax = 4096
local QueueWait = 10
local QueueRoomOps = 4096
local QueueRoomBytes = 1.5 * BytesPerMiB

local NewTimedShare = 4
local NewTimedBytesMax = TimedRoom / NewTimedShare

local StorableDepthMax = 64
local UnknownKindProbe = "Ledger.UnknownKindProbe"

local WideLowDigits = 7
local WideLimb = VarintDigitBase ^ WideLowDigits

local BookVersion = 0
local IdentityFlag = 1
local GateFlag = 2
local BookFlagsMost = IdentityFlag + GateFlag
local EncodeStartBytes = 1024

local FateCode = table.freeze({
	Took = 0,
	Refused = 1,
	Full = 2,
	AbortedFirst = 3,
	FencedFirst = 6,
	FencedFinalFirst = 9,
	TookWith = 12,
	RefusedFor = 13,
	Cut = 14,
})
local NamedKindBase = 16
local WriterEntryHead = 0

local EventCauseByte = table.freeze({
	Reset = string.byte("R"),
	Erase = string.byte("E"),
})

local ReturnCauseByte = table.freeze({
	Returned = string.byte("T"),
	Orphan = string.byte("O"),
})

local ReturnEscrowByte = table.freeze({
	None = string.byte("N"),
	Some = string.byte("Y"),
})

local SlotByte = string.byte("F")

local WorkKind = table.freeze({
	Escrow = 0,
	Exclusive = 1,
	Pinned = 2,
	PinnedValue = 3,
})
local WorkKindMask = 3
local WorkCleanBit = 4
local WorkSignOrSlotBit = 8
local WorkSubBit = 16
local WorkForeignBit = 32

local SealVersion = 0

local ShardKeyPrefix = "$T:"
local PartKeyPrefix = "$P:"
local KeyNameBytesMost = 37
local KeyBytesMost = 50
local StoreNameBytesMost = 50
local CounterStore = "Ledger$N"
local CounterScope = "global"
local MapCount = 16
local SummaryMapPrefix = "Ledger_Total_"
local CopyMapPrefix = "Ledger_Copy_"
local SummaryKeyPrefix = "t/"
local CopyKeyPrefix = "c/"

local ItemVersionKey = "v"
local ItemHolderKey = "hd"
local ItemUntilKey = "un"
local ItemAtKey = "at"
local SummaryVersion = 1
local CopyVersion = 1
local SummaryShardWidth = 2
local SummaryPartWidth = 6
local PartsMax = 4

return table.freeze({
	SecondsPerMinute = SecondsPerMinute,
	SecondsPerHour = SecondsPerHour,
	SecondsPerDay = SecondsPerDay,
	BytesPerKiB = BytesPerKiB,
	BytesPerMiB = BytesPerMiB,
	BitsPerByte = BitsPerByte,
	Late = Late,
	Delay = Delay,
	Sigma = Sigma,
	SkewSigmas = SkewSigmas,
	Ceiling = Ceiling,
	Ahead = Ahead,
	Hold = Hold,
	Jump = Jump,
	ShutdownSeconds = ShutdownSeconds,
	StampMax = StampMax,
	DrawnNumberLimit = DrawnNumberLimit,
	StampEpoch = StampEpoch,
	Alphabet = Alphabet,
	WindowUnit = WindowUnit,
	VarintDigitBase = VarintDigitBase,
	VarintLimit = VarintLimit,
	TimedRoom = TimedRoom,
	UntimedRoom = UntimedRoom,
	WorkRoom = WorkRoom,
	LossRoom = LossRoom,
	CutNamesKept = CutNamesKept,
	EntryMax = EntryMax,
	ItemMax = ItemMax,
	MarkMax = MarkMax,
	PostCap = PostCap,
	GateMax = GateMax,
	FatesMax = FatesMax,
	MarkCap = MarkCap,
	OwedCap = OwedCap,
	MoneyMax = MoneyMax,
	EventFixedBytes = EventFixedBytes,
	EventBytesPerField = EventBytesPerField,
	SlotFixedBytes = SlotFixedBytes,
	SlotBytesPerField = SlotBytesPerField,
	EventMax = EventMax,
	SlotMax = SlotMax,
	ValueFramingBytes = ValueFramingBytes,
	PostFramingBytes = PostFramingBytes,
	BookMax = BookMax,
	DataStoreValueMax = DataStoreValueMax,
	StateCap = StateCap,
	NameMax = NameMax,
	StateWarnBytes = StateWarnBytes,
	CounterKeyCount = CounterKeyCount,
	SequenceMax = SequenceMax,
	FirstSequence = FirstSequence,
	KeyKind = table.freeze(KeyKind),
	MigrationsMax = MigrationsMax,
	HorizonCacheKeys = HorizonCacheKeys,
	SentNamesKept = SentNamesKept,
	ShownKeysMax = ShownKeysMax,
	ShownBitCount = ShownBitCount,
	UnservedShowableKeys = UnservedShowableKeys,
	TimedWindowLeast = TimedWindowLeast,
	UntimedWindowLeast = UntimedWindowLeast,
	MintedWindow = MintedWindow,
	OpBound = OpBound,
	ErrorsBeforeUnresolved = ErrorsBeforeUnresolved,
	PinEvictAge = PinEvictAge,
	RetryGapFirst = RetryGapFirst,
	RetryGapMost = RetryGapMost,
	QueueOpsMax = QueueOpsMax,
	QueueWait = QueueWait,
	QueueRoomOps = QueueRoomOps,
	QueueRoomBytes = QueueRoomBytes,
	NewTimedBytesMax = NewTimedBytesMax,
	StorableDepthMax = StorableDepthMax,
	UnknownKindProbe = UnknownKindProbe,
	WideLowDigits = WideLowDigits,
	WideLimb = WideLimb,
	BookVersion = BookVersion,
	IdentityFlag = IdentityFlag,
	GateFlag = GateFlag,
	BookFlagsMost = BookFlagsMost,
	EncodeStartBytes = EncodeStartBytes,
	FateCode = FateCode,
	NamedKindBase = NamedKindBase,
	WriterEntryHead = WriterEntryHead,
	EventCauseByte = EventCauseByte,
	ReturnCauseByte = ReturnCauseByte,
	ReturnEscrowByte = ReturnEscrowByte,
	SlotByte = SlotByte,
	WorkKind = WorkKind,
	WorkKindMask = WorkKindMask,
	WorkCleanBit = WorkCleanBit,
	WorkSignOrSlotBit = WorkSignOrSlotBit,
	WorkSubBit = WorkSubBit,
	WorkForeignBit = WorkForeignBit,
	SealVersion = SealVersion,
	ShardKeyPrefix = ShardKeyPrefix,
	PartKeyPrefix = PartKeyPrefix,
	KeyNameBytesMost = KeyNameBytesMost,
	KeyBytesMost = KeyBytesMost,
	StoreNameBytesMost = StoreNameBytesMost,
	CounterStore = CounterStore,
	CounterScope = CounterScope,
	MapCount = MapCount,
	SummaryMapPrefix = SummaryMapPrefix,
	CopyMapPrefix = CopyMapPrefix,
	SummaryKeyPrefix = SummaryKeyPrefix,
	CopyKeyPrefix = CopyKeyPrefix,
	ItemVersionKey = ItemVersionKey,
	ItemHolderKey = ItemHolderKey,
	ItemUntilKey = ItemUntilKey,
	ItemAtKey = ItemAtKey,
	SummaryVersion = SummaryVersion,
	CopyVersion = CopyVersion,
	SummaryShardWidth = SummaryShardWidth,
	SummaryPartWidth = SummaryPartWidth,
	PartsMax = PartsMax,
})
