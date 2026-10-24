--!strict
local M = {}
local PackLocale = require("./PackLocale")
local strings: { [string]: { string } } = PackLocale.rows({
	-- Kept in source: the provenance n-gram gate flags these KO lines; moving them needs a human review.
	PLACEMENT_BLOCKED_CREATURE = {
		"A creature is standing on the spot. Wait for it to move, or pick another spot.",
		"동물이 그 자리에 있어요. 비켜날 때까지 기다리거나 다른 곳을 고르세요.",
	},
	["market.tutorial"] = {
		"Finish the first-day tutorial to open market listing.",
		"첫날 튜토리얼을 마치면 장터에 등록할 수 있어요.",
	},
}, { "hud.", "" })
function M.text(locale: string, key: string): string
	local entry = strings[key]
	return if entry then entry[if string.sub(locale, 1, 2) == "ko" then 2 else 1] else key
end
-- Food freshness line from remaining permille; under a quarter left it warns to eat or refrigerate.
function M.freshness(locale: string, permille: number): string
	return string.format(M.text(locale, if permille < 250 then "freshness_spoiling" else "freshness"), permille // 10)
end
-- Skills row: category name, rank and cost; an unknown category shows its id with spaces.
function M.skill(locale: string, node: { category: string, rank: number?, cost: number }): string
	local key = "skills." .. node.category
	local name = if strings[key] then M.text(locale, key) else (string.gsub(node.category, "_", " "))
	return name .. (if node.rank then " " .. tostring(node.rank) else "") .. " · " .. tostring(node.cost) .. " SP"
end
function M.refusal(locale: string, reason: string): string
	local key = reason
	if string.find(reason, "WEIGHT") or string.find(reason, "SLOTS") or string.find(reason, "CAPACITY") then
		key = "capacity"
	elseif string.find(reason, "STALE") then
		key = "stale"
	elseif string.find(reason, "INGREDIENT") or string.find(reason, "RESERVED") or string.find(reason, "QUANTITY") then
		key = "materials"
	end
	return M.text(locale, if strings[key] then key else "unknown")
end
return M
