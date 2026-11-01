--!strict
-- EN/KO text for the character/progression screens. Keys mirror games/robango-island/locale/strings.csv
-- (char_*). Refusal reasons map to sentences; a raw reason code is never shown.
local Party = require("../../../core/domain/island/Party")
local Guide = require("./GuideEvents")
local M = {}

local PackLocale = require("./PackLocale")
local strings: { [string]: { string } } = PackLocale.rows({}, { "chr.", "" })

M.keys = {} :: { string }
for key in strings do
	table.insert(M.keys, key)
end
table.sort(M.keys)

function M.has(key: string): boolean
	return strings[key] ~= nil
end

function M.text(locale: string, key: string): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end

function M.format(locale: string, key: string, ...: any): string
	return string.format(M.text(locale, key), ...)
end

-- Lowest character gate of a support region whose layout is the only source of `item`
-- (no ungated region has a node for it), or nil when the item is gathered at level 1.
local function regionLevel(content: any, item: string): number?
	local nodes = {}
	for _, layout in content.layouts or {} do
		for _, node in layout.resourceNodes or {} do
			if node.item == item then
				nodes[layout.id] = true
			end
		end
	end
	local best: number? = nil
	for _, region in content.supportRegions or {} do
		if nodes[region.layout] then
			local gate = (region.gates or {}).characterLevel or 1
			if gate <= 1 then
				return nil
			end
			best = math.min(best or gate, gate)
		end
	end
	return best
end

local function title(locale: string, guide: any, names: any): string
	local key = "guide_" .. string.sub(guide.id, 4, 6)
	return if strings[key] then M.text(locale, key) else names[guide.id] or guide.id
end

-- First open unfinished guide with a HUD action: "<guide>: <action> have/need".
local function openGuide(
	locale: string,
	content: any,
	ch: any,
	names: any,
	level: number,
	grade: number,
	minRank: number,
	solo: boolean?
): string?
	local done, progress = ch.definitions or {}, ch.progress or {}
	for _, g in Guide.visible(content, solo) do
		if not done[g.id] and Guide.open(g, level, grade) and ((g.gates or {}).developmentRank or 0) >= minRank then
			local o = g.objectives[1]
			for _, objective in g.objectives do
				if (progress[objective.id] or 0) < objective.quantity then
					o = objective
					break
				end
			end
			local go = "guide_go_" .. o.action
			if strings[go] then
				local t = "guide_target_" .. o.target
				local what = M.format(locale, go, if strings[t] then M.text(locale, t) else names[o.target] or o.target)
				local where = if o.action == "gather" then regionLevel(content, o.target) else nil
				if where then
					what = M.format(locale, "guide_where_region", what, where)
				end
				local have = math.min(progress[o.id] or 0, o.quantity)
				return M.format(locale, "guide_next", title(locale, g, names), what, have, o.quantity)
			end
		end
	end
	return nil
end

-- HUD objective: the next open start guide; after route 1's grade, the next open waypoint guide of
-- that grade's band; with none open, route 1's gate plus the next authored step (a support region
-- opening at the harbor departure post, or the next guide's level). With `solo`, guides whose steps
-- need another player (GuideEvents.multiplayer) are skipped.
function M.guideObjective(locale: string, content: any, ch: any, names: any, solo: boolean?): string?
	local level, grade, done = ch.level or 1, math.floor((ch.points or 0) / 100), ch.definitions or {}
	local needLevel, needRank = Party.gates(content, 1)
	if grade < needRank then
		return openGuide(locale, content, ch, names, level, grade, 0, solo)
	elseif level >= needLevel then
		return M.text(locale, "guide_route_open")
	end
	-- Grade met but below the route level: a guide of the route's grade first, else any still-open
	-- start guide (chart2 lowered route 1 to grade 1, reached after two of the four start guides).
	local open = openGuide(locale, content, ch, names, level, grade, needRank, solo)
		or openGuide(locale, content, ch, names, level, grade, 0, solo)
	if open then
		return open
	end
	local gate = M.format(locale, "guide_route_level", grade, needLevel, level)
	local region: number? = nil
	for _, row in content.supportRegions or {} do
		local at = (row.gates or {}).characterLevel or 1
		if at > level and at < needLevel then
			region = math.min(region or at, at)
		end
	end
	local nextGuide, guideAt = nil, nil
	for _, g in Guide.visible(content, solo) do
		local gates = g.gates or {}
		local at = gates.characterLevel or 1
		if
			not done[g.id]
			and at > level
			and at < needLevel
			and (gates.developmentRank or 0) <= grade
			and (gates.developmentRank or 0) >= needRank
		then
			if guideAt == nil or at < guideAt then
				nextGuide, guideAt = g, at
			end
		end
	end
	if region and (guideAt == nil or region <= guideAt) then
		return M.format(locale, "guide_then_region", gate, region, region)
	elseif nextGuide then
		return M.format(locale, "guide_then_guide", gate, title(locale, nextGuide, names), guideAt)
	end
	return gate
end

-- "Guide complete" line for guides finished since the previous snapshot.
function M.newGuides(locale: string, seen: any, ch: any): string?
	local new = {}
	for id in type(ch) == "table" and ch.definitions or {} do
		if seen.ready and not seen[id] then
			table.insert(new, M.text(locale, "guide_" .. string.sub(id, 4, 6)))
		end
		seen[id] = true
	end
	seen.ready = seen.ready or type(ch) == "table"
	return if #new > 0 then M.format(locale, "guide_complete", table.concat(new, ", ")) else nil
end

function M.refusal(locale: string, reason: string?): string
	local key = reason or ""
	return M.text(locale, if strings[key] and string.upper(key) == key then key else "char_failed")
end

return M
