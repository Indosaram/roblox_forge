--!strict
-- ui.island-rank: 100 development points per rank, current/next bound, lab unlock, first-award catalog.
local Rules = require("./CharacterRules")
local Text = require("./CharacterText")
local Sheet = require("./CharacterSheet")
local M = {}

function M.model(locale: string, data: any): { Sheet.Row }
	local content, character = data.content, data.character
	if not content then
		return { { name = "Empty", text = Text.text(locale, "char_failed") } }
	end
	local points = if character then character.points or 0 else 0
	local rank = Rules.rank(points)
	local lab = Rules.labRank(content)
	local rows: { Sheet.Row } = {
		{ name = "Rank", text = Text.format(locale, "char_rank", rank) },
		{ name = "Points", text = Text.format(locale, "rank_points", points) },
		{
			name = "Next",
			text = if rank >= Rules.MAX_RANK
				then Text.text(locale, "rank_max")
				else Text.format(locale, "rank_next", (rank + 1) * Rules.RANK_POINTS),
		},
		{
			name = "Lab",
			text = Text.format(locale, if rank >= lab then "rank_lab_open" else "rank_lab_locked", lab),
		},
		{ name = "Guide", text = Text.text(locale, "rank_guide") },
	}
	for _, cell in Rules.cells(content, rank) do
		table.insert(rows, {
			name = "Cell-" .. cell.id,
			text = Text.format(
				locale,
				if cell.open then "rank_cell_open" else "rank_cell_locked",
				cell.island,
				cell.stage,
				cell.width,
				cell.depth,
				cell.rank
			),
		})
	end
	local names = data.names or {}
	for index, award in Rules.awards(content, if character then character.definitions else nil) do
		if index > 40 then
			break
		end
		table.insert(rows, {
			name = "Award-" .. award.id,
			text = Text.format(
				locale,
				if award.earned then "rank_award_done" else "rank_award",
				names[award.id] or award.id,
				award.points
			),
		})
	end
	return rows
end

function M.factory(ctx: any): any
	return Sheet.mount(ctx, {
		id = "island-rank",
		title = "rank_title",
		order = 3,
		menu = false,
		model = function(l, d)
			d.content, d.names = ctx.content, ctx.names
			return M.model(l, d)
		end,
	})
end

return M
