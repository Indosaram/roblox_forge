--!strict
-- EN/KO text for the character/progression screens. Keys mirror games/robango-island/locale/strings.csv
-- (char_*). Refusal reasons map to sentences; a raw reason code is never shown.
local Party = require("../../../core/domain/island/Party")
local Guide = require("./GuideEvents")
local SkillTraining = require("./SkillTraining")
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
-- (no ungated region has a node for it), or nil when the item is gathered at level 1. The second
-- value is that region's role (the sea chart isle to sail to).
local function regionLevel(content: any, item: string): (number?, string?)
	local nodes = {}
	for _, layout in content.layouts or {} do
		for _, node in layout.resourceNodes or {} do
			if node.item == item then
				nodes[layout.id] = true
			end
		end
	end
	local best: number?, role: string? = nil, nil
	for _, region in content.supportRegions or {} do
		if nodes[region.layout] then
			local gate = (region.gates or {}).characterLevel or 1
			if gate <= 1 then
				return nil, nil
			end
			if best == nil or gate < best then
				best, role = gate, region.role
			end
		end
	end
	return best, role
end

-- "<thing> (Sea chart > <isle>, level N+)" when `item` only grows on a gated wild isle.
local function whereIsle(locale: string, content: any, item: string, what: string): string?
	local level, role = regionLevel(content, item)
	if not level then
		return nil
	end
	local isle = if role and strings["cli.chart.isle." .. role] then M.text(locale, "cli.chart.isle." .. role) else nil
	if isle and strings.guide_where_isle then
		return M.format(locale, "guide_where_isle", what, isle, level)
	end
	return M.format(locale, "guide_where_region", what, level)
end

local function recipeOf(content: any, target: string): any?
	for _, recipe in content.recipes or {} do
		if recipe.id == target then
			return recipe
		end
	end
	for _, recipe in content.recipes or {} do
		if recipe.outputs and recipe.outputs[1] and recipe.outputs[1].item == target then
			return recipe
		end
	end
	return nil
end

local function hasNode(content: any, item: string): boolean
	for _, layout in content.layouts or {} do
		for _, node in layout.resourceNodes or {} do
			if node.item == item then
				return true
			end
		end
	end
	return false
end

