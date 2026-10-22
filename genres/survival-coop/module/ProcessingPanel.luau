--!strict
-- ui.processing: six processes, the eligible bag stack per recipe with its processing
-- budget and before/after attribute deltas, the 5/10-second duration and Start
-- (craft-reserve at the nearest matching station), then the job's Start / Collect.
local HudModel = require("./SurvivalHUDModel")
local Model = require("./FarmCraftModel")
local Text = require("./FarmCraftText")
local Sheet = require("./FarmCraftSheet")
local M = {}

function M.mount(ctx: any, hub: any): any
	local t = function(key: string, ...: any): string
		return Text.text(ctx.locale, key, ...)
	end
	local sheet = Sheet.new(ctx, { id = "processing", title = t("proc_title"), order = 34 })
	local processIndex = 1
	function sheet.render()
		if not sheet.gui.Enabled then
			return
		end
		sheet.clear()
		local process = Model.PROCESSES[processIndex]
		sheet.button("Process", t("proc_kind", t(process)), function()
			processIndex = processIndex % #Model.PROCESSES + 1
			sheet.render()
		end)
		local rows = Model.processing(hub.content, hub.state.packet, process)
		if #rows == 0 then
			sheet.label(t("proc_none"))
		end
		for _, row in rows do
			local recipe = row.recipe
			sheet.label(
				t(
					"proc_row",
					hub.name(row.item.catalogId),
					hub.name(recipe.outputs[1].item),
					row.seconds,
					row.budget,
					row.after
				)
			)
			local deltas = {}
			for _, delta in row.deltas do
				table.insert(deltas, t("proc_delta", hub.name(delta.id), delta.before, delta.after))
			end
			sheet.label(table.concat(deltas, "  "))
			sheet.button("Start-" .. recipe.id, t("proc_start", hub.name(recipe.id)), function()
				sheet.send("craft-reserve", { recipe.id, hub.station(recipe.station) })
			end)
		end
		for _, entry in HudModel.jobs(Model.genre(hub.state.packet), hub.actor()) do
			if string.match(entry.job.recipeId, "^([a-z]+)%-") == process then
				local verb = if entry.job.state == "Reserved" then "start" else "complete"
				sheet.button(
					verb .. "-" .. entry.id,
					hub.name(entry.job.recipeId) .. ": " .. t(if verb == "start" then "job_start" else "job_collect"),
					function()
						sheet.send("craft-" .. verb, { entry.id })
					end
				)
			end
		end
		sheet.footer()
	end
	return sheet
end

return M
