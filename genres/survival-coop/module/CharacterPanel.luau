--!strict
-- ui.character: level 1-60, next XP, available/total SP, exploration rank 0-10 and award checklist count.
local Rules = require("./CharacterRules")
local Text = require("./CharacterText")
local Sheet = require("./CharacterSheet")
local M = {}

function M.model(locale: string, data: any): { Sheet.Row }
	local survival, character, content = data.survival, data.character, data.content
	local tree = survival and survival.progression
	if not tree or not content then
		return { { name = "Empty", text = Text.text(locale, "char_failed") } }
	end
	local view = Rules.character(content, tree, if character then character.points or 0 else 0)
	local awards = Rules.awards(content, if character then character.definitions else nil)
	local earned = 0
	for _, award in awards do
		earned += if award.earned then 1 else 0
	end
	return {
		{ name = "Level", text = Text.format(locale, "char_level", view.level, view.maxLevel) },
		{
			name = "XP",
			text = if view.nextXP > 0
				then Text.format(locale, "char_xp", view.xp, view.nextXP)
				else Text.text(locale, "char_xp_max"),
		},
		{ name = "SP", text = Text.format(locale, "char_sp", view.sp, view.totalSP) },
		{ name = "Rank", text = Text.format(locale, "char_rank", view.rank) },
		{ name = "Awards", text = Text.format(locale, "char_awards", earned, #awards) },
		{ name = "OpenRank", text = Text.text(locale, "char_open_rank"), open = "island-rank" },
		{ name = "OpenReset", text = Text.text(locale, "char_open_reset"), open = "skill-reset" },
		{ name = "OpenEquipment", text = Text.text(locale, "char_open_equipment"), open = "equipment" },
		{ name = "OpenResearch", text = Text.text(locale, "char_open_research"), open = "personal-research" },
	}
end

function M.factory(ctx: any): any
	return Sheet.mount(ctx, {
		id = "character",
		title = "char_title",
		order = 1,
		menu = true,
		model = function(l, d)
			d.content = ctx.content
			return M.model(l, d)
		end,
	})
end

return M
