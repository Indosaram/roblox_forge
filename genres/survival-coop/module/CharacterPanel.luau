--!strict
-- ui.character: level 1-60, next XP, available/total SP, exploration rank 0-10 and award checklist count.
local Rules = require("./CharacterRules")
local Text = require("./CharacterText")
local Sheet = require("./CharacterSheet")
local Cards = require("./SheetCards")
local M = {}

-- U6: portrait hero (level, XP bar, SP / rank / awards chips) built from the model rows.
local HERO = { Level = true, XP = true, SP = true, Rank = true, Awards = true }
function M.cards(locale: string, data: any, size: number, icons: any): (string, any, (any) -> ())
	local rows, by = M.model(locale, data), {}
	for _, row in rows do
		by[row.name] = row.text
	end
	if not by.Level then
		return "", {}, function() end
	end
	local tree = data.survival.progression
	local xp = Rules.character(data.content, tree, 0)
	return by.Level .. by.XP .. by.SP .. by.Rank .. by.Awards,
		HERO,
		function(parent)
			Cards.hero(parent, {
				icon = icons.ui("member"),
				title = by.Level,
				fraction = if xp.nextXP > 0 then xp.xp / xp.nextXP else 1,
				caption = by.XP,
				chips = {
					{ icon = icons.ui("skill-point"), text = by.SP },
					{ icon = icons.ui("exploration-rank"), text = by.Rank },
					{ icon = icons.ui("success"), text = by.Awards },
				},
				size = size,
			})
		end
end

function M.model(locale: string, data: any): { Sheet.Row }
	local survival, character, content = data.survival, data.character, data.content
	local tree = survival and survival.progression
	if not tree or not content then
		return { { name = "Empty", text = Text.text(locale, "char_empty") } }
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
		cards = function(l, d, size)
			d.content = ctx.content
			return M.cards(l, d, size, ctx.icons)
		end,
	})
end

return M
