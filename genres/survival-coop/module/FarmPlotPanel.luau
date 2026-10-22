--!strict
-- ui.farm-plot: placed home farm plots with Plant / Fertilize / Harvest, the seed + water
-- cost and the exact time to the next harvest. Opened from the Menu (Farm) or a plot's
-- ProximityPrompt (ForgePanel = "farm").
local Farming = require("../../../core/domain/home/Farming")
local Model = require("./FarmCraftModel")
local Text = require("./FarmCraftText")
local Sheet = require("./FarmCraftSheet")
local M = {}

function M.mount(ctx: any, hub: any): any
	local t = function(key: string, ...: any): string
		return Text.text(ctx.locale, key, ...)
	end
	local sheet = Sheet.new(ctx, { id = "farm", title = t("farm_title"), order = 30 })
	local cropIndex, fertIndex = 1, 1
	function sheet.render()
		if not sheet.gui.Enabled then
			return
		end
		sheet.clear()
		local home = hub.state.home
		local crops = Model.crops(hub.content)
		local plots = Model.plots(home, hub.now())
		if not home or #plots == 0 then
			sheet.label(t("farm_none"))
		end
		local crop = crops[cropIndex]
		local fertilizer = Farming.FERTILIZER_ORDER[fertIndex]
		for index, plot in plots do
			local planted = plot.planted
			local cropName = if planted then hub.name(planted.crop) else ""
			sheet.label(
				t(
					"farm_plot",
					index,
					if not planted
						then t("farm_empty")
						elseif plot.ready then t("farm_ready", cropName)
						else t("farm_growing", cropName, Text.clock(plot.remaining))
				)
			).Name = "Plot-"
				.. index
			if not planted then
				local seeds, seedItem = Model.count(home.storage, crop.seed)
				local water = Model.count(home.storage, "water")
				sheet.label(t("farm_cost", seeds, water))
				sheet.row(Sheet.SPLIT2, {
					{
						name = "Crop-" .. index,
						text = hub.name(crop.id),
						click = function()
							cropIndex = cropIndex % #crops + 1
							sheet.render()
						end,
					},
					{
						name = "Plant-" .. index,
						text = t("farm_plant"),
						click = function()
							sheet.send(
								"home-plant",
								{ home.homeId, { crop = crop.id, plot = plot.id, seedItem = seedItem or "none" } }
							)
						end,
					},
				})
			elseif plot.ready then
				sheet.button("Harvest-" .. index, t("farm_harvest"), function()
					sheet.send("home-harvest", { home.homeId, { plot = plot.id } })
				end)
			else
				sheet.row(Sheet.SPLIT2, {
					{
						name = "Fertilizer-" .. index,
						text = t(fertilizer),
						click = function()
							fertIndex = fertIndex % #Farming.FERTILIZER_ORDER + 1
							sheet.render()
						end,
					},
					{
						name = "Fertilize-" .. index,
						text = t("farm_fertilize"),
						click = function()
							sheet.send("home-fertilize", { home.homeId, { plot = plot.id, fertilizer = fertilizer } })
						end,
					},
				})
			end
		end
		sheet.row(Sheet.SPLIT2, {
			{
				name = "Sprayer",
				text = t("farm_area"),
				click = function()
					hub.open("farm-area")
				end,
			},
			{
				name = "CropBook",
				text = t("farm_book"),
				click = function()
					hub.open("crop-book")
				end,
			},
		})
		sheet.footer()
	end
	return sheet
end

return M
