--!strict
-- ui.farm-area: water sprayer selection overlay. Up to nine plots within radius 12 of the
-- first plot, explicit per-plot selection, per-plot water + fertilizer cost, Apply, and the
-- per-plot result list the server records (home.areaResults).
local Farming = require("../../../core/domain/home/Farming")
local Model = require("./FarmCraftModel")
local Text = require("./FarmCraftText")
local Sheet = require("./FarmCraftSheet")
local M = {}

function M.mount(ctx: any, hub: any): any
	local t = function(key: string, ...: any): string
		return Text.text(ctx.locale, key, ...)
	end
	local sheet = Sheet.new(ctx, { id = "farm-area", title = t("area_title"), order = 31, hidden = true })
	local selected: { [string]: boolean? } = {}
	local fertIndex = 1
	local applied = false
	function sheet.render()
		if not sheet.gui.Enabled then
			return
		end
		sheet.clear()
		local home = hub.state.home
		local plots = Model.plots(home, hub.now())
		sheet.label(t("area_hint"))
		if not home or #plots == 0 then
			sheet.label(t("farm_none"))
			sheet.footer()
			return
		end
		local fertilizer = Farming.FERTILIZER_ORDER[fertIndex]
		local picked, ids = 0, {}
		local index = {}
		for position, plot in plots do
			index[plot.id] = position
		end
		for _, row in Model.areaPlots(plots, plots[1]) do
			local plot = row.plot
			local on = selected[plot.id] == true
			if on then
				picked += 1
				table.insert(ids, plot.id)
			end
			sheet.button(
				"Select-" .. index[plot.id],
				(if on then "[x] " else "[ ] ")
					.. t(
						"farm_plot",
						index[plot.id],
						if plot.planted then hub.name(plot.planted.crop) else t("farm_empty")
					),
				function()
					selected[plot.id] = not on or nil
					sheet.render()
				end
			)
		end
		sheet.label(t("area_cost", picked, picked))
		sheet.row(Sheet.SPLIT2, {
			{
				name = "AreaFertilizer",
				text = t(fertilizer),
				click = function()
					fertIndex = fertIndex % #Farming.FERTILIZER_ORDER + 1
					sheet.render()
				end,
			},
			{
				name = "Apply",
				text = t("area_apply"),
				click = function()
					table.sort(ids)
					local result = sheet.send("home-area", {
						home.homeId,
						{ plot = plots[1].id, plots = table.concat(ids, ","), fertilizer = fertilizer },
					})
					applied = result.ok == true
					sheet.render()
				end,
			},
		})
		if applied then
			for _, result in home.areaResults or {} do
				local at = index[result.plot] or 0
				sheet.label(
					if result.ok then t("area_ok", at) else t("area_fail", at, Text.refusal(ctx.locale, result.reason))
				)
			end
		end
		sheet.button("Done", t("area_done"), function()
			applied = false
			hub.open("farm")
		end)
		sheet.footer()
	end
	return sheet
end

return M
