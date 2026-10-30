--!strict
-- ui.guides: island development grade progress (current / required points), then every open guide
-- with its objectives, progress and rewards. Guides whose action has no command yet say so
-- (GuideEvents.UNSUPPORTED) instead of showing a goal the player cannot reach. Level-locked guides
-- of the current grade band follow as locked rows (nearest level first, at most UPCOMING), and the
-- Locked line names the nearest gate: the lowest level among guides the grade already allows, else
-- the lowest level overall.
local Rules = require("./CharacterRules")
local Text = require("./CharacterText")
local Sheet = require("./CharacterSheet")
local GuideEvents = require("./GuideEvents")
local M = {}

local ACK: { [string]: any } = {}
for _, verb in GuideEvents.VERBS do
	ACK[verb] = function(target: string): (string, { any })
		return GuideEvents.ACT, { verb, target }
	end
end
-- The support steps (g18) run the real quote command; the server reads the authored tier row.
local QUOTE: { [string]: string } = { preview = "preview", ["acknowledge-level-gate"] = "acknowledge" }
for verb, mode in QUOTE do
	ACK[verb] = function(target: string): (string, { any })
		return "survival-coop:equipment-quote", { target, mode }
	end
end

M.UPCOMING = 3

-- Steps performed on another panel (p111): the row opens the panel that sends the real command
-- (route sharing on the party sheet, role preview and drafts on clan roles, loans at the camp).
M.OPEN = table.freeze({
	["invite-training"] = "party",
	revoke = "party",
	["preview-role"] = "clan-roles",
	["draft-membership"] = "clan-roles",
	["cancel-draft"] = "clan-roles",
	["equip-loan"] = "camp",
	["return-loan"] = "camp",
})

local function before(a: any, b: any): boolean
	local ga, gb = a.gates or {}, b.gates or {}
	local la, lb = ga.characterLevel or 1, gb.characterLevel or 1
	if la ~= lb then
		return la < lb
	end
	return (ga.developmentRank or 0) < (gb.developmentRank or 0)
end

local function label(locale: string, names: any, id: string): string
	local key = "guide_target_" .. id
	return if Text.has(key) then Text.text(locale, key) else names[id] or id
end

function M.model(locale: string, data: any): { Sheet.Row }
	local content, character = data.content, data.character
	if not content or not character then
		return { { name = "Empty", text = Text.text(locale, "char_empty") } }
	end
	local names = data.names or {}
	local points = character.points or 0
	local grade = Rules.rank(points)
	local level = character.level or 1
	local definitions = character.definitions or {}
	local progress = character.progress or {}
	local rows: { Sheet.Row } = {
		{
			name = "Grade",
			text = if grade >= Rules.MAX_RANK
				then Text.text(locale, "rank_max")
				else Text.format(locale, "guide_grade", grade, points, (grade + 1) * Rules.RANK_POINTS, grade + 1),
		},
		{ name = "How", text = Text.text(locale, "guide_how"), height = 52 },
	}
	local done, nearest, lowest, upcoming = 0, nil, nil, {}
	for _, guide in content.guides or {} do
		if definitions[guide.id] then
			done += 1
		elseif not GuideEvents.open(guide, level, grade) then
			if lowest == nil or before(guide, lowest) then
				lowest = guide
			end
			if ((guide.gates or {}).developmentRank or 0) <= grade then
				table.insert(upcoming, guide)
				if nearest == nil or before(guide, nearest) then
					nearest = guide
				end
			end
		else
			local short = string.match(guide.id, "^rw%.(g%d+)") or guide.id
			local rewards = guide.rewards or {}
			table.insert(rows, {
				name = "Guide-" .. guide.id,
				text = Text.format(
					locale,
					"guide_reward",
					Text.text(locale, "guide_" .. short),
					rewards.development or 0,
					rewards.coins or 0
				),
			})
			for _, objective in guide.objectives do
				local verb = "guide_act_" .. string.gsub(objective.action, "%-", "_")
				local missing = GuideEvents.UNSUPPORTED[objective.action] ~= nil
				-- Acknowledgement steps are performed from this row (guide-act); the server checks order.
				local pending = (progress[objective.id] or 0) < objective.quantity
				local tap = ACK[objective.action] ~= nil and pending
				local panel = if pending then M.OPEN[objective.action] else nil
				local action, args = nil, nil
				if tap then
					action, args = ACK[objective.action](objective.target)
				end
				table.insert(rows, {
					name = "Objective-" .. objective.id,
					text = Text.format(
						locale,
						if missing
							then "guide_objective_missing"
							elseif tap or panel then "guide_objective_tap"
							else "guide_objective",
						if Text.has(verb) then Text.text(locale, verb) else objective.action,
						label(locale, names, objective.target),
						math.min(progress[objective.id] or 0, objective.quantity),
						objective.quantity
					),
					action = action,
					args = args,
					open = panel,
				})
			end
		end
	end
	table.insert(rows, 3, {
		name = "Done",
		text = Text.format(locale, "guide_done", done, #(content.guides or {})),
	})
	table.sort(upcoming, before)
	for index = 1, math.min(M.UPCOMING, #upcoming) do
		local guide = upcoming[index]
		local short = string.match(guide.id, "^rw%.(g%d+)") or guide.id
		local rewards = guide.rewards or {}
		table.insert(rows, {
			name = "Upcoming-" .. guide.id,
			text = Text.format(
				locale,
				"guide_upcoming",
				Text.text(locale, "guide_" .. short),
				(guide.gates or {}).characterLevel or 1,
				rewards.development or 0,
				rewards.coins or 0
			),
			enabled = false,
		})
	end
	local near = nearest or lowest
	local locked = if near then near.gates or {} else nil
	if locked then
		table.insert(rows, {
			name = "Locked",
			text = Text.format(locale, "guide_locked", locked.characterLevel or 1, locked.developmentRank or 0),
		})
	end
	return rows
end

-- U7: development-grade hero (grade, points bar, guides done / next gate chips) over the rows.
local HERO = { Grade = true, How = true, Done = true, Locked = true }
function M.cards(locale: string, data: any, size: number, icons: any): (string, any, (any) -> ())
	local by = {}
	for _, row in M.model(locale, data) do
		by[row.name] = row.text
	end
	if not by.Grade then
		return "", {}, function() end
	end
	local points = (data.character or {}).points or 0
	local grade = Rules.rank(points)
	local chips = { { icon = icons.ui("success"), text = by.Done } }
	if by.Locked then
		table.insert(chips, { icon = icons.ui("locked"), text = by.Locked })
	end
	return by.Grade .. by.Done .. (by.Locked or ""),
		HERO,
		function(parent)
			require("./SheetCards").hero(parent, {
				icon = icons.ui("help"),
				title = by.Grade,
				fraction = if grade >= Rules.MAX_RANK then 1 else (points % Rules.RANK_POINTS) / Rules.RANK_POINTS,
				caption = by.How,
				chips = chips,
				size = size,
			})
		end
end

function M.factory(ctx: any): any
	return Sheet.mount(ctx, {
		id = "guides",
		title = "guide_title",
		order = -1,
		menu = true,
		model = function(l, d)
			d.content, d.names = ctx.content, ctx.names
			return M.model(l, d)
		end,
		cards = function(l, d, size)
			d.content, d.names = ctx.content, ctx.names
			return M.cards(l, d, size, ctx.icons)
		end,
	})
end

return M
