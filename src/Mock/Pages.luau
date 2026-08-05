--!strict
--!optimize 2

--[=[
	Pages: A page walker that finishes the way that a real one finishes.

	It also refuses to move past the end, which a real one does.
	Cursor names the last row of the page that you hold. A later call that carries it starts after
	that row. A walker of keys therefore continues where the last one stopped.

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
local function Edge(self: Pages)
	self.IsFinished = self.At + self.Size > #self.Rows

	local Field = self.Field
	if Field == nil then
		self.Cursor = ""
		return
	end

	local Row = self.Rows[math.min(self.At + self.Size - 1, #self.Rows)]
	local Mark = if type(Row) == "table" then (Row :: { [string]: any })[Field] else nil
	self.Cursor = if type(Mark) == "string" then Mark else ""
end

local function New(Rows: { any }, PageSize: number?, Fallback: number, Field: string?, Spend: (() -> ())?): Pages
	local Size = math.clamp(PageSize or Fallback, 1, PAGE_LIMIT)
	local Book: Pages = setmetatable({
		Rows = Rows,
		At = 1,
		Size = Size,
		Field = Field,
		Spend = Spend,
		Cursor = "",
		IsFinished = true
	}, Pages) :: any

	Edge(Book)
	return Book
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
	Edge(self)
end

table.freeze(Pages)

return table.freeze({
	New = New,
	PAGE_LIMIT = PAGE_LIMIT
})
