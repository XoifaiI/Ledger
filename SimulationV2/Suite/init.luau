--!strict
--!optimize 2

--[=[
	Suite: The case suite. One rule per case, and one bench per case.

	A case is a claim about Ledger written so a person can read it. Cases run in the order they are
	written, and each one gets a seed made from its own name, so adding a case cannot change another.
	Every warning Ledger writes is caught for the case that wrote it. A case can then say what Ledger
	explained, and the run can say that Ledger never accused itself.

	Return type: A table with File, Run, Fault, Reducers, Insides and Entries.
	Example usage:
		local Cases = Suite.File("Once")
		Cases.Case("a replay under the same name changes nothing", function(T) end)
--]=]

local EncodingService = game:GetService("EncodingService")
local LogService = game:GetService("LogService")

local Lib = require("./Lib")
local Marks = require("./Marks")
local Case = require("@self/Case")
local Fault = require("@self/Fault")
local Fixture = require("@self/Fixture")
local Insides = require("@self/Insides")
local Reducers = require("@self/Reducers")

export type Case = Case.Case
export type Spec = Case.Spec
export type Fixture = Fixture.Fixture

export type Written = {
	read Name: string,
	read Body: (Case) -> ()
}

export type File = {
	read Name: string,
	read Tags: { string },
	read Cases: { Written },
	read Case: (Name: string, Body: (Case) -> ()) -> ()
}

export type Failure = {
	read File: string,
	read Name: string,
	read Says: string
}

export type Report = {
	Ok: boolean,
	Ran: number,
	Skipped: number,
	Failed: number,
	Broken: { Failure },
	Accused: { string },
	Sheet: Marks.Marks,
	Warnings: number,
	Slowest: { { Name: string, Seconds: number } },
	Seconds: number
}

export type Options = {
	Match: string?,
	Files: { string }?,
	Loud: boolean?
}

local SLOWEST = 8
local MAX_SEED = 2 ^ 31 - 1
local ALGORITHM = Enum.HashAlgorithm.Blake3

local function Seeded(Name: string): number
	local Raw = EncodingService:ComputeStringHash(Name, ALGORITHM)
	return buffer.readu32(buffer.fromstring(string.sub(Raw, 1, 4)), 0) % MAX_SEED + 1
end

local function File(Name: string, Tags: { string }?): File
	local Written: { Written } = {}
	local Seen: { [string]: boolean } = {}

	local function Add(Held: string, Body: (Case) -> ())
		assert(type(Held) == "string" and #Held > 0, `a case in '{Name}' has no name`)
		assert(not Seen[Held], `'{Name}' names two cases '{Held}', and a name has to say one thing`)
		Seen[Held] = true
		table.insert(Written, { Name = Held, Body = Body })
	end

	return table.freeze({
		Name = Name,
		Tags = Tags or {},
		Cases = Written,
		Case = Add
	})
end

local function Wanted(Held: File, Named: string, Options: Options): boolean
	local Files = Options.Files
	if Files ~= nil and #Files > 0 and table.find(Files, Held.Name) == nil then
		return false
	end

	local Match = Options.Match
	if Match == nil or Match == "" then
		return true
	end
	return string.find(string.lower(`{Held.Name} {Named}`), string.lower(Match), 1, true) ~= nil
end

local function Run(Files: { File }, Options: Options?): Report
	local Held: Options = Options or {}
	local Started = os.clock()

	local Sheet = Marks.New()
	local Lines: { string } = {}
	local Tap = LogService.MessageOut:Connect(function(Message: string, Kind: Enum.MessageType)
		if Kind ~= Enum.MessageType.MessageWarning then
			return
		end
		table.insert(Lines, Message)
		Sheet:Note(Message)
	end)

	local Broken: { Failure } = {}
	local Accused: { string } = {}
	local Timed: { { Name: string, Seconds: number } } = {}
	local Ran, Skipped, Failed = 0, 0, 0

	for _, Book in Files do
		for _, Written in Book.Cases do
			if not Wanted(Book, Written.Name, Held) then
				Skipped += 1
				continue
			end

			Ran += 1
			local Began = os.clock()
			local Bench = Case.Open(Written.Name, Seeded(Written.Name), Lines)

			local Fine, Raised = pcall(Written.Body, Bench)
			if not Fine then
				table.insert(Bench.Broken, `threw: {tostring(Raised)}`)
			end

			local Shut = pcall(Case.Close, Bench)
			if not Shut then
				table.insert(Bench.Broken, "the bench could not be taken down after it")
			end

			for _, Line in Case.Judge(Bench) do
				table.insert(Accused, `{Book.Name}: {Written.Name}: {Line}`)
			end

			if #Bench.Broken > 0 then
				Failed += 1
			end
			for _, Says in Bench.Broken do
				table.insert(Broken, { File = Book.Name, Name = Written.Name, Says = Says })
			end
			table.insert(Timed, { Name = `{Book.Name}: {Written.Name}`, Seconds = os.clock() - Began })
		end
	end

	Tap:Disconnect()

	table.sort(Timed, function(Left: { Name: string, Seconds: number }, Right: { Name: string, Seconds: number }): boolean
		return Left.Seconds > Right.Seconds
	end)
	local Slowest: { { Name: string, Seconds: number } } = table.move(Timed, 1, math.min(SLOWEST, #Timed), 1, {})

	return {
		Ok = #Broken == 0 and #Accused == 0,
		Ran = Ran,
		Skipped = Skipped,
		Failed = Failed,
		Broken = Broken,
		Accused = Accused,
		Sheet = Sheet,
		Warnings = #Lines,
		Slowest = Slowest,
		Seconds = os.clock() - Started
	}
end

return table.freeze({
	File = File,
	Run = Run,

	Fault = Fault,
	Reducers = Reducers,
	Insides = Insides,
	Entries = Lib.Entries,
	Reasons = Lib.Reasons,
	Horizons = Lib.Horizons
})
