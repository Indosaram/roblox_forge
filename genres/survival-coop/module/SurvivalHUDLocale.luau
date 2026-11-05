--!strict
local M = {}
local PackLocale = require("./PackLocale")
local strings: { [string]: { string } } = PackLocale.rows({}, { "hud.", "" })
function M.text(locale: string, key: string): string
	local entry = strings[key]
	return if entry then entry[if string.sub(locale, 1, 2) == "ko" then 2 else 1] else key
end
--- Single-player wording: the `<key>_solo` row when the pack has one (camp storage is not shared
--- in solo, p134 v63), otherwise the plain row.
function M.soloText(locale: string, key: string, solo: boolean?): string
	return M.text(locale, if solo and strings[key .. "_solo"] then key .. "_solo" else key)
end
--- Keyboard hints in a string: a trailing " [I]" and every {{...}} span. A touch-only device drops
--- them ("bag{{ (I)}} open" -> "bag open"); with a keyboard the span shows without its braces.
function M.keyHints(text: string, touchOnly: boolean): string
	if touchOnly then
		return (string.gsub(string.gsub(text, "{{.-}}", ""), " %[%u%]$", ""))
	end
	return (string.gsub(text, "{{(.-)}}", "%1"))
end
-- Food freshness line from remaining permille; under a quarter left it warns to eat or refrigerate,
-- at 0 it has spoiled and can no longer be eaten (p134 v73: '0% - eat it soon' on a spoiled berry).
function M.freshness(locale: string, permille: number): string
	if permille <= 0 and strings.freshness_spoiled then
		return M.text(locale, "freshness_spoiled")
	end
	return string.format(M.text(locale, if permille < 250 then "freshness_spoiling" else "freshness"), permille // 10)
end
-- Skills row: category name, rank and cost; an unknown category shows its id with spaces.
function M.skill(locale: string, node: { category: string, rank: number?, cost: number }): string
	local key = "skills." .. node.category
	local name = if strings[key] then M.text(locale, key) else (string.gsub(node.category, "_", " "))
	return name .. (if node.rank then " " .. tostring(node.rank) else "") .. " · " .. tostring(node.cost) .. " SP"
end
function M.skillName(locale: string, id: string): string
	local category, rank = string.match(id, "^(.-)_(%d+)$")
	return M.text(locale, "skills." .. (category or id)) .. " " .. (rank or "")
end
function M.refusal(locale: string, reason: string, skill: string?): string
	if reason == "SKILL_NODE_GATE" and skill then
		return string.format(M.text(locale, "skill_needed_refusal"), skill)
	end
	local key = reason
	if string.find(reason, "WEIGHT") or string.find(reason, "SLOTS") or string.find(reason, "CAPACITY") then
		key = "capacity"
	elseif string.find(reason, "STALE") then
		key = "stale"
	elseif string.find(reason, "INGREDIENT") or string.find(reason, "RESERVED") or string.find(reason, "QUANTITY") then
		key = "materials"
	elseif string.find(reason, "STATION_TIER") then
		-- The tier-2/3 recipe was reserved at a station one tier too low: say it is the station's rank,
		-- never the generic 'refresh your supplies' (p134 v77: g46 pickaxe-t2 at a tier-1 bench).
		key = "STATION_TIER"
	end
	return M.text(locale, if strings[key] then key else "unknown")
end
return M
