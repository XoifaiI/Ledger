--!strict
--!optimize 2

-- the clock Ledger stamps records with, swappable so a test can hold time still or jump it forward

local function Real(): number
	return os.time()
end

local Source: () -> number = Real

local function Set(Reads: (() -> number)?)
	Source = Reads or Real
end

local function Now(): number
	return Source()
end

return table.freeze({
	Set = Set,
	Now = Now
})
