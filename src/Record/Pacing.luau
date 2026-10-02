--!strict
--!optimize 2

--[=[
	Pacing: Logic. The gap a paced writer keeps between its sends, so a busy key stays under its
	byte ceiling and its ops ride together.

	Spec: extras 2.3; hot keys 2.10.

	Only Ledger's own keys are paced: a total's shard aims at half its write ceiling and a part at the
	whole of it, the Share a build gives. The ceiling is KEY_CEILING kilobytes a minute over the
	kilobytes of the key's last landing. Each landing after the first measures the key's writes a
	minute from the change in its write count over this server's clock. The gap then moves by the
	rate over the target, falling by at most a half at once and kept from GAP_MIN to GAP_MAX. A
	clock only decides when a request leaves, never what applies. A failed request waits no gap.

	Return type: The Pacing module, and the Pace type.
	Example usage:
		local Wait = Pacing.Wait(Held.Pace, Now)
--]=]

export type Pace = {
	read Share: number,
	Gap: number,
	Sent: number?,
	Landing: { read Writes: number, read At: number }?,
}

local GAP_MIN = 1
local GAP_MAX = 60
local GAP_FALL = 0.5
local RETRY_GAP = 2
local RETRY_MAX = 16
local MINUTE = 60
local KB = 1024
local KEY_CEILING = 4096

local Pacing = {
	GAP_MAX = GAP_MAX,
	RETRY_GAP = RETRY_GAP,
	RETRY_MAX = RETRY_MAX,
}

function Pacing.New(Share: number): Pace
	return { Share = Share, Gap = GAP_MAX }
end

function Pacing.Wait(Held: Pace?, Clock: number): number
	local Sent = if Held then Held.Sent else nil
	if Held == nil or Sent == nil then
		return 0
	end
	return math.max(Sent + Held.Gap - Clock, 0)
end

function Pacing.Stagger(Held: Pace, Clock: number, Wait: number)
	Held.Sent = Clock + Wait - Held.Gap
end

function Pacing.Sent(Held: Pace?, Clock: number)
	if Held then
		Held.Sent = Clock
	end
end

function Pacing.Failed(Held: Pace?)
	if Held then
		Held.Sent = nil
	end
end

function Pacing.Landed(Held: Pace, Writes: number, Bytes: number, Clock: number)
	local Before = Held.Landing
	if Before and Clock <= Before.At then
		return
	end
	Held.Landing = { Writes = Writes, At = Clock }
	if Before == nil then
		return
	end
	local Rate = (Writes - Before.Writes) * MINUTE / (Clock - Before.At)
	local Target = (KEY_CEILING // math.max(math.ceil(Bytes / KB), 1)) / Held.Share
	Held.Gap = math.clamp(Held.Gap * math.max(Rate / Target, GAP_FALL), GAP_MIN, GAP_MAX)
end

return Pacing
