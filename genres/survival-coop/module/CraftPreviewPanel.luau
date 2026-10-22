--!strict
-- ui.craft-preview: for one recipe, the exact bag stacks the server will reserve split into
-- main (primary) and support ingredients with level/quality, deterministic output level,
-- duration, main-material return bonus, a 1-15 count stepper and Queue (craft-reserve x n).
local Model = require("./FarmCraftModel")
local Text = require("./FarmCraftText")
local Sheet = require("./FarmCraftSheet")
local M = {}

function M.mount(ctx: any, hub: any): any
	local t = function(key: string, ...: any): string
		return Text.text(ctx.locale, key, ...)
	end
	local sheet = Sheet.new(ctx, { id = "craft-preview", title = t("preview_title"), order = 35 })
	local recipeIndex, count = 1, 1
	local queued: string? = nil
	function sheet.render()
		if not sheet.gui.Enabled then
			return
		end
		sheet.clear()
		local recipes = hub.content.recipes
		local recipe = recipes[recipeIndex]
		sheet.button("Recipe", t("preview_recipe", hub.name(recipe.id)), function()
			recipeIndex = recipeIndex % #recipes + 1
			queued = nil
			sheet.render()
		end)
		local preview = Model.recipePreview(hub.content, hub.state.packet, recipe)
		for _, row in preview.rows do
			local name = hub.name(row.input.item)
			if not row.main then
				sheet.label(t("preview_support", name, row.input.quantity, row.have))
			elseif #row.stacks == 0 or row.missing > 0 then
				sheet.label(t("preview_missing", name, row.missing))
			end
			for _, stack in if row.main then row.stacks else {} do
				local item = stack.item
				local level = if item.material then item.material.level else tonumber(item.attributes.level) or 0
				sheet.label(t("preview_main", name, stack.take, item.itemId, level, item.qualityMilli // 1000))
			end
		end
		sheet.label(
			t("preview_out", hub.name(preview.output.item), preview.output.quantity, preview.level, preview.seconds)
		)
		sheet.label(t("preview_bonus", preview.bonus))
		sheet.row(Sheet.SPLIT3, {
			{
				name = "Less",
				text = t("preview_less"),
				click = function()
					count = math.max(1, count - 1)
					sheet.render()
				end,
			},
			{
				name = "Count",
				text = t("preview_count", count),
				click = function() end,
			},
			{
				name = "More",
				text = t("preview_more"),
				click = function()
					count = math.min(Model.MAX_COUNT, count + 1)
					sheet.render()
				end,
			},
		})
		sheet.button("Queue", t("preview_queue", count), function()
			local done = 0
			for _ = 1, count do
				local result = ctx.send("survival-coop:craft-reserve", { recipe.id, hub.station(recipe.station) })
				if not result.ok then
					sheet.status = Text.refusal(ctx.locale, result.reason)
					break
				end
				done += 1
			end
			queued = t("preview_queued", done, count)
			if done == count then
				sheet.status = ""
			end
			sheet.render()
		end)
		if queued then
			sheet.label(queued).Name = "Queued"
		end
		sheet.footer()
	end
	return sheet
end

return M