-- Inputs of a craft target the player cannot just pick up here: processed inputs (no node
-- anywhere) name their recipe's station, wild-isle inputs name the isle. nil when none.
-- Up to two creatures (display names) whose carcass gives `item`, preferring low-level species.
local function huntedBy(content: any, item: string, names: any): string?
	local found = {}
	for _, row in content.wildlifeDetails or {} do
		for _, drop in row.dropReservoirs or {} do
			if drop.item == item then
				table.insert(found, row)
			end
		end
	end
	table.sort(found, function(a, b)
		return (a.level or 0) < (b.level or 0) or ((a.level or 0) == (b.level or 0) and a.id < b.id)
	end)
	local labels = {}
	for index = 1, math.min(2, #found) do
		table.insert(labels, names[found[index].id] or found[index].id)
	end
	return if #labels > 0 then table.concat(labels, "/") else nil
end

local function craftInputs(locale: string, content: any, target: string, names: any): string?
	local recipe = recipeOf(content, target)
	if not recipe or not strings.guide_inputs then
		return nil
	end
	local parts = {}
	for _, input in recipe.inputs or {} do
		local name = names[input.item] or input.item
		if not hasNode(content, input.item) then
			local source = recipeOf(content, input.item)
			if source then
				local station = if source.station then names[source.station] or source.station else nil
				local part = if station then M.format(locale, "guide_input_station", name, station) else name
				-- A processed input whose raw comes from hunting (leather <- hide) names the creatures.
				local raw = source.inputs and source.inputs[1] and source.inputs[1].item
				local hunted = raw
					and strings.guide_input_hunt
					and not hasNode(content, raw)
					and huntedBy(content, raw, names)
				if hunted then
					part = M.format(locale, "guide_input_hunt", part, names[raw] or raw, hunted)
				end
				table.insert(parts, part)
			end
		else
			local placed = whereIsle(locale, content, input.item, name)
			if placed then
				table.insert(parts, placed)
			end
		end
	end
	return if #parts > 0 then table.concat(parts, ", ") else nil
end

-- "<what>. Practice N more times: <entry action>" when the step needs a skill node whose category
-- proficiency the player has not reached (the server refuses PROFICIENCY_GATE until then).
local function practiceFirst(locale: string, content: any, ch: any, names: any, what: string, node: string): string
	local mastery = ch.mastery
	if type(mastery) ~= "table" or not strings.guide_practice or not content.progressionPolicy then
		return what
	end
	for _, row in content.skillNodes or {} do
		if row.id == node then
			local have = mastery[row.category] or { level = 0, xp = 0 }
			if (have.level or 0) >= row.proficiency then
				return what
			end
			local training = SkillTraining.forNode(content, { mastery = { [row.category] = have } }, row)
			local action = training.action or row.category
			-- An entry action with no display name (home-harvest, ranged-hit) reads as its category.
			local label = names[action]
				or (if strings["skills." .. row.category] then M.text(locale, "skills." .. row.category) else nil)
			return M.format(locale, "guide_practice", what, training.count, label or action)
		end
	end
	return what
end

-- Display name of a guide target: guide_target_<id>, a skill node (skills.<id>), else the
-- entity name.
local function targetName(locale: string, target: string, names: any): string
	local key = "guide_target_" .. target
	if strings[key] then
		return M.text(locale, key)
	elseif strings["skills." .. target] then
		return M.text(locale, "skills." .. target)
	end
	return names[target] or target
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
	solo: boolean?,
	touch: boolean?
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
			local verb = "guide_act_" .. string.gsub(o.action, "%-", "_")
			if not strings[go] and strings[verb] and strings.guide_go_sheet then
				-- Steps without a HUD verb row read as "<Verb> <target> (Menu > Guides)": the guide
				-- sheet row carries that step's own button.
				local what =
					M.format(locale, "guide_go_sheet", M.text(locale, verb), targetName(locale, o.target, names))
				local have = math.min(progress[o.id] or 0, o.quantity)
				return M.format(locale, "guide_next", title(locale, g, names), what, have, o.quantity)
			end
			if strings[go] then
				-- p134 v73 (phone): a touch device reads the key-free row ("walk up and tap"), never "E".
				local row = if touch and strings[go .. "_touch"] then go .. "_touch" else go
				local what = M.format(locale, row, targetName(locale, o.target, names))
				if o.action == "gather" then
					what = whereIsle(locale, content, o.target, what) or what
				elseif o.action == "craft" then
					local inputs = craftInputs(locale, content, o.target, names)
					if inputs then
						what = M.format(locale, "guide_inputs", what, inputs)
					end
				elseif o.action == "capture" and strings.guide_where_capture then
					-- The dodo line names dodos; a named species gets its own drift-isle hint.
					local species = o.target ~= "creature" and o.target ~= "dodo" and strings.guide_where_species
					what = M.format(locale, if species then "guide_where_species" else "guide_where_capture", what)
				end
				if o.action == "purchase" then
					what = practiceFirst(locale, content, ch, names, what, o.target)
				elseif o.action == "craft" then
					for _, detail in content.recipeDetails or {} do
						if detail.id == o.target then
							for _, node in detail.skillNodes or {} do
								what = practiceFirst(locale, content, ch, names, what, node)
							end
						end
					end
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
-- need another player (GuideEvents.multiplayer) are skipped. With `touch`, step hints that name a
-- key (E, C, B) read their guide_go_<action>_touch row instead.
function M.guideObjective(locale: string, content: any, ch: any, names: any, solo: boolean?, touch: boolean?): string?
	local level, grade, done = ch.level or 1, math.floor((ch.points or 0) / 100), ch.definitions or {}
	local needLevel, needRank = Party.gates(content, 1)
	if grade < needRank then
		return openGuide(locale, content, ch, names, level, grade, 0, solo, touch)
	elseif level >= needLevel then
		-- Route open: an open guide of the bands past the route grade leads (route 1 stays on the
		-- Routes card); only with none open does the line point at the route.
		return openGuide(locale, content, ch, names, level, grade, needRank + 1, solo, touch)
			or M.text(locale, "guide_route_open")
	end
	-- Grade met but below the route level: a guide of the route's grade first, else any still-open
	-- start guide (chart2 lowered route 1 to grade 1, reached after two of the four start guides).
	local open = openGuide(locale, content, ch, names, level, grade, needRank, solo, touch)
		or openGuide(locale, content, ch, names, level, grade, 0, solo, touch)
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
