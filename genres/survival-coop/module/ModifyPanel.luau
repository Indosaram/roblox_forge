--!strict
-- ui.modify: equipped item, two slots, fixed +2 effects with material cost, replace-without-refund warning, apply per slot.
local Rules = require("./CharacterRules")
local Text = require("./CharacterText")
local Sheet = require("./CharacterSheet")
local M = {}

local Support = require("./TechnicalSupportPanel")
M.START = "survival-coop:equipment-start"
M.COMPLETE = "survival-coop:equipment-complete"

function M.model(locale: string, data: any): { Sheet.Row }
	local content, survival = data.content, data.survival
	local tree = survival and survival.progression
	if not content or not tree then
		return { { name = "Empty", text = Text.text(locale, "char_failed") } }
	end
	local record = Support.focused(data)
	if not record then
		return { { name = "None", text = Text.text(locale, "support_none") } }
	end
	local names = data.names or {}
	local view = Rules.modify(content, data.late, tree, record)
	local rows: { Sheet.Row } = {
		{ name = "Item", text = Text.format(locale, "support_item", names[record.catalogId] or record.catalogId) },
	}
	for slot = 1, 2 do
		local effect = view.slots[slot]
		table.insert(rows, {
			name = "Slot-" .. slot,
			text = Text.format(
				locale,
				"modify_slot",
				slot,
				if effect
					then "+" .. effect.value .. " " .. Text.text(locale, "attr_" .. effect.id)
					else Text.text(locale, "modify_empty")
			),
		})
	end
	table.insert(rows, { name = "Warning", text = Text.text(locale, "modify_warning") })
	if view.jobId then
		table.insert(rows, {
			name = "Collect",
			text = Text.text(locale, "research_complete"),
			action = M.COMPLETE,
			args = { view.jobId },
		})
		return rows
	end
	for _, entry in view.rows do
		local row = entry.row
		local attribute = Text.text(locale, "attr_" .. row.effects[1].id)
		local mats = (names[row.inputs[1].item] or row.inputs[1].item) .. " x" .. row.inputs[1].quantity
		table.insert(rows, { name = "Mod-" .. row.id, text = Text.format(locale, "modify_row", attribute, mats) })
		for slot = 1, 2 do
			table.insert(rows, {
				name = "Mod-" .. row.id .. "-" .. slot,
				text = Text.format(locale, "modify_apply", slot),
				action = M.START,
				args = { row.id, record.itemId, slot },
			})
		end
	end
	return rows
end

function M.factory(ctx: any): any
	return Sheet.mount(ctx, {
		id = "modify",
		title = "modify_title",
		order = 6,
		menu = false,
		model = function(l, d)
			d.content, d.names = ctx.content, ctx.names
			return M.model(l, d)
		end,
	})
end

return M
