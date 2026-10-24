--!strict
-- Player-facing copy for the social/home/trade sheets (EN default, KO for ko-*).
-- Rows live in the pack's locale table as soc.<key> (games/robango-island/locale/strings.csv).
local M = {}
local PackLocale = require("./PackLocale")
local strings: { [string]: { string } } = PackLocale.rows({}, { "soc." })

local function ko(locale: string): boolean
	return string.sub(locale, 1, 2) == "ko"
end

function M.has(key: string): boolean
	return strings[key] ~= nil
end

function M.text(locale: string, key: string, ...: any): string
	local row = strings[key]
	if not row then
		return key
	end
	local template = row[if ko(locale) then 2 else 1]
	return if select("#", ...) > 0 then string.format(template, ...) else template
end

function M.refusal(locale: string, reason: string?): string
	local key = "refuse." .. tostring(reason)
	return M.text(locale, if strings[key] then key else "refuse.unknown")
end

function M.duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local hours, minutes = seconds // 3600, (seconds % 3600) // 60
	return if hours > 0
		then string.format("%dh %02dm", hours, minutes)
		else string.format("%d:%02d", minutes, seconds % 60)
end

M.strings = strings
return M
