--!strict
-- ui.inbox: persistent paged result ledger. Market claims (returned listings, bought items,
-- sale proceeds) Claim through market-claim; crafted output waiting in a job is collected
-- with craft-complete; committed outputs and cancellation refunds are listed with their job.
local Model = require("./FarmCraftModel")
local Text = require("./FarmCraftText")
local Sheet = require("./FarmCraftSheet")
local M = {}

function M.mount(ctx: any, hub: any): any
	local t = function(key: string, ...: any): string
		return Text.text(ctx.locale, key, ...)
	end
	local sheet = Sheet.new(ctx, { id = "inbox", title = t("inbox_title"), order = 36 })
	local page = 1
	function sheet.render()
		if not sheet.gui.Enabled then
			return
		end
		sheet.clear()
		local rows = Model.inbox(hub.state.packet, hub.state.market)
		local shown, current, pages = Model.page(rows, page)
		page = current
		if #rows == 0 then
			sheet.label(t("inbox_empty"))
		end
		for _, row in shown do
			local item = if row.catalogId then hub.name(row.catalogId) .. " x" .. tostring(row.quantity) else ""
			local short = if row.job then string.sub(row.job, 1, 8) else ""
			if row.kind == "item" or row.kind == "coins" then
				sheet.label(
					if row.kind == "item"
						then t("inbox_item", hub.name(row.catalogId), row.quantity)
						else t("inbox_coins", row.coins or 0)
				)
				sheet.button("Claim-" .. row.claim, t("inbox_claim"), function()
					sheet.send("market-claim", { row.claim })
				end)
			elseif row.kind == "ready" or row.kind == "running" then
				sheet.label(t(if row.kind == "ready" then "inbox_crafted" else "inbox_running", item, short))
				sheet.button("Collect-" .. row.job, t("job_collect"), function()
					sheet.send("craft-complete", { row.job })
				end)
			else
				sheet.label(t(if row.kind == "crafted" then "inbox_crafted" else "inbox_refund", item, short))
			end
		end
		if pages > 1 then
			sheet.button("NextPage", t("inbox_page", page, pages), function()
				page += 1
				sheet.render()
			end)
		end
		sheet.footer()
	end
	return sheet
end

return M
