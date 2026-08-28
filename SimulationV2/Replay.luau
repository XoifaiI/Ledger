--!strict
--!optimize 2

--[=[
	Replay: Proves that a seed gives the same run every time.

	Everything else rests on that one claim. It is what makes a failing seed worth printing. A seed
	runs two times and the two digests are compared.

	Return type: A table with Check, Digest and Apart. The type is Report.
	Example usage:
		local Same = Replay.Check(1)
--]=]

local Catalogue = require("./Catalogue")
local Simulator = require("./Simulator")

export type Report = {
	Ok: boolean,
	Seed: number,
	First: string,
	Second: string,
	Says: string?,
}

local function Digest(Out: any): string
	local Parts: { string } = {
		`issued={Out.Issued}`,
		`steps={Out.Steps}`,
		`calls={Out.Calls}`,
		`injected={Out.Injected}`,
		`lost={Out.Lost}`,
		`threw={#Out.Threw}`,
		`broken={#Out.Broken}`,
		`checked={Out.Books.Checked}`,
		`outside={#Out.Books.Broken}`,
	}

	for _, Bucket in Catalogue.Buckets() do
		local Count = Out.Cover.Counts[Bucket] or 0
		if Count > 0 then
			table.insert(Parts, `{Bucket}={Count}`)
		end
	end

	return table.concat(Parts, " ")
end

local function Apart(First: string, Second: string): string
	local Left = string.split(First, " ")
	local Right = string.split(Second, " ")

	local Apart: { string } = {}
	for Index, Held in Left do
		local Other = Right[Index]
		if Other == nil then
			table.insert(Apart, `the second run stopped after '{Held}'`)
			break
		end
		if Held ~= Other then
			table.insert(Apart, `'{Held}' then '{Other}'`)
		end
	end

	if #Right > #Left then
		table.insert(Apart, `the second run had '{Right[#Left + 1]}' and the first had nothing there`)
	end
	if #Apart == 0 then
		return "they agree, which should not have reached here"
	end
	return table.concat(Apart, ", ")
end

local function Check(Seed: number, Options: any?): Report
	local First = Digest(Simulator.Run(Seed, Options))
	local Second = Digest(Simulator.Run(Seed, Options))

	if First == Second then
		return { Ok = true, Seed = Seed, First = First, Second = Second, Says = nil }
	end

	return {
		Ok = false,
		Seed = Seed,
		First = First,
		Second = Second,
		Says = `seed {Seed} did not replay: {Apart(First, Second)}`,
	}
end

return table.freeze({
	Check = Check,
	Digest = Digest,
	Apart = Apart,
})
