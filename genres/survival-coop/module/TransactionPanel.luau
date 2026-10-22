--!strict
-- ui.transaction: surfaces unknown/recovering settlements. Every durable send is observed;
-- a COMMAND_PENDING or data.status == "recovering" result keeps its operation open. Check
-- status re-sends the SAME pending request (ExtensionPanels reuses its requestId), so a
-- retry can never become a fresh debit. Close only hides the sheet; settlement continues.
local Sheet = require("./SocialSheet")
local L = require("./SocialLocale")
local M = {}

function M.classify(result: any): string
	if type(result) ~= "table" then
		return "verifying"
	end
	if result.reason == "COMMAND_PENDING" or (type(result.data) == "table" and result.data.status == "recovering") then
		return "settling"
	end
	if type(result.reason) == "string" and string.sub(result.reason, 1, 16) == "TRANSPORT_FAILED" then
		return "verifying"
	end
	return if result.ok then "delivered" else "rejected"
end

-- Track one operation per action; returns the updated entry or nil when not tracked.
function M.track(entries: { [string]: any }, action: string, args: any, result: any): any?
	local status = M.classify(result)
	local known = entries[action]
	if not known and (status == "delivered" or status == "rejected") then
		return nil
	end
	local operationId = if type(result) == "table"
			and type(result.data) == "table"
			and result.data.operationId
		then tostring(result.data.operationId)
		elseif known then known.operationId
		else action
	local entry = { action = action, args = args, status = status, operationId = operationId, reason = nil :: any }
	if type(result) == "table" then
		entry.reason = result.reason
	end
	entries[action] = entry
	return entry
end

function M.rows(locale: string, entries: { [string]: any }, act: any): { any }
	local actions = {}
	for action in entries do
		table.insert(actions, action)
	end
	table.sort(actions)
	if #actions == 0 then
		return { { text = L.text(locale, "tx.none") }, { text = L.text(locale, "tx.close"), onClick = act.close } }
	end
	local rows: { any } = {}
	for _, action in actions do
		local entry = entries[action]
		local line = L.text(locale, "tx.op", entry.operationId) .. "\n"
		if entry.status == "rejected" then
			line ..= L.text(locale, "tx.rejected", L.refusal(locale, entry.reason))
		else
			line ..= L.text(locale, "tx." .. entry.status)
		end
		table.insert(rows, { text = line })
		if entry.status == "settling" or entry.status == "verifying" then
			table.insert(rows, {
				text = L.text(locale, "tx.check"),
				onClick = function()
					act.check(entry)
				end,
			})
		end
	end
	table.insert(rows, { text = L.text(locale, "tx.close"), onClick = act.close })
	return rows
end

function M.factory(ctx: any): any
	local entries: { [string]: any } = {}
	local panel: any
	panel = Sheet.mount(ctx, {
		id = "transaction",
		name = "Transaction",
		title = L.text(ctx.locale, "tx.title"),
		order = 14,
		select = function(): any
			return entries
		end,
		rows = function(): { any }
			return M.rows(ctx.locale, entries, {
				check = function(entry: any)
					ctx.send(entry.action, entry.args)
				end,
				close = function()
					for action, entry in entries do
						if entry.status == "delivered" or entry.status == "rejected" then
							entries[action] = nil
						end
					end
					panel.close()
				end,
			})
		end,
	})
	local stop = if ctx.onSend
		then ctx.onSend(function(action: string, args: any, result: any)
			local entry = M.track(entries, action, args, result)
			if entry and (entry.status == "settling" or entry.status == "verifying") and not panel.isOpen() then
				panel.show()
			end
			panel.render()
		end)
		else function() end
	local destroy = panel.destroy
	panel.destroy = function()
		stop()
		destroy()
	end
	return panel
end

return M
