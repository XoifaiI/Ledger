--!strict
--!optimize 2

--[=[

	Pages: A page walker that behaves like a real one.

	It refuses to advance past the end. It reads a page size of zero as the usual size rather than
	none. A cursor names a place in the listing rather than a row of it. The last page carries no
	cursor.

	Return type: A table with New.
	Example usage:
		local Pages = require("./Pages")
		local Book = Pages.New(Rows, 25, 25)
--]=]

local Datastore = require("../Core/Constants/Datastore")
local Types = require("./Types")

type Pages = Types.Pages

local Pages = {} :: Types.PagesImpl
Pages.__index = Pages

function Pages.New(Rows: { any }, PageSize: number?, Fallback: number, Mark: ((At: number) -> string)?, Spend: (() -> ())?): Pages
	local Asked = if PageSize ~= nil and PageSize > 0 then PageSize else Fallback
	local Size = math.clamp(Asked, 1, Datastore.PAGE_LIMIT)
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
})
