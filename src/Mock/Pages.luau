--!strict
--!optimize 2

--[=[
	Pages: A page walker that finishes the way that a real one finishes.

	It also refuses to move past the end, which a real one does.
	A page size of zero is the caller asking for the usual one rather than for no rows, which is what
	a real datastore reads it as, so it falls back the same way a missing one does.
	Cursor is a place in the listing and never a row of it, which is what a real one hands back, and
	the last page carries no cursor at all. A later call that carries one starts at that place, so a
	walker of keys continues where the last one stopped without naming what it stopped on.

	Return type: A table with New and PAGE_LIMIT.
	Example usage:
		local Pages = require("./Pages")
		local Book = Pages.New(Rows, 25, 25)
--]=]

local Types = require("./Types")

type Pages = Types.Pages

local PAGE_LIMIT = 100

local Pages = {} :: Types.PagesImpl
Pages.__index = Pages

function Pages.New(Rows: { any }, PageSize: number?, Fallback: number, Mark: ((At: number) -> string)?, Spend: (() -> ())?): Pages
	local Asked = if PageSize ~= nil and PageSize > 0 then PageSize else Fallback
	local Size = math.clamp(Asked, 1, PAGE_LIMIT)
	local Book: Pages = setmetatable({
		Rows = Rows,
		At = 1,
		Size = Size,
		Mark = Mark,
		Spend = Spend,
		Cursor = "",
		IsFinished = true,
	}, Pages) :: any

	Book:Edge()
	return Book
end

function Pages.Edge(self: Pages)
	self.IsFinished = self.At + self.Size > #self.Rows

	local Mark = self.Mark
	if Mark == nil or self.IsFinished then
		self.Cursor = ""
		return
	end
	self.Cursor = Mark(self.At + self.Size)
end

function Pages.GetCurrentPage(self: Pages): { any }
	local Last = math.min(self.At + self.Size - 1, #self.Rows)
	return table.move(self.Rows, self.At, Last, 1, {})
end

function Pages.AdvanceToNextPageAsync(self: Pages)
	if self.IsFinished then
		error("Ledger mock: there are no pages left to advance to", 0)
	end

	local Spend = self.Spend
	if Spend ~= nil then
		Spend()
	end

	self.At += self.Size
	self:Edge()
end

table.freeze(Pages)

return table.freeze({
	New = Pages.New,
	PAGE_LIMIT = PAGE_LIMIT,
})
