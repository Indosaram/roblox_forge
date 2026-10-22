--!strict
-- ui.home-permissions: owner-only grants for visit / use / build / recover on the personal
-- island, plus the offline-help switch. Each tap cycles one category and sends the full ACL
-- through survival-coop:home-permissions (friend list stays server-side). Opens ui.home-move.
local Sheet = require("./SocialSheet")
local L = require("./SocialLocale")
local M = {}

M.CYCLE = { "owner", "friend", "clan" }

local function nextMode(mode: string): string
	local index = table.find(M.CYCLE, mode) or (if mode == "none" then 1 else 0)
	return M.CYCLE[index % #M.CYCLE + 1]
end

function M.grants(home: any): any
	local acl = home.permissions
	local grants = acl.grants or {}
	return {
		visit = acl.visit,
		use = grants.use or acl.cooperate,
		build = grants.build or acl.cooperate,
		recover = grants.recover or acl.cooperate,
	}
end

-- The ACL a tap on `category` sends: every category explicit, friends omitted.
function M.request(home: any, category: string?, clanId: string?, offline: boolean?): any
	local current = M.grants(home)
	if category then
		current[category] = nextMode(current[category])
	end
	return {
		visit = current.visit,
		cooperate = current.use,
		grants = { use = current.use, build = current.build, recover = current.recover },
		clanId = if clanId and clanId ~= "" then clanId else home.permissions.clanId,
		offlineCoop = if offline == nil then home.permissions.offlineCoop else offline,
		anyFriend = true,
	}
end

-- state = { home, actorId, clanId, status }
function M.rows(locale: string, state: any, act: any): { any }
	local home = state and state.home
	if not home or home.owner ~= state.actorId then
		return { { text = L.text(locale, "refuse.FORBIDDEN") } }
	end
	local grants = M.grants(home)
	local rows: { any } = {
		{
			text = L.text(locale, "perm.owner", L.text(locale, "perm.me"))
				.. "  "
				.. L.text(locale, "perm.version", home.revision),
		},
		{ text = L.text(locale, "perm.hint") },
	}
	for _, category in { "visit", "use", "build", "recover" } do
		table.insert(rows, {
			text = L.text(locale, "perm." .. category, L.text(locale, "mode." .. grants[category])),
			onClick = function()
				act.send(M.request(home, category, state.clanId, nil))
			end,
		})
	end
	table.insert(rows, {
		text = L.text(locale, "perm.offline", L.text(locale, if home.permissions.offlineCoop then "on" else "off")),
		onClick = function()
			act.send(M.request(home, nil, state.clanId, not home.permissions.offlineCoop))
		end,
	})
	if state.status then
		table.insert(rows, { text = state.status })
	end
	if act.openMove then
		table.insert(rows, { text = L.text(locale, "perm.move"), onClick = act.openMove })
	end
	return rows
end

function M.factory(ctx: any): any
	local status: string? = nil
	local panel: any
	panel = Sheet.mount(ctx, {
		id = "home-permissions",
		name = "HomePermissions",
		title = L.text(ctx.locale, "perm.title"),
		order = 12,
		select = function(extensions: any): any
			return {
				home = extensions.home,
				actorId = ctx.actorId,
				clanId = if extensions.clan then extensions.clan.clanId else "",
			}
		end,
		rows = function(state: any): { any }
			local view = table.clone(state or {})
			view.status = status
			return M.rows(ctx.locale, view, {
				send = function(acl: any)
					local result =
						ctx.send("survival-coop:home-permissions", { state.home.homeId, { permissions = acl } })
					status = if result.ok then nil else L.refusal(ctx.locale, result.reason)
					panel.render()
				end,
				openMove = ctx.openHomeMove,
			})
		end,
	})
	return panel
end

return M
