--!strict
-- Rows live in the pack's locale table as mus.<key> (games/robango-island/locale/strings.csv).
local M = {}
local PackLocale = require("./PackLocale")

local strings: { [string]: { string } } = PackLocale.rows({}, { "mus." })

M.strings = strings

local function ko(locale: string): boolean
	return string.sub(locale, 1, 2) == "ko"
end

function M.text(locale: string, key: string, ...: any): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	local template = if ko(locale) then entry[2] else entry[1]
	return if select("#", ...) > 0 then string.format(template, ...) else template
end

--- Localized instrument name; an unknown id falls back to the id itself.
function M.instrument(locale: string, id: string): string
	return if strings["instrument_" .. id] then M.text(locale, "instrument_" .. id) else id
end

function M.refusal(locale: string, reason: string?): string
	local value = reason or ""
	if strings[value] then
		return M.text(locale, value)
	end
	local part, note, field = string.match(value, "^score%.parts%[(%d+)%]%.notes%[(%d+)%]%.?(%a*)$")
	if part and note then
		local key = "f_" .. (if field == nil or field == "" then "note" else field)
		return M.text(locale, "score.field", tonumber(part), tonumber(note), M.text(locale, key))
	end
	local only, partField = string.match(value, "^score%.parts%[(%d+)%]%.(%a+)$")
	if only and partField and strings["f_" .. partField] then
		local key = "f_" .. partField
		return M.text(locale, "score.partfield", tonumber(only), M.text(locale, key))
	end
	return M.text(locale, "failed")
end

return M
