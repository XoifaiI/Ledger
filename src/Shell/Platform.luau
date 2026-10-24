--!strict
--!optimize 2

--[=[
	Platform: what the core may not ask the platform for. The protocol's clock is whole seconds since StampEpoch
	(Format 2); SecondsUntil is negative once the stamp has passed. Random:NextNumber() may give 1, so a 1 is drawn
	again, up to DrawsMost draws, then 0: a fraction is uniform in [0, 1). Util/Threads times durations. ParseJson
	throws on text that is not JSON.

	Return type: A plain table with Now, SecondsUntil, Fraction, JobId, IsStudio, IsServer and Encoding.
	Example usage:
		local Clock = Platform.Now()
		local Wait = Platform.SecondsUntil(Clock + 30)
--]=]

local HashInputs = require("../Record/Encoding/HashInputs")
local Record = require("../Record/Constants/Record")

type Encoding = HashInputs.Encoding

local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local MillisecondsPerSecond = 1000

local Generator = Random.new()
local DrawsMost = 8

local ZstdLevel = 1

local function Now(): number
	return DateTime.now().UnixTimestamp - Record.StampEpoch
end

local function SecondsUntil(At: number): number
	local MillisecondsSinceEpoch = DateTime.now().UnixTimestampMillis - Record.StampEpoch * MillisecondsPerSecond
	return At - MillisecondsSinceEpoch / MillisecondsPerSecond
end

local function Fraction(): number
	for _ = 1, DrawsMost do
		local Drawn = Generator:NextNumber()
		if Drawn < 1 then
			return Drawn
		end
	end
	return 0
end

local function JobId(): string
	return game.JobId
end

local function IsStudio(): boolean
	return RunService:IsStudio()
end

local function IsServer(): boolean
	return RunService:IsServer()
end

local function Sha256(Input: buffer): buffer
	return EncodingService:ComputeBufferHash(Input, Enum.HashAlgorithm.Sha256)
end

local function Compress(Input: buffer): buffer
	return EncodingService:CompressBuffer(Input, Enum.CompressionAlgorithm.Zstd, ZstdLevel)
end

local function ParseJson(Text: string): unknown
	return HttpService:JSONDecode(Text)
end

local Encoding: Encoding = {
	Sha256 = Sha256,
	Compress = Compress,
	ParseJson = ParseJson,
}

return {
	Now = Now,
	SecondsUntil = SecondsUntil,
	Fraction = Fraction,
	JobId = JobId,
	IsStudio = IsStudio,
	IsServer = IsServer,
	Encoding = Encoding,
}
