--!strict
-- ui.technical-support: level 60 gate; three tiers with current/new 5/10/15% effect and cost; confirm sends equipment-start.
local Rules = require("./CharacterRules")
local Text = require("./CharacterText")
local Sheet = require("./CharacterSheet")
local M = {}

M.START = "survival-coop:equipment-start"
M.COMPLETE = "survival-coop:equipment-complete"

local function focused(data: any): any?
	local gear = data.character and data.character.gear
	if not gear then
		return nil
	end
	local id = Sheet.focus.item
	if not id or not gear.equipment[id] then
		id = nil
		for _, slot in Rules.SLOTS do
			id = id or gear.equipped[slot]
		end
	end
	return if id then gear.equipment[id] else nil
end
M.focused = focused

function M.model(locale: string, data: any): { Sheet.Row }
	local content, survival = data.content, data.survival
	local tree = survival and survival.progression
	if not content or not tree then
		return { { name = "Empty", text = Text.text(locale, "char_failed") } }
	end
	local record = focused(data)
	local view = Rules.support(content, data.late, tree, record, survival.balance or 0)
	local rows: { Sheet.Row } = {}
	if tree.level < view.levelGate then
		table.insert(rows, { name = "Gate", text = Text.format(locale, "support_gate", view.levelGate, tree.level) })
	end
	if not record then
		table.insert(rows, { name = "None", text = Text.text(locale, "support_none") })
		return rows
	end
	local names = data.names or {}
	table.insert(
		rows,
		{ name = "Item", text = Text.format(locale, "support_item", names[record.catalogId] or record.catalogId) }
	)
	table.insert(rows, { name = "Current", text = Text.format(locale, "support_current", view.current) })
	for tier, entry in view.tiers do
		local row = entry.row
		local mats = (names[row.inputs[1].item] or row.inputs[1].item) .. " x" .. row.inputs[1].quantity
		table.insert(rows, {
			name = "Tier-" .. tier,
			text = Text.format(locale, "support_tier", tier, entry.value, row.cost or 0, mats),
		})
		if entry.status == "running" then
			table.insert(rows, {
				name = "Tier-" .. tier .. "-collect",
				text = Text.text(locale, "research_complete"),
				action = M.COMPLETE,
				args = { entry.jobId },
			})
		elseif entry.status == "done" then
			table.insert(rows, { name = "Tier-" .. tier .. "-done", text = Text.text(locale, "research_done") })
		elseif
			entry.status == "ready"
			or entry.reason == "CHARACTER_LEVEL_GATE"
			or entry.reason == "INSUFFICIENT_COINS"
		then
			-- The level-60 gate is shown above and enforced by the server; pressing shows its refusal.
			table.insert(rows, {
				name = "Tier-" .. tier .. "-confirm",
				text = Text.format(locale, "support_confirm", tier),
				action = M.START,
				args = { row.id, record.itemId, 1 },
			})
		else
			table.insert(rows, { name = "Tier-" .. tier .. "-locked", text = Text.refusal(locale, entry.reason) })
		end
	end
	return rows
end

function M.factory(ctx: any): any
	return Sheet.mount(ctx, {
		id = "technical-support",
		title = "support_title",
		order = 5,
		menu = false,
		model = function(l, d)
			d.content, d.names = ctx.content, ctx.names
			return M.model(l, d)
		end,
	})
end

return M
