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
			sheet.empty(t("farm_none"), nil, "fertility")
		end
		local crop = crops[cropIndex]
		-- Plant consumes home storage, never the bag or the tribe warehouse. Offer the
		-- real transfer here so carried seeds and water can reach that storage.
		if home and crop then
			for _, row in Model.bagRows(hub.state.packet) do
				local item = row.item
				if row.available > 0 and (item.catalogId == crop.seed or item.catalogId == "water") then
					local itemId = item.itemId
					sheet.row(Sheet.SPLIT2, {
						{
							name = "Store-" .. itemId,
							text = t("farm_store", hub.name(item.catalogId)),
							click = function()
								sheet.send("home-deposit", { home.homeId, { itemId = itemId, quantity = 1 } })
							end,
						},
					})
				end
			end
		end
		local fertilizer = Farming.FERTILIZER_ORDER[fertIndex]
		for index, plot in plots do
			local planted = plot.planted
			local cropName = if planted then hub.name(planted.crop) else ""
			local text = t(
				"farm_plot",
				index,
				if not planted
					then t("farm_empty")
					elseif plot.ready then t("farm_ready", cropName)
					else t("farm_growing", cropName, Text.clock(plot.remaining))
			)
			-- sheets3: one card per plot with its crop (or the picked seed) art on a soil bed, the
			-- growth bar and the plot's actions. sheets4: the growth is a 4-step stage bar with the stage
			-- name and a clock pill; an empty plot invites planting with the seed tray (icon + count per
			-- seed, the picked one rimmed) and one Plant button.
			if not planted then
				local seeds, seedItem = Model.count(home.storage, crop.seed)
				local water = Model.count(home.storage, "water")
				local tray = {}
				for _, entry in Model.seedTray(crops, home.storage) do
					table.insert(tray, {
						name = "Seed-" .. index .. "-" .. entry.crop,
						catalogId = entry.seed,
						count = entry.count,
						selected = entry.index == cropIndex,
						click = function()
							cropIndex = entry.index
							sheet.render()
						end,
					})
				end
				sheet.plot({
					name = "Plot-" .. index,
					catalogId = crop.seed,
					text = text,
					detail = t("farm_cost", seeds, water),
					stage = 0,
					stageText = t("farm_pick_seed", hub.name(crop.id)),
					empty = true,
					seeds = tray,
					cells = {
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
					},
				})
			else
				local span = math.max(1, (planted.readyAt or 0) - (planted.plantedAt or 0))
				local fraction = if plot.ready then 1 else 1 - plot.remaining / span
				local stage = Model.stage(fraction, plot.ready)
				sheet.plot({
					name = "Plot-" .. index,
					catalogId = planted.crop,
					text = text,
					detail = string.format("%s x%d", cropName, planted.quantity or 1),
					stage = stage,
					stageText = t(Model.STAGES[stage]),
					time = if plot.ready then nil else Text.clock(plot.remaining),
					ready = plot.ready,
					cells = if plot.ready
						then {
							{
								name = "Harvest-" .. index,
								text = t("farm_harvest"),
								click = function()
									sheet.send("home-harvest", { home.homeId, { plot = plot.id } })
								end,
							},
						}
						else {
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
									sheet.send(
										"home-fertilize",
										{ home.homeId, { plot = plot.id, fertilizer = fertilizer } }
									)
								end,
							},
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
