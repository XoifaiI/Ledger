--!strict
--!optimize 2

--[=[
	Coverage: Counts which outcomes of the catalogue a run reached.

	A run that passes and reached nothing is not evidence. Missed names an outcome nothing saw,
	Silent names an operation that never answered, and Starved names one that never reached the store.

	Return type: A table with New. The type is Cover.
	Example usage:
		local Cover = Coverage.New()
		Cover:Note("Edit", true, nil)
--]=]

local Catalogue = require("./Catalogue")

type CoverImpl = {
	__index: CoverImpl,

	New: () -> Cover,

	Note: (self: Cover, Named: string, Ok: boolean, Why: string?) -> (),
	Starved: (self: Cover) -> { string },
	Threw: (self: Cover, Named: string) -> (),
	Missed: (self: Cover) -> { string },
	Silent: (self: Cover) -> { string },
	Merge: (self: Cover, Other: Cover) -> (),
	Report: (self: Cover) -> string,
}

export type Cover = setmetatable<{
	Counts: { [string]: number },
	Issued: { [string]: number },
	Idle: { [string]: number },
	Raised: { [string]: number },
	Buckets: { string },
}, CoverImpl>

local Cover = {} :: CoverImpl
Cover.__index = Cover

function Cover.New(): Cover
	local Counts: { [string]: number } = {}
	local Buckets = Catalogue.Buckets()
	for _, Bucket in Buckets do
		Counts[Bucket] = 0
	end

	local Issued: { [string]: number } = {}
	for _, Operation in Catalogue.CATALOGUE do
		Issued[Operation.Name] = 0
	end

	return setmetatable({ Counts = Counts, Issued = Issued, Idle = {}, Raised = {}, Buckets = Buckets }, Cover) :: any
end

function Cover.Note(self: Cover, Named: string, Ok: boolean, Why: string?)
	self.Issued[Named] = (self.Issued[Named] or 0) + 1

	if not Ok and Why == nil then
		self.Idle[Named] = (self.Idle[Named] or 0) + 1
		return
	end

	local Bucket = `{Named}:{if Ok then "Ok" else Why}`
	self.Counts[Bucket] = (self.Counts[Bucket] or 0) + 1
end

function Cover.Threw(self: Cover, Named: string)
	self.Issued[Named] = (self.Issued[Named] or 0) + 1
	self.Raised[Named] = (self.Raised[Named] or 0) + 1
end

function Cover.Missed(self: Cover): { string }
	local Gaps: { string } = {}
	for _, Bucket in self.Buckets do
		if (self.Counts[Bucket] or 0) == 0 then
			table.insert(Gaps, Bucket)
		end
	end
	table.sort(Gaps)
	return Gaps
end

function Cover.Silent(self: Cover): { string }
	local Quiet: { string } = {}
	for _, Operation in Catalogue.CATALOGUE do
		if (self.Issued[Operation.Name] or 0) == 0 then
			table.insert(Quiet, Operation.Name)
		end
	end
	table.sort(Quiet)
	return Quiet
end

function Cover.Starved(self: Cover): { string }
	local Held: { string } = {}
	for Named, Count in self.Issued do
		if Count > 0 and (self.Idle[Named] or 0) >= Count then
			table.insert(Held, Named)
		end
	end
	table.sort(Held)
	return Held
end

function Cover.Merge(self: Cover, Other: Cover)
	for Bucket, Count in Other.Counts do
		self.Counts[Bucket] = (self.Counts[Bucket] or 0) + Count
	end
	for Named, Count in Other.Issued do
		self.Issued[Named] = (self.Issued[Named] or 0) + Count
	end
	for Named, Count in Other.Raised do
		self.Raised[Named] = (self.Raised[Named] or 0) + Count
	end
	for Named, Count in Other.Idle do
		self.Idle[Named] = (self.Idle[Named] or 0) + Count
	end
end

function Cover.Report(self: Cover): string
	local Reached = 0
	for _, Bucket in self.Buckets do
		if (self.Counts[Bucket] or 0) > 0 then
			Reached += 1
		end
	end

	local Silent = #self:Silent()
	return `{Reached}/{#self.Buckets} outcomes reached, {#Catalogue.CATALOGUE - Silent}/{#Catalogue.CATALOGUE} operations issued`
end

table.freeze(Cover)

return table.freeze({
	New = Cover.New,
})
