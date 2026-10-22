--!strict
-- ui.skill-reset: versioned quote (removed nodes, paid SP refund, mastery kept); Confirm sends skill-reset with the quote version.
local Rules = require("./CharacterRules")
local Text = require("./CharacterText")
local Sheet = require("./CharacterSheet")
local M = {}

M.RESET = "survival-coop:skill-reset"

function M.model(locale: string, data: any): { Sheet.Row }
	local tree = data.survival and data.survival.progression
	if not tree then
		return { { name = "Empty", text = Text.text(locale, "char_failed") } }
	end
	local quote = Rules.resetQuote(tree)
	local rows: { Sheet.Row } = {
		{ name = "Refund", text = Text.format(locale, "reset_refund", quote.refund) },
		{
			name = "Nodes",
			text = if #quote.nodes > 0
				then Text.format(locale, "reset_nodes", #quote.nodes)
				else Text.text(locale, "reset_none"),
		},
		{ name = "Keep", text = Text.text(locale, "reset_keep") },
		{ name = "Busy", text = Text.text(locale, "reset_busy_note") },
	}
	if #quote.nodes > 0 then
		table.insert(rows, {
			name = "Confirm",
			text = Text.text(locale, "reset_confirm"),
			action = M.RESET,
			args = { quote.version },
			success = "reset_done",
		})
	end
	return rows
end

function M.factory(ctx: any): any
	return Sheet.mount(ctx, { id = "skill-reset", title = "reset_title", order = 2, menu = false, model = M.model })
end

return M
