--!strict
-- Localized wildlife species names (EN first, ko-kr second), shared by the taming panel and
-- the expedition objective lines. Keys mirror the pack's wildlife_<id> rows in
-- games/robango-island/locale/strings.csv; an unknown id falls back to the raw id.
local M = {}

local PackLocale = require("./PackLocale")
local strings: { [string]: { string } } = PackLocale.rows({}, { "wld.", "" })

M.strings = strings

function M.name(locale: string, species: string): string
	local entry = strings["wildlife_" .. string.gsub(species, "%-", "_")]
	if entry == nil then
		return species
	end
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end

return M
