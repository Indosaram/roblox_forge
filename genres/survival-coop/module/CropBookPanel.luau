--!strict
-- ui.crop-book: eight crop species, rank 0-5 from recorded harvests, harvests to the next
-- rank, chosen and open specialization effects; Specialize opens ui.crop-specialize.
local Model = require("./FarmCraftModel")
local Text = require("./FarmCraftText")
local Sheet = require("./FarmCraftSheet")
local M = {}

local function effects(locale: string, list: { string }): string
	if #list == 0 then
		return Text.text(locale, "none")
	end
	local out = {}
	for _, id in list do
		table.insert(out, Text.text(locale, id))
	end
	return table.concat(out, ", ")
end

function M.mount(ctx: any, hub: any): any
	local t = function(key: string, ...: any): string
		return Text.text(ctx.locale, key, ...)
	end
	local sheet = Sheet.new(ctx, { id = "crop-book", title = t("book_title"), order = 32 })
	function sheet.render()
		if not sheet.gui.Enabled then
			return
		end
		sheet.clear()
		for _, row in Model.book(hub.state.home, hub.content) do
			sheet.label(
				t(
					"book_rank",
					hub.name(row.crop.id),
					row.rank,
					if row.toNext then t("book_next", row.toNext) else t("book_max")
				)
			).Name = "Crop-"
				.. row.crop.id
			sheet.label(t("book_effects", effects(ctx.locale, row.chosen), effects(ctx.locale, row.open)))
			if row.choices > 0 then
				sheet.button("Specialize-" .. row.crop.id, t("book_specialize", row.choices), function()
					hub.specialize = row.crop
					hub.open("crop-specialize")
				end)
			end
		end
		sheet.footer()
	end
	return sheet
end

return M
