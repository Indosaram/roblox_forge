--!strict
-- Player-facing text for the expedition lane (routes, party, invites, departure, travel,
-- expedition tracker, results, hazard, knockout). EN first, ko-kr second; default EN.
-- Every key mirrors a games/robango-island/locale/strings.csv row.
local WildlifeNames = require("./WildlifeNames")
local M = {}

local PackLocale = require("./PackLocale")
local strings: { [string]: { string } } = PackLocale.rows({}, { "exp.", "" })

M.strings = strings

function M.text(locale: string, key: string, ...: any): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	local template = if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
	return if select("#", ...) > 0 then string.format(template, ...) else template
end

--- Localized biome (route) name; the pack's names table wins, then the genre table, never a raw id.
function M.biome(locale: string, names: any, id: string?): string
	local key = "biome_" .. tostring(id)
	if id and names and names[key] then
		return names[key]
	end
	return M.text(locale, if strings[key] then key else "biome_unknown")
end

--- Localized mission name: the pack's names table wins, then "Route N <kind> job" parsed from
--- the "<prefix>.m<route>.<kind>" id, never the raw id.
function M.mission(locale: string, names: any, id: string): string
	if names and names[id] then
		return names[id]
	end
	local route, kind = string.match(id, "%.m(%d+)%.([%w_]+)$")
	local key = "mission_" .. tostring(kind)
	return M.text(
		locale,
		"exp_mission",
		tonumber(route) or 0,
		M.text(locale, if strings[key] then key else "mission_unknown")
	)
end

-- Objective verbs whose template names the target; survey and rescue targets are layout
-- anchors (never player-facing), so their lines name the activity only.
local NAMED = { gather = true, craft = true, hunt = true, transport = true }

--- One player-readable objective line, e.g. "쓰러진 통나무 모으기 3/5" or "Survey the marked spot 0/1".
--- Items come from the pack's names table, hunted species from the wildlife names; a raw id or
--- action verb is never shown.
function M.objective(locale: string, names: any, objective: any): string
	local action = tostring(objective.action)
	local progress, quantity = objective.progress or 0, objective.quantity or 0
	if NAMED[action] then
		local target = tostring(objective.target)
		local name = if names and names[target] then names[target] else nil
		if not name and action == "hunt" then
			local species = WildlifeNames.name(locale, target)
			name = if species ~= target then species else nil
		end
		return M.text(locale, "exp_obj_" .. action, name or M.text(locale, "exp_obj_thing"), progress, quantity)
	end
	local key = "exp_obj_" .. action
	return M.text(locale, if strings[key] then key else "exp_obj_other", progress, quantity)
end

--- A refusal sentence; `verb` (e.g. "route-revoke") picks a verb-specific line when one exists,
--- because shared codes (invite_missing, party_member_busy) mean different things per verb.
function M.reason(locale: string, reason: string?, verb: string?): string
	local key = "reason_" .. tostring(reason)
	local specific = if verb then "reason_" .. string.gsub(verb, "%-", "_") .. "_" .. tostring(reason) else nil
	if specific and strings[specific] then
		return M.text(locale, specific)
	end
	return M.text(locale, if strings[key] then key else "exp_refused")
end

function M.duration(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	if s >= 3600 then
		return string.format("%dh %02dm", s // 3600, (s % 3600) // 60)
	end
	return string.format("%d:%02d", s // 60, s % 60)
end

return M
