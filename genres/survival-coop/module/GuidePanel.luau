--!strict
-- ui.guides: island development grade progress (current / required points), then every open guide
-- with its objectives, progress and rewards. Guides whose action has no command yet say so
-- (GuideEvents.UNSUPPORTED) instead of showing a goal the player cannot reach.
local Rules = require("./CharacterRules")
local Text = require("./CharacterText")
local Sheet = require("./CharacterSheet")
local GuideEvents = require("./GuideEvents")
local M = {}

local function label(locale: string, names: any, id: string): string
	local key = "guide_target_" .. id
	return if Text.has(key) then Text.text(locale, key) else names[id] or id
end

function M.model(locale: string, data: any): { Sheet.Row }
	local content, character = data.content, data.character
	if not content or not character then
		return { { name = "Empty", text = Text.text(locale, "char_failed") } }
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
	local done, locked = 0, nil
	for _, guide in content.guides or {} do
		if definitions[guide.id] then
			done += 1
		elseif not GuideEvents.open(guide, level, grade) then
			local gates = guide.gates or {}
			locked = locked or gates
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
				table.insert(rows, {
					name = "Objective-" .. objective.id,
					text = Text.format(
						locale,
						if missing then "guide_objective_missing" else "guide_objective",
						if Text.has(verb) then Text.text(locale, verb) else objective.action,
						label(locale, names, objective.target),
						math.min(progress[objective.id] or 0, objective.quantity),
						objective.quantity
					),
				})
			end
		end
	end
	table.insert(rows, 3, {
		name = "Done",
		text = Text.format(locale, "guide_done", done, #(content.guides or {})),
	})
	if locked then
		table.insert(rows, {
			name = "Locked",
			text = Text.format(locale, "guide_locked", locked.characterLevel or 1, locked.developmentRank or 0),
		})
	end
	return rows
end

function M.factory(ctx: any): any
	return Sheet.mount(ctx, {
		id = "guides",
		title = "guide_title",
		order = 2,
		menu = true,
		model = function(l, d)
			d.content, d.names = ctx.content, ctx.names
			return M.model(l, d)
		end,
	})
end

return M
