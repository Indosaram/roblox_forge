--!strict
-- ui.crop-specialize: pick one unused yield / time / quality effect for the crop chosen in
-- the crop book, preview the next crop, Confirm (home-specialize) or Back.
local Farming = require("../../../core/domain/home/Farming")
local Model = require("./FarmCraftModel")
local Text = require("./FarmCraftText")
local Sheet = require("./FarmCraftSheet")
local M = {}

function M.mount(ctx: any, hub: any): any
	local t = function(key: string, ...: any): string
		return Text.text(ctx.locale, key, ...)
	end
	local sheet = Sheet.new(ctx, { id = "crop-specialize", title = t("spec_title"), order = 33, hidden = true })
	local effect: string? = nil
	function sheet.render()
		if not sheet.gui.Enabled then
			return
		end
		sheet.clear()
		local crop = hub.specialize
		local home = hub.state.home
		if not crop or not home then
			sheet.label(t("farm_none"))
			sheet.footer()
			return
		end
		local entry = Farming.entry(home, crop.id)
		for _, id in Farming.EFFECTS do
			local chosen = entry.effects[id] == true
			if effect == nil and not chosen then
				effect = id
			end
			sheet.button(
				"Effect-" .. id,
				if chosen then t("spec_chosen", t(id)) elseif effect == id then "> " .. t(id) else t(id),
				function()
					effect = id
					sheet.render()
				end
			)
		end
		if effect then
			local seconds, yield, quality = Model.preview(home, crop, effect)
			sheet.label(t("spec_preview", hub.name(crop.id), seconds, yield, quality))
		end
		sheet.row(Sheet.SPLIT2, {
			{
				name = "Back",
				text = t("spec_back"),
				click = function()
					effect = nil
					hub.open("crop-book")
				end,
			},
			{
				name = "Confirm",
				text = t("spec_confirm"),
				click = function()
					sheet.send("home-specialize", { home.homeId, { crop = crop.id, effect = effect or "" } })
				end,
			},
		})
		sheet.footer()
	end
	return sheet
end

return M
