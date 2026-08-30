--!strict
--!optimize 2

--[=[

	Suite: The case suite. One rule per case, and one bench per case.

	File collects the cases of one file, and Run gives each a bench of its own, runs it, takes the
	bench down and collects what broke. A case that breaks several checks reports them all. Cases run
	in the order they are written, and a filter runs only the ones whose name holds a fragment.

	Return type: A table with File, Run, Heard, Fault, Reducers, Reasons and Horizons.
	Example usage:
		local Cases = Suite.File("Once")
		Cases.Case("a replay under the same name changes nothing", function(T) end)
--]=]

local Case = require("@self/Case")
local Fixture = require("@self/Fixture")
local Reducers = require("@self/Reducers")

export type Case = Case.Case
export type Spec = Case.Spec
export type Fixture = Fixture.Fixture

export type Written = {
	read Name: string,
	read Body: (Case) -> (),
}

export type File = {
	read Name: string,
	read Tags: { string },
	read Cases: { Written },
	read Case: (Name: string, Body: (Case) -> ()) -> (),
}

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
		Case = Add,
	})
end

export type Failure = {
	read File: string,
	read Name: string,
	read Says: string,
}

export type Report = {
	Ok: boolean,
	Ran: number,
	Failed: number,
	Broken: { Failure },
	Accused: { string },
	Warnings: number,
	Seconds: number,
}

export type Options = {
	Match: string?,
}

local function Wanted(File: string, Named: string, Match: string?): boolean
	if Match == nil or Match == "" then
		return true
	end
	return string.find(string.lower(`{File} {Named}`), string.lower(Match), 1, true) ~= nil
end

local function Run(Files: { File }, Options: Options?): Report
	local Held: Options = Options or {}
	local Started = os.clock()

	local Broken: { Failure } = {}
	local Accused: { string } = {}
	local Warnings = 0
	local Ran, Failed = 0, 0

	for _, Book in Files do
		for _, Written in Book.Cases do
			if not Wanted(Book.Name, Written.Name, Held.Match) then
				continue
			end

			Ran += 1
			local Bench = Case.Open(Written.Name)

			local Raised = Case.Drive(Bench, Written.Body)
			if Raised ~= nil then
				table.insert(Bench.Broken, `threw: {Raised}`)
			end

			local Shut = pcall(Case.Close, Bench)
			if not Shut then
				table.insert(Bench.Broken, "the bench could not be taken down after it")
			end

			for _, Line in Case.Judge(Bench) do
				table.insert(Accused, `{Book.Name}: {Written.Name}: {Line}`)
			end
			for _, Record in Bench.Records do
				Warnings += Record.Count
			end

			if #Bench.Broken > 0 then
				Failed += 1
			end
			for _, Says in Bench.Broken do
				table.insert(Broken, { File = Book.Name, Name = Written.Name, Says = Says })
			end
		end
	end

	return {
		Ok = #Broken == 0 and #Accused == 0,
		Ran = Ran,
		Failed = Failed,
		Broken = Broken,
		Accused = Accused,
		Warnings = Warnings,
		Seconds = os.clock() - Started,
	}
end

return table.freeze({
	File = File,
	Run = Run,
	Heard = Case.Heard,

	Fault = require("../src/Hooks/Memory"),
	Reducers = Reducers,
	Reasons = require("../src/Core/Constants/Reasons"),
	Horizons = require("../src/Core/Constants/Windows"),
})
