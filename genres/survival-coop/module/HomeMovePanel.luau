--!strict
-- ui.home-move: pick a destination, review what is packed and preserved, then Confirm or
-- Back. Sends survival-coop:home-move { destination }; the server refuses while storage
-- transfers are settling (safe transfer lock) and keeps grants and property history.
local Sheet = require("./SocialSheet")
local L = require("./SocialLocale")
local M = {}

local function count(map: any): number
	local n = 0
	for _ in map or {} do
		n += 1
	end
	return n
end

-- state = { home, actorId, destinations, picked, status }
function M.rows(locale: string, state: any, act: any): { any }
	local home = state and state.home
	if not home or home.owner ~= state.actorId then
		return { { text = L.text(locale, "refuse.FORBIDDEN") } }
	end
	local current = home.location or state.destinations[1]
	local rows: { any } = {
		{ text = L.text(locale, "move.current", L.text(locale, "dest." .. current)) },
	}
	if state.picked then
		table.insert(rows, { text = L.text(locale, "move.confirm_head", L.text(locale, "dest." .. state.picked)) })
		table.insert(rows, {
			text = L.text(locale, "move.packed", count(home.storage and home.storage.items), count(home.structures)),
		})
		table.insert(rows, { text = L.text(locale, "move.kept") })
		table.insert(rows, { text = L.text(locale, "move.history", #(home.moveHistory or {})) })
		table.insert(rows, { text = L.text(locale, "move.lock") })
		if state.status then
			table.insert(rows, { text = state.status })
		end
		table.insert(rows, { text = L.text(locale, "move.do"), onClick = act.confirm })
		table.insert(rows, { text = L.text(locale, "back"), onClick = act.back })
		return rows
	end
	for _, destination in state.destinations do
		if destination ~= current then
			table.insert(rows, {
				text = L.text(locale, "move.pick", L.text(locale, "dest." .. destination)),
				onClick = function()
					act.pick(destination)
				end,
			})
		end
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	return rows
end

function M.factory(ctx: any): any
	local picked: string? = nil
	local status: string? = nil
	local panel: any
	panel = Sheet.mount(ctx, {
		id = "home-move",
		name = "HomeMove",
		title = L.text(ctx.locale, "move.title"),
		order = 13,
		select = function(extensions: any): any
			return { home = extensions.home, actorId = ctx.actorId, destinations = ctx.destinations }
		end,
		rows = function(state: any): { any }
			local view = table.clone(state or { destinations = ctx.destinations })
			view.picked, view.status = picked, status
			return M.rows(ctx.locale, view, {
				pick = function(destination: string)
					picked, status = destination, nil
					panel.render()
				end,
				back = function()
					picked, status = nil, nil
					panel.render()
				end,
				confirm = function()
					local result = ctx.send("survival-coop:home-move", { state.home.homeId, { destination = picked } })
					if result.ok then
						picked, status = nil, L.text(ctx.locale, "move.done")
					else
						status = L.refusal(ctx.locale, result.reason)
					end
					panel.render()
				end,
			})
		end,
	})
	return panel
end

return M
