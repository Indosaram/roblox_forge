--!strict
-- Spec-side PackText over the real locale/strings.csv: the same lookups the client builds from
-- the shipped LocalizationTable, so specs assert against the one source of pack copy.
local fs = require("@lune/fs")
local Strings = require("../../core/infra/localization/Strings")
local PackText = require("./src/shared/PackText")

local rows = PackText.fromCsvRows(Strings.parseCsv(fs.readFile("games/robango-island/locale/strings.csv")).rows)
return {
	rows = rows,
	names = PackText.names(rows),
	authored = PackText.authored(rows),
}
