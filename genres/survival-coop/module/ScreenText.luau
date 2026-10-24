--!strict
-- Copy for the recovered screens (RecoveredScreens.luau, NavigatorPanel scr.nav.* labels).
-- The text itself lives in the pack's locale table (scr.* rows of locale/strings.csv, shipped as
-- a LocalizationTable), not in script source: the pack injects a (locale, key) -> string?
-- lookup with M.use. A key the lookup does not know renders "" (never the raw key).
local M = {}

local lookup: (string, string) -> string? = function(_locale: string, _key: string): string?
	return nil
end

--- Install the pack's text lookup (client: PackText over GetEntries(); specs: over the CSV).
function M.use(fn: (string, string) -> string?)
	lookup = fn
end

function M.has(key: string): boolean
	return lookup("en-us", key) ~= nil
end

function M.text(locale: string, key: string, ...: any): string
	local template = lookup(locale, key)
	if template == nil or template == "" then
		return ""
	end
	return if select("#", ...) > 0 then string.format(template, ...) else template
end

function M.refusal(locale: string, reason: string?): string
	local key = "scr.refuse." .. tostring(reason)
	return M.text(locale, if M.has(key) then key else "scr.refuse.unknown")
end

--- Player-facing island name for a layout id (never the raw id).
function M.layout(locale: string, id: string?): string
	if type(id) ~= "string" or id == "" then
		return M.text(locale, "scr.territory.nobody")
	end
	local route, stage = string.match(id, "^rw%.a(%d+)%.s(%d+)$")
	if route then
		return M.text(locale, "scr.layout.route", tonumber(route), tonumber(stage))
	end
	return M.text(locale, if M.has("scr.layout." .. id) then "scr.layout." .. id else "scr.layout.unknown")
end

--- "1:05" / "2h 03m" style remaining time.
function M.duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local hours, minutes = seconds // 3600, (seconds % 3600) // 60
	return if hours > 0
		then string.format("%dh %02dm", hours, minutes)
		else string.format("%d:%02d", minutes, seconds % 60)
end

return M
