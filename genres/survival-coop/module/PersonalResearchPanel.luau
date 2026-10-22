--!strict
-- ui.personal-research: life/light/heavy x 3 tiers; cost, materials, duration, benefit; Start / Collect / Cancel with refund quote.
local Rules = require("./CharacterRules")
local Text = require("./CharacterText")
local Sheet = require("./CharacterSheet")
local M = {}

M.START = "survival-coop:equipment-start"
M.COMPLETE = "survival-coop:equipment-complete"
M.CANCEL = "survival-coop:equipment-cancel"

local function materials(row: any, names: any): string
	local parts = {}
	for _, input in row.inputs do
		table.insert(parts, (names[input.item] or input.item) .. " x" .. input.quantity)
	end
	return table.concat(parts, ", ")
end

function M.model(locale: string, data: any): { Sheet.Row }
	local content, survival, character = data.content, data.survival, data.character
	local tree = survival and survival.progression
	if not content or not tree then
		return { { name = "Empty", text = Text.text(locale, "char_failed") } }
	end
	local rank = Rules.rank(if character then character.points or 0 else 0)
	local now = if character then character.now or 0 else 0
	local rows: { Sheet.Row } = {}
	for _, line in Rules.research(content, data.late, tree, rank, survival.balance or 0) do
		table.insert(
			rows,
			{ name = "Line-" .. line.line, text = Text.format(locale, "research_line_" .. line.line, line.benefit) }
		)
		for tier, entry in line.tiers do
			local row = entry.row
			local base = "R-" .. row.id
			table.insert(rows, {
				name = base,
				text = Text.format(
					locale,
					"research_tier",
					tier,
					row.effects[1].value,
					row.cost or 0,
					materials(row, data.names or {}),
					row.seconds
				),
				height = 56,
			})
			if entry.status == "done" then
				table.insert(rows, { name = base .. "-done", text = Text.text(locale, "research_done") })
			elseif entry.status == "running" then
				local left = math.max(0, (entry.finishAt or 0) - now)
				table.insert(rows, { name = base .. "-left", text = Text.format(locale, "research_running", left) })
				table.insert(rows, {
					name = base .. "-collect",
					text = Text.text(locale, "research_complete"),
					action = M.COMPLETE,
					args = { entry.jobId },
				})
				table.insert(rows, {
					name = base .. "-cancel",
					text = Text.format(locale, "research_cancel", entry.refund or 0),
					action = M.CANCEL,
					args = { entry.jobId },
				})
			elseif entry.status == "ready" or entry.reason == "INSUFFICIENT_COINS" then
				table.insert(rows, {
					name = base .. "-start",
					text = Text.text(locale, "research_start"),
					action = M.START,
					args = { row.id, "research", 1 },
				})
			else
				table.insert(rows, { name = base .. "-locked", text = Text.refusal(locale, entry.reason) })
			end
		end
	end
	return rows
end

function M.factory(ctx: any): any
	return Sheet.mount(ctx, {
		id = "personal-research",
		title = "research_title",
		order = 4,
		menu = false,
		model = function(l, d)
			d.content, d.names = ctx.content, ctx.names
			return M.model(l, d)
		end,
	})
end

return M
