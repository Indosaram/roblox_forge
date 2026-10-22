--!strict
-- ui.transaction: surfaces unknown/recovering settlements. Every durable send is observed;
-- a COMMAND_PENDING or data.status == "recovering" result keeps its operation open, keyed by
-- the server operationId (trade id) or the durable requestId. Check status sends the
-- read-only survival-coop:operation-status query for that id. Only when the server has no
-- record yet (UNKNOWN_OPERATION) of a still-pending durable request is that SAME request
-- re-sent (ExtensionPanels reuses its requestId), so a check never becomes a fresh debit.
-- Close only hides the sheet; settlement continues.
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

M.QUERY = "survival-coop:operation-status"

-- Apply a status query reply to its entry: verifying/settling/delivered/rejected from the
-- server records. An unknown operationId is refused and the entry stays as it was.
function M.applyStatus(entry: any, result: any)
	if type(result) ~= "table" or not result.ok or type(result.data) ~= "table" then
		entry.query = if type(result) == "table" then result.reason else nil
		return
	end
	local state = result.data.status
	if state == "verifying" or state == "settling" or state == "delivered" or state == "rejected" then
		entry.status, entry.reason, entry.query = state, result.data.reason, nil
	end
end

-- Track one operation per action; returns the updated entry or nil when not tracked.
function M.track(entries: { [string]: any }, action: string, args: any, result: any, requestId: string?): any?
	if action == M.QUERY then
		return nil
	end
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
		else requestId or action
	local entry = {
		action = action,
		args = args,
		status = status,
		operationId = operationId,
		requestId = requestId or (if known then known.requestId else nil),
		reason = nil :: any,
	}
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
		if entry.query then
			line ..= "\n" .. L.refusal(locale, entry.query)
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
					local reply = ctx.send(M.QUERY, { entry.operationId })
					M.applyStatus(entry, reply)
					if entry.query == "UNKNOWN_OPERATION" and entry.requestId then
						-- Same pending request id: the server replays or finishes it, never re-debits.
						ctx.send(entry.action, entry.args)
					end
					panel.render()
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
		then ctx.onSend(function(action: string, args: any, result: any, requestId: string?)
			local entry = M.track(entries, action, args, result, requestId)
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
