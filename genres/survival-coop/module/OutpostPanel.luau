--!strict
local Panel = require("./ClanPanel")
local M = {}

function M.model(state: any, now: number): any
	local matches = {}
	for id, match in state.matches do
		table.insert(matches, {
			id = id,
			status = match.status,
			score = table.clone(match.score),
			winner = match.winner,
			remaining = math.max(0, match.finishAt - now),
		})
	end
	table.sort(matches, function(a: any, b: any): boolean
		return a.id < b.id
	end)
	return {
		owner = if now < state.expiresAt then state.owner else "",
		remaining = math.max(0, state.expiresAt - now),
		matches = matches,
	}
end

function M.factory(ctx: any): any
	return Panel.mount(ctx, "outpost", ctx.text("ui.outpost"), "social", function(state: any, add: any)
		local view = M.model(state, ctx.serverNow())
		add(ctx.text("outpost.owner") .. ": " .. view.owner)
		add(ctx.text("outpost.remaining") .. ": " .. view.remaining)
		for _, match in view.matches do
			add(ctx.text("outpost." .. match.status) .. " / " .. match.remaining)
			add(tostring(match.score[1]) .. " : " .. tostring(match.score[2]))
			if match.winner ~= "" then
				add(ctx.text("outpost.winner") .. ": " .. match.winner)
			end
		end
		-- Queue/opt-in is a server-owned matchmaking surface supplied by the host.
		add(ctx.text("outpost.opt-in"), function()
			ctx.outpostOptIn()
		end)
	end)
end

return M
